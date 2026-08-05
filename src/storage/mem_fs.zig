const std = @import("std");
const vfs = @import("vfs.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub const MemoryFs = struct {
    alloc: Allocator,
    files: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn init(alloc: Allocator) MemoryFs {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *MemoryFs) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.files.deinit(self.alloc);
    }

    pub fn fs(self: *MemoryFs) vfs.Vfs {
        return .{
            .ptr = self,
            .vtable = &.{
                .readFile = readFileImpl,
                .readRange = readRangeImpl,
                .writeFile = writeFileImpl,
                .openStream = openStreamImpl,
                .deleteFile = deleteFileImpl,
                .fileExists = fileExistsImpl,
                .statFile = statFileImpl,
                .renameFile = renameFileImpl,
                .copyFile = copyFileImpl,
                .deleteDir = deleteDirImpl,
                .listFiles = listFilesImpl,
            },
        };
    }

    pub fn fileCount(self: *const MemoryFs) usize {
        return self.files.count();
    }

    pub fn hasFile(self: *const MemoryFs, path: []const u8) bool {
        return self.files.contains(path);
    }

    /// Direct write method utilizing the struct's own allocator rather than requiring a transient one
    pub fn write(self: *MemoryFs, path: []const u8, contents: []const u8) !void {
        const value = try self.alloc.dupe(u8, contents);
        errdefer self.alloc.free(value);

        if (self.files.getPtr(path)) |value_ptr| {
            self.alloc.free(value_ptr.*);
            value_ptr.* = value;
            return;
        }

        const key = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(key);
        try self.files.put(self.alloc, key, value);
    }

    fn readFileImpl(ptr: *anyopaque, alloc: Allocator, path: []const u8, max_size: usize) vfs.VfsError!?[]u8 {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));
        const entry = self.files.get(path) orelse return null;
        if (entry.len > max_size) return error.FileTooBig;
        return try alloc.dupe(u8, entry);
    }

    fn readRangeImpl(ptr: *anyopaque, alloc: Allocator, path: []const u8, offset: u64, len: usize) vfs.VfsError!?[]u8 {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));
        const entry = self.files.get(path) orelse return null;

        if (offset >= entry.len) return try alloc.alloc(u8, 0);

        const available = entry.len - offset;
        const to_read: usize = @intCast(@min(@as(u64, len), available));
        const start: usize = @intCast(offset);
        return try alloc.dupe(u8, entry[start .. start + to_read]);
    }

    const MemFileStream = struct {
        alloc: Allocator,
        bytes: []u8,
        pos: usize,
    };

    fn openStreamImpl(ptr: *anyopaque, alloc: Allocator, path: []const u8) vfs.VfsError!?vfs.FileStream {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));
        const entry = self.files.get(path) orelse return null;

        const dup = try alloc.dupe(u8, entry);
        errdefer alloc.free(dup);

        const stream_ptr = try alloc.create(MemFileStream);
        stream_ptr.* = .{ .alloc = alloc, .bytes = dup, .pos = 0 };

        return vfs.FileStream{
            .ptr = stream_ptr,
            .vtable = &.{
                .read = memFileStreamRead,
                .close = memFileStreamClose,
            },
        };
    }

    fn memFileStreamRead(ptr: *anyopaque, buffer: []u8) vfs.VfsError!usize {
        const stream_ptr: *MemFileStream = @ptrCast(@alignCast(ptr));
        const remaining = stream_ptr.bytes[stream_ptr.pos..];
        const n = @min(buffer.len, remaining.len);
        @memcpy(buffer[0..n], remaining[0..n]);
        stream_ptr.pos += n;
        return n;
    }

    fn memFileStreamClose(ptr: *anyopaque) void {
        const stream_ptr: *MemFileStream = @ptrCast(@alignCast(ptr));
        stream_ptr.alloc.free(stream_ptr.bytes);
        stream_ptr.alloc.destroy(stream_ptr);
    }

    fn writeFileImpl(ptr: *anyopaque, alloc: Allocator, path: []const u8, contents: []const u8) vfs.VfsError!void {
        _ = alloc;
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));
        return self.write(path, contents);
    }

    fn deleteFileImpl(ptr: *anyopaque, path: []const u8) vfs.VfsError!void {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));
        const kv = self.files.fetchRemove(path) orelse return error.FileNotFound;
        self.alloc.free(kv.key);
        self.alloc.free(kv.value);
    }

    fn fileExistsImpl(ptr: *anyopaque, path: []const u8) vfs.VfsError!bool {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));
        return self.files.contains(path);
    }

    fn statFileImpl(ptr: *anyopaque, path: []const u8) vfs.VfsError!?vfs.FileStat {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));
        const entry = self.files.get(path) orelse return null;
        return vfs.FileStat{ .size = entry.len, .mtime_ns = 0 };
    }

    fn renameFileImpl(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) vfs.VfsError!void {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));

        if (std.mem.eql(u8, old_path, new_path)) {
            if (!self.files.contains(old_path)) return error.FileNotFound;
            return;
        }

        const kv = self.files.fetchRemove(old_path) orelse return error.FileNotFound;
        errdefer self.alloc.free(kv.value);
        defer self.alloc.free(kv.key);

        if (self.files.fetchRemove(new_path)) |old_dest| {
            self.alloc.free(old_dest.key);
            self.alloc.free(old_dest.value);
        }

        const new_key = try self.alloc.dupe(u8, new_path);
        errdefer self.alloc.free(new_key);

        try self.files.put(self.alloc, new_key, kv.value);
    }

    fn copyFileImpl(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) vfs.VfsError!void {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));

        const original = self.files.get(old_path) orelse return error.FileNotFound;
        const duplicate = try self.alloc.dupe(u8, original);
        errdefer self.alloc.free(duplicate);

        if (self.files.getPtr(new_path)) |existing_value_ptr| {
            self.alloc.free(existing_value_ptr.*);
            existing_value_ptr.* = duplicate;
            return;
        }

        const key = try self.alloc.dupe(u8, new_path);
        errdefer self.alloc.free(key);
        try self.files.put(self.alloc, key, duplicate);
    }

    fn deleteDirImpl(ptr: *anyopaque, dir_path: []const u8) vfs.VfsError!void {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));

        const prefix_with_sep = if (dir_path.len == 0)
            ""
        else
            try std.fmt.allocPrint(self.alloc, "{s}/", .{dir_path});
        defer if (dir_path.len > 0) self.alloc.free(prefix_with_sep);

        var to_remove: std.ArrayListUnmanaged([]const u8) = .{};
        defer to_remove.deinit(self.alloc);

        var it = self.files.keyIterator();
        while (it.next()) |key_ptr| {
            const key = key_ptr.*;
            if (dir_path.len == 0 or std.mem.startsWith(u8, key, prefix_with_sep)) {
                try to_remove.append(self.alloc, key);
            }
        }

        for (to_remove.items) |key| {
            const kv = self.files.fetchRemove(key) orelse continue;
            self.alloc.free(kv.key);
            self.alloc.free(kv.value);
        }
    }

    fn listFilesImpl(ptr: *anyopaque, alloc: Allocator, dir_path: []const u8) vfs.VfsError![][]u8 {
        const self: *MemoryFs = @ptrCast(@alignCast(ptr));

        const prefix_with_sep = if (dir_path.len == 0)
            ""
        else
            try std.fmt.allocPrint(alloc, "{s}/", .{dir_path});
        defer if (dir_path.len > 0) alloc.free(prefix_with_sep);

        var names: std.ArrayListUnmanaged([]u8) = .{};
        errdefer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }

        var it = self.files.keyIterator();
        while (it.next()) |key_ptr| {
            const key = key_ptr.*;
            if (dir_path.len == 0) {
                try names.append(alloc, try alloc.dupe(u8, key));
            } else if (std.mem.startsWith(u8, key, prefix_with_sep)) {
                const relative = key[prefix_with_sep.len..];
                try names.append(alloc, try alloc.dupe(u8, relative));
            }
        }

        const owned = try names.toOwnedSlice(alloc);
        std.mem.sort([]u8, owned, {}, lessThanStrings);
        return owned;
    }
};

