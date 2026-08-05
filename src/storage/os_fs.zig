const std = @import("std");
const native_fs = std.fs;

const Allocator = std.mem.Allocator;
const vfs = @import("vfs.zig");

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub const OsFs = struct {
    dir: vfs.Dir,

    pub fn init(dir: vfs.Dir) OsFs {
        return .{ .dir = dir };
    }

    pub fn fs(self: *OsFs) vfs.Vfs {
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

    fn readFileImpl(ptr: *anyopaque, alloc: Allocator, path: []const u8, max_size: usize) vfs.VfsError!?[]u8 {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        return self.dir.readFileAlloc(alloc, path, max_size) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    }

    fn readRangeImpl(ptr: *anyopaque, alloc: Allocator, path: []const u8, offset: u64, len: usize) vfs.VfsError!?[]u8 {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        const file = self.dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (offset >= stat.size) return try alloc.alloc(u8, 0);

        const available = stat.size - offset;
        const to_read: usize = @intCast(@min(@as(u64, len), available));

        try file.seekTo(offset);
        const buf = try alloc.alloc(u8, to_read);
        errdefer alloc.free(buf);

        var total: usize = 0;
        while (total < to_read) {
            const n = try file.read(buf[total..]);
            if (n == 0) break;
            total += n;
        }

        return if (total == to_read) buf else try alloc.realloc(buf, total);
    }

    const RealFileStream = struct {
        alloc: Allocator,
        file: native_fs.File,
    };

    fn openStreamImpl(ptr: *anyopaque, alloc: Allocator, path: []const u8) vfs.VfsError!?vfs.FileStream {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        const file = self.dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        errdefer file.close();

        const stream_ptr = try alloc.create(RealFileStream);
        stream_ptr.* = .{ .alloc = alloc, .file = file };

        return vfs.FileStream{
            .ptr = stream_ptr,
            .vtable = &.{
                .read = realFileStreamRead,
                .close = realFileStreamClose,
            },
        };
    }

    fn realFileStreamRead(ptr: *anyopaque, buffer: []u8) vfs.VfsError!usize {
        const stream_ptr: *RealFileStream = @ptrCast(@alignCast(ptr));
        return stream_ptr.file.read(buffer);
    }

    fn realFileStreamClose(ptr: *anyopaque) void {
        const stream_ptr: *RealFileStream = @ptrCast(@alignCast(ptr));
        stream_ptr.file.close();
        stream_ptr.alloc.destroy(stream_ptr);
    }

    fn writeFileImpl(ptr: *anyopaque, alloc: Allocator, path: []const u8, contents: []const u8) vfs.VfsError!void {
        const self: *OsFs = @ptrCast(@alignCast(ptr));

        if (native_fs.path.dirname(path)) |parent| {
            try self.dir.makePath(parent);
        }

        var rand_buf: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{x}", .{ path, rand_buf });
        defer alloc.free(tmp_path);

        const file = try self.dir.createFile(tmp_path, .{ .truncate = true });
        var file_closed = false;
        defer if (!file_closed) file.close();
        errdefer {
            if (!file_closed) {
                file.close();
                file_closed = true;
            }
            self.dir.deleteFile(tmp_path) catch {};
        }

        try file.writeAll(contents);
        try file.sync();
        file.close();
        file_closed = true;

        self.dir.rename(tmp_path, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try self.dir.deleteFile(path);
                try self.dir.rename(tmp_path, path);
            },
            else => return err,
        };
    }

    fn deleteFileImpl(ptr: *anyopaque, path: []const u8) vfs.VfsError!void {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        try self.dir.deleteFile(path);
        self.pruneEmptyParents(path);
    }

    fn pruneEmptyParents(self: *OsFs, deleted_path: []const u8) void {
        var current: []const u8 = deleted_path;
        while (native_fs.path.dirname(current)) |parent| {
            if (parent.len == 0) break;
            self.dir.deleteDir(parent) catch break;
            current = parent;
        }
    }

    fn fileExistsImpl(ptr: *anyopaque, path: []const u8) vfs.VfsError!bool {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        self.dir.access(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn statFileImpl(ptr: *anyopaque, path: []const u8) vfs.VfsError!?vfs.FileStat {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        const stat = self.dir.statFile(path) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return vfs.FileStat{ .size = stat.size, .mtime_ns = stat.mtime };
    }

    fn renameFileImpl(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) vfs.VfsError!void {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        if (native_fs.path.dirname(new_path)) |parent| {
            try self.dir.makePath(parent);
        }
        try self.dir.rename(old_path, new_path);
        self.pruneEmptyParents(old_path);
    }

    fn copyFileImpl(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) vfs.VfsError!void {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        if (native_fs.path.dirname(new_path)) |parent| {
            try self.dir.makePath(parent);
        }
        try self.dir.copyFile(old_path, self.dir, new_path, .{});
    }

    fn deleteDirImpl(ptr: *anyopaque, dir_path: []const u8) vfs.VfsError!void {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        try self.dir.deleteTree(dir_path);
    }

    fn listFilesImpl(ptr: *anyopaque, alloc: Allocator, dir_path: []const u8) vfs.VfsError![][]u8 {
        const self: *OsFs = @ptrCast(@alignCast(ptr));
        var dir = self.dir.openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer dir.close();

        var names: std.ArrayListUnmanaged([]u8) = .{};
        errdefer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }

        var walker = try dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            try names.append(alloc, try normalizePath(alloc, entry.path));
        }

        const owned = try names.toOwnedSlice(alloc);
        std.mem.sort([]u8, owned, {}, lessThanStrings);
        return owned;
    }

    fn normalizePath(alloc: Allocator, path: []const u8) Allocator.Error![]u8 {
        if (native_fs.path.sep == '/') {
            return try alloc.dupe(u8, path);
        }
        const normalized = try alloc.alloc(u8, path.len);
        for (path, 0..) |c, i| {
            normalized[i] = if (c == native_fs.path.sep) '/' else c;
        }
        return normalized;
    }
};

test "OsFs: write and read round-trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "a/b/c.txt", "nested");

    const contents = try real.fs().readFile(alloc, "a/b/c.txt");
    defer if (contents) |c| alloc.free(c);

    try std.testing.expect(contents != null);
    try std.testing.expectEqualStrings("nested", contents.?);
}

test "OsFs: read missing returns null" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    const result = try real.fs().readFile(alloc, "ghost");
    defer if (result) |r| alloc.free(r);

    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "OsFs: readFileLimit enforces the caller's bound" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "big.txt", "0123456789");

    try std.testing.expectError(error.FileTooBig, real.fs().readFileLimit(alloc, "big.txt", 5));

    const ok = try real.fs().readFileLimit(alloc, "big.txt", 10);
    defer if (ok) |c| alloc.free(c);
    try std.testing.expect(ok != null);
}

test "OsFs: readRange returns a middle slice on real disk" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "range.txt", "0123456789");

    const mid = try real.fs().readRange(alloc, "range.txt", 3, 4);
    defer if (mid) |m| alloc.free(m);
    try std.testing.expect(mid != null);
    try std.testing.expectEqualStrings("3456", mid.?);
}

test "OsFs: readRange past end of file returns empty slice" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "range.txt", "short");

    const past_end = try real.fs().readRange(alloc, "range.txt", 100, 10);
    defer if (past_end) |p| alloc.free(p);
    try std.testing.expect(past_end != null);
    try std.testing.expectEqual(@as(usize, 0), past_end.?.len);
}

test "OsFs: readRange clamps a length that overruns the file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "range.txt", "0123456789");

    const clamped = try real.fs().readRange(alloc, "range.txt", 8, 10);
    defer if (clamped) |c| alloc.free(c);
    try std.testing.expect(clamped != null);
    try std.testing.expectEqualStrings("89", clamped.?);
}