test "MemoryFs: read returns null for missing file" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    const result = try tfs.fs().readFile(alloc, "missing.txt");
    defer if (result) |r| alloc.free(r);

    try testing.expectEqual(@as(?[]u8, null), result);
}

test "MemoryFs: write and read round-trip" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "hello.txt", "world");
    try testing.expectEqual(@as(usize, 1), tfs.fileCount());

    const contents = try tfs.fs().readFile(alloc, "hello.txt");
    defer if (contents) |c| alloc.free(c);

    try testing.expect(contents != null);
    try testing.expectEqualStrings("world", contents.?);
}

test "MemoryFs: readFileLimit enforces the caller's bound" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "big.txt", "0123456789");

    try testing.expectError(error.FileTooBig, tfs.fs().readFileLimit(alloc, "big.txt", 5));

    const ok = try tfs.fs().readFileLimit(alloc, "big.txt", 10);
    defer if (ok) |c| alloc.free(c);
    try testing.expect(ok != null);
}

test "MemoryFs: readRange returns a middle slice" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "range.txt", "0123456789");

    const mid = try tfs.fs().readRange(alloc, "range.txt", 3, 4);
    defer if (mid) |m| alloc.free(m);
    try testing.expect(mid != null);
    try testing.expectEqualStrings("3456", mid.?);
}

test "MemoryFs: readRange past end of file returns empty slice, not an error" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "range.txt", "short");

    const past_end = try tfs.fs().readRange(alloc, "range.txt", 100, 10);
    defer if (past_end) |p| alloc.free(p);
    try testing.expect(past_end != null);
    try testing.expectEqual(@as(usize, 0), past_end.?.len);
}

test "MemoryFs: readRange clamps a length that overruns the file" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "range.txt", "0123456789");

    const clamped = try tfs.fs().readRange(alloc, "range.txt", 8, 10);
    defer if (clamped) |c| alloc.free(c);
    try testing.expect(clamped != null);
    try testing.expectEqualStrings("89", clamped.?);
}

test "MemoryFs: readRange on a missing file returns null" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    const result = try tfs.fs().readRange(alloc, "ghost.txt", 0, 10);
    try testing.expectEqual(@as(?[]u8, null), result);
}

test "MemoryFs: readRange at offset 0 with len 0 returns an empty slice" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "range.txt", "0123456789");

    const empty = try tfs.fs().readRange(alloc, "range.txt", 0, 0);
    defer if (empty) |e| alloc.free(e);
    try testing.expect(empty != null);
    try testing.expectEqual(@as(usize, 0), empty.?.len);
}

test "MemoryFs: openStream streams a file across many small reads" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "stream.txt", "the quick brown fox jumps over the lazy dog");

    var handle = (try tfs.fs().openStream(alloc, "stream.txt")).?;
    defer handle.close();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    var buf: [3]u8 = undefined;
    while (true) {
        const n = try handle.read(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }

    try testing.expectEqualStrings("the quick brown fox jumps over the lazy dog", out.items);
}

test "MemoryFs: openStream on a missing file returns null" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    const handle = try tfs.fs().openStream(alloc, "ghost.txt");
    try testing.expectEqual(@as(?vfs.FileStream, null), handle);
}

test "MemoryFs: openStream is independent of later writes to the same path" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "stream.txt", "original contents");
    var handle = (try tfs.fs().openStream(alloc, "stream.txt")).?;
    defer handle.close();

    // Overwrite the file after opening the handle — the handle should
    // keep reading the snapshot it was opened with.
    try tfs.fs().writeFile(alloc, "stream.txt", "REPLACED");

    var buf: [64]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try handle.read(buf[total..]);
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqualStrings("original contents", buf[0..total]);
}