test "OsFs: readRange on a missing file returns null" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    const result = try real.fs().readRange(alloc, "ghost", 0, 10);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "OsFs: openStream streams a file across many small reads" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "stream.txt", "the quick brown fox jumps over the lazy dog");

    var handle = (try real.fs().openStream(alloc, "stream.txt")).?;
    defer handle.close();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    var buf: [3]u8 = undefined;
    while (true) {
        const n = try handle.read(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }

    try std.testing.expectEqualStrings("the quick brown fox jumps over the lazy dog", out.items);
}

test "OsFs: openStream on a missing file returns null" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    const handle = try real.fs().openStream(alloc, "ghost");
    try std.testing.expectEqual(@as(?vfs.FileStream, null), handle);
}

test "OsFs: two open readers on the same file have independent cursors" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "stream.txt", "0123456789");

    var handle_a = (try real.fs().openStream(alloc, "stream.txt")).?;
    defer handle_a.close();
    var handle_b = (try real.fs().openStream(alloc, "stream.txt")).?;
    defer handle_b.close();

    var buf_a: [4]u8 = undefined;
    var buf_b: [2]u8 = undefined;
    _ = try handle_a.read(&buf_a);
    _ = try handle_b.read(&buf_b);
    try std.testing.expectEqualStrings("0123", &buf_a);
    try std.testing.expectEqualStrings("01", &buf_b);

    // Ask for only 2 more bytes here — reusing the full 4-byte `buf_a`
    // would read "4567" (4 bytes) instead of continuing where handle_a
    // left off by exactly 2.
    const n_a2 = try handle_a.read(buf_a[0..2]);
    try std.testing.expectEqualStrings("45", buf_a[0..n_a2]);
}

test "OsFs: delete removes file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "delme", "bye");
    const result = try real.fs().readFile(alloc, "delme");
    try std.testing.expect(result != null);
    defer if (result) |r| alloc.free(r);

    try real.fs().deleteFile("delme");
    try std.testing.expectEqual(@as(?[]u8, null), try real.fs().readFile(alloc, "delme"));
}

test "OsFs: delete missing returns FileNotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try std.testing.expectError(error.FileNotFound, real.fs().deleteFile("nope"));
}

test "OsFs: fileExists reflects writes and deletes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try std.testing.expect(!try real.fs().fileExists("x"));

    try real.fs().writeFile(alloc, "x", "y");
    try std.testing.expect(try real.fs().fileExists("x"));

    try real.fs().deleteFile("x");
    try std.testing.expect(!try real.fs().fileExists("x"));
}

test "OsFs: statFile reports size and null-for-missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try std.testing.expectEqual(@as(?vfs.FileStat, null), try real.fs().statFile("nope"));

    try real.fs().writeFile(alloc, "sized", "12345");
    const stat = try real.fs().statFile("sized");
    try std.testing.expect(stat != null);
    try std.testing.expectEqual(@as(u64, 5), stat.?.size);
}

test "OsFs: renameFile moves content, creates dest dirs, and prunes now-empty source dirs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "refs/heads/old-branch", "sha123");

    // Rename into a directory that shares no path components with the
    // source, so pruning the (now-empty) source tree has nothing to collide
    // with. (Renaming *into* a subdirectory of the source, e.g.
    // "refs/heads/renamed/x", would correctly leave "refs/heads" non-empty
    // that's covered by the "stops at a directory that still has siblings"
    // test below)
    try real.fs().renameFile("refs/heads/old-branch", "archived/deep/new-branch");

    try std.testing.expect(!try real.fs().fileExists("refs/heads/old-branch"));
    try std.testing.expect(try real.fs().fileExists("archived/deep/new-branch"));

    const contents = try real.fs().readFile(alloc, "archived/deep/new-branch");
    defer if (contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("sha123", contents.?);

    // "refs/heads" itself should have been pruned away since the only entry
    // it contained (old-branch) is gone
    var opened = tmp.dir.openDir("refs/heads", .{ .iterate = true });
    try std.testing.expectError(error.FileNotFound, opened);
    if (opened) |*d| d.close() else |_| {}

    // But "refs" is a separate, unrelated top-level directory here (nothing
    // was ever written under it besides "heads"), so it too should be gone
    // confirming pruning climbs more than one level
    var refs = tmp.dir.openDir("refs", .{ .iterate = true });
    try std.testing.expectError(error.FileNotFound, refs);
    if (refs) |*d| d.close() else |_| {}
}