test "MemoryFs: two open readers on the same file have independent cursors" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "stream.txt", "0123456789");

    var handle_a = (try tfs.fs().openStream(alloc, "stream.txt")).?;
    defer handle_a.close();
    var handle_b = (try tfs.fs().openStream(alloc, "stream.txt")).?;
    defer handle_b.close();

    var buf_a: [4]u8 = undefined;
    var buf_b: [2]u8 = undefined;
    _ = try handle_a.read(&buf_a);
    _ = try handle_b.read(&buf_b);
    try testing.expectEqualStrings("0123", &buf_a);
    try testing.expectEqualStrings("01", &buf_b);

    const n_a2 = try handle_a.read(buf_a[0..2]);
    try testing.expectEqualStrings("45", buf_a[0..n_a2]);
}

test "MemoryFs: overwrite updates contents" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "foo", "first");
    try tfs.fs().writeFile(alloc, "foo", "second");

    const contents = try tfs.fs().readFile(alloc, "foo");
    defer if (contents) |c| alloc.free(c);

    try testing.expectEqualStrings("second", contents.?);
    try testing.expectEqual(@as(usize, 1), tfs.fileCount());
}

test "MemoryFs: delete removes file" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "tmp", "data");
    try testing.expect(tfs.hasFile("tmp"));

    try tfs.fs().deleteFile("tmp");
    try testing.expect(!tfs.hasFile("tmp"));
    try testing.expectEqual(@as(usize, 0), tfs.fileCount());
}

test "MemoryFs: delete missing file returns error" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try testing.expectError(error.FileNotFound, tfs.fs().deleteFile("nope"));
}

test "MemoryFs: fileExists reflects writes and deletes" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try testing.expect(!try tfs.fs().fileExists("x"));

    try tfs.fs().writeFile(alloc, "x", "y");
    try testing.expect(try tfs.fs().fileExists("x"));

    try tfs.fs().deleteFile("x");
    try testing.expect(!try tfs.fs().fileExists("x"));
}

test "MemoryFs: statFile reports size and null-for-missing" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try testing.expectEqual(@as(?vfs.FileStat, null), try tfs.fs().statFile("nope"));

    try tfs.fs().writeFile(alloc, "sized", "12345");
    const stat = try tfs.fs().statFile("sized");
    try testing.expect(stat != null);
    try testing.expectEqual(@as(u64, 5), stat.?.size);
}

test "MemoryFs: renameFile moves content and updates existence" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "old", "payload");
    try tfs.fs().renameFile("old", "new");

    try testing.expect(!tfs.hasFile("old"));
    try testing.expect(tfs.hasFile("new"));

    const contents = try tfs.fs().readFile(alloc, "new");
    defer if (contents) |c| alloc.free(c);
    try testing.expectEqualStrings("payload", contents.?);
}

test "MemoryFs: renameFile overwrites an existing destination" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "src", "new-data");
    try tfs.fs().writeFile(alloc, "dst", "stale-data");

    try tfs.fs().renameFile("src", "dst");

    try testing.expect(!tfs.hasFile("src"));
    try testing.expectEqual(@as(usize, 1), tfs.fileCount());

    const contents = try tfs.fs().readFile(alloc, "dst");
    defer if (contents) |c| alloc.free(c);
    try testing.expectEqualStrings("new-data", contents.?);
}

test "MemoryFs: renameFile onto itself is a no-op" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "same", "data");
    try tfs.fs().renameFile("same", "same");

    const contents = try tfs.fs().readFile(alloc, "same");
    defer if (contents) |c| alloc.free(c);
    try testing.expectEqualStrings("data", contents.?);
}

test "MemoryFs: renameFile missing source errors" {
    var tfs = MemoryFs.init(testing.allocator);
    defer tfs.deinit();

    try testing.expectError(error.FileNotFound, tfs.fs().renameFile("ghost", "somewhere"));
}

test "MemoryFs: copyFile leaves source untouched and independent" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "src", "original");
    try tfs.fs().copyFile("src", "dst");

    try testing.expect(tfs.hasFile("src"));
    try testing.expect(tfs.hasFile("dst"));

    // Mutate the destination and confirm the source is unaffected.
    try tfs.fs().writeFile(alloc, "dst", "mutated");

    const src_contents = try tfs.fs().readFile(alloc, "src");
    defer if (src_contents) |c| alloc.free(c);
    try testing.expectEqualStrings("original", src_contents.?);
}

test "MemoryFs: copyFile missing source errors" {
    var tfs = MemoryFs.init(testing.allocator);
    defer tfs.deinit();

    try testing.expectError(error.FileNotFound, tfs.fs().copyFile("ghost", "somewhere"));
}

test "MemoryFs: copyFile overwrites an existing destination" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "src", "new-data");
    try tfs.fs().writeFile(alloc, "dst", "stale-data");

    try tfs.fs().copyFile("src", "dst");

    const contents = try tfs.fs().readFile(alloc, "dst");
    defer if (contents) |c| alloc.free(c);
    try testing.expectEqualStrings("new-data", contents.?);
}

test "MemoryFs: listFiles returns empty for missing dir" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    const names = try tfs.fs().listFiles(alloc, "nonexistent");
    defer alloc.free(names);

    try testing.expectEqual(@as(usize, 0), names.len);
}

test "MemoryFs: listFiles returns sorted relative paths under a prefix" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "refs/heads/main", "aaa");
    try tfs.fs().writeFile(alloc, "refs/heads/feature/x", "bbb");
    try tfs.fs().writeFile(alloc, "refs/tags/v1", "ccc");

    const names = try tfs.fs().listFiles(alloc, "refs/heads");
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    try testing.expectEqual(@as(usize, 2), names.len);
    // Sorted lexicographically: "feature/x" < "main"
    try testing.expectEqualStrings("feature/x", names[0]);
    try testing.expectEqualStrings("main", names[1]);
}

test "MemoryFs: deleteDir removes everything under a prefix" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "refs/heads/main", "aaa");
    try tfs.fs().writeFile(alloc, "refs/heads/feature/x", "bbb");
    try tfs.fs().writeFile(alloc, "refs/tags/v1", "ccc");

    try tfs.fs().deleteDir("refs/heads");

    try testing.expect(!tfs.hasFile("refs/heads/main"));
    try testing.expect(!tfs.hasFile("refs/heads/feature/x"));
    try testing.expect(tfs.hasFile("refs/tags/v1"));
    try testing.expectEqual(@as(usize, 1), tfs.fileCount());
}

test "MemoryFs: deleteDir on a missing directory is a no-op, not an error" {
    var tfs = MemoryFs.init(testing.allocator);
    defer tfs.deinit();

    try tfs.fs().deleteDir("nowhere/at/all");
}

test "MemoryFs: deleteDir does not touch similarly-prefixed siblings" {
    const alloc = testing.allocator;
    var tfs = MemoryFs.init(alloc);
    defer tfs.deinit();

    // "refs/heading" should NOT be treated as being under "refs/head".
    try tfs.fs().writeFile(alloc, "refs/head/a", "1");
    try tfs.fs().writeFile(alloc, "refs/heading/b", "2");

    try tfs.fs().deleteDir("refs/head");

    try testing.expect(!tfs.hasFile("refs/head/a"));
    try testing.expect(tfs.hasFile("refs/heading/b"));
}

test "MemoryFs conformance" {
    const alloc = testing.allocator;

    var mem = MemoryFs.init(alloc);
    defer mem.deinit();

    try vfs.runVfsTests(mem.fs(), alloc);
}