test "OsFs: renameFile overwrites an existing destination" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "src", "new-data");
    try real.fs().writeFile(alloc, "dst", "stale-data");

    try real.fs().renameFile("src", "dst");

    try std.testing.expect(!try real.fs().fileExists("src"));
    const contents = try real.fs().readFile(alloc, "dst");
    defer if (contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("new-data", contents.?);
}

test "OsFs: renameFile missing source errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try std.testing.expectError(error.FileNotFound, real.fs().renameFile("ghost", "somewhere"));
}

test "OsFs: pruneEmptyParents stops at a directory that still has siblings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "refs/heads/main", "aaa");
    try real.fs().writeFile(alloc, "refs/tags/v1", "bbb");

    try real.fs().deleteFile("refs/heads/main");

    // "refs/heads" should be pruned
    var heads = tmp.dir.openDir("refs/heads", .{});
    try std.testing.expectError(error.FileNotFound, heads);
    if (heads) |*d| d.close() else |_| {}

    // refs" itself must survive, since "refs/tags/v1" still lives there.
    try std.testing.expect(try real.fs().fileExists("refs/tags/v1"));
}

test "OsFs: copyFile leaves source untouched and independent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "src", "original");
    try real.fs().copyFile("src", "nested/dst");

    try std.testing.expect(try real.fs().fileExists("src"));
    try std.testing.expect(try real.fs().fileExists("nested/dst"));

    try real.fs().writeFile(alloc, "nested/dst", "mutated");

    const src_contents = try real.fs().readFile(alloc, "src");
    defer if (src_contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("original", src_contents.?);
}

test "OsFs: copyFile missing source errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try std.testing.expectError(error.FileNotFound, real.fs().copyFile("ghost", "somewhere"));
}

test "OsFs: listFiles returns normalized, sorted forward-slash paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "refs/heads/main", "aaa");
    try real.fs().writeFile(alloc, "refs/heads/feature/x", "bbb");

    const names = try real.fs().listFiles(alloc, "refs/heads");
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    try std.testing.expectEqual(@as(usize, 2), names.len);
    // Sorted lexicographically: "feature/x" < "main"
    try std.testing.expectEqualStrings("feature/x", names[0]);
    try std.testing.expectEqualStrings("main", names[1]);
}

test "OsFs: listFiles empty for missing directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    const names = try real.fs().listFiles(alloc, "does/not/exist");
    defer alloc.free(names);

    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "OsFs: deleteDir removes everything under a prefix" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "refs/heads/main", "aaa");
    try real.fs().writeFile(alloc, "refs/heads/feature/x", "bbb");
    try real.fs().writeFile(alloc, "refs/tags/v1", "ccc");

    try real.fs().deleteDir("refs/heads");

    try std.testing.expect(!try real.fs().fileExists("refs/heads/main"));
    try std.testing.expect(!try real.fs().fileExists("refs/heads/feature/x"));
    try std.testing.expect(try real.fs().fileExists("refs/tags/v1"));
}

test "OsFs: deleteDir on a missing directory is a no-op, not an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = OsFs.init(tmp.dir);
    try real.fs().deleteDir("nowhere/at/all");
}

test "OsFs conformance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var os_fs = OsFs.init(tmp.dir);

    try vfs.runVfsTests(os_fs.fs(), std.testing.allocator);
}
