const std = @import("std");

///
/// Production code uses `RealFs` (backed by `std.fs.Dir`). Unit tests use
/// `TestFs` (a pure in-memory hash map). Both implement the `FileSystem`
/// vtable below, so merk's storage layer can be driven identically in tests
/// and in production.
///
/// Note for anyone adding a new `VTable` field: `RealFs.fs()` and
/// `TestFs.fs()` are (as far as this file knows) the only two
/// implementations. If callers elsewhere in the codebase construct a
/// `FileSystem` from their own vtable literal, adding a field here will
/// break them at compile time until they're updated too.
pub const FileSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Read-size ceiling used by the `readFile` convenience wrapper. Chosen
    /// to be generous for merk object/ref files while still catching
    /// corrupted-size or unbounded-growth bugs before they OOM the process.
    /// Callers that know their own tighter (or looser) bound should use
    /// `readFileLimit` instead of relying on this default
    pub const default_max_read_size: usize = 1 << 30; // 1 GiB

    pub const VTable = struct {
        /// Read a file, bounded by `max_size`. Returns `null` if the file
        /// does not exist, or `error.FileTooBig` if it exceeds `max_size`.
        /// Caller owns the returned slice
        readFile: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, max_size: usize) anyerror!?[]u8,

        /// Write `contents` to `path` atomically. Creates parent directories as needed
        writeFile: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, contents: []const u8) anyerror!void,

        /// Delete a file. Returns `error.FileNotFound` if it does not exist
        /// Implementations may also opportunistically remove now-empty
        /// parent directories (see `RealFs`'s doc comment on this)
        deleteFile: *const fn (ptr: *anyopaque, path: []const u8) anyerror!void,

        /// Returns whether `path` exists as a file. Does not read its
        /// contents, so it's cheap to call on a hot path (e.g. an existence
        /// check before inserting a merk node)
        fileExists: *const fn (ptr: *anyopaque, path: []const u8) anyerror!bool,

        /// Returns metadata about `path`, or `null` if it does not exist
        statFile: *const fn (ptr: *anyopaque, path: []const u8) anyerror!?FileStat,

        /// Atomically move `old_path` to `new_path`, creating `new_path`'s
        /// parent directories as needed and overwriting any existing file at
        /// `new_path`. Returns `error.FileNotFound` if `old_path` does not
        /// exist. Renaming a path onto itself is a no-op (still an error if
        /// the path doesn't exist)
        renameFile: *const fn (ptr: *anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void,

        /// Copy `old_path` to `new_path`, creating `new_path`'s parent
        /// directories as needed and overwriting any existing file at
        /// `new_path`. Returns `error.FileNotFound` if `old_path` does not
        /// exist. The two paths are independent after the call — mutating
        /// one does not affect the other.
        copyFile: *const fn (ptr: *anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void,

        /// Recursively delete every file under `dir_path`. Idempotent: a
        /// missing directory is treated as already-empty rather than an
        /// error, matching `listFiles`'s treatment of a missing directory.
        deleteDir: *const fn (ptr: *anyopaque, dir_path: []const u8) anyerror!void,

        /// Recursively list all files under `dir_path`, returning paths relative to
        /// `dir_path` using forward slashes, sorted lexicographically for
        /// deterministic iteration order (callers hashing directory contents,
        /// as merk does, depend on this). Returns an empty slice if the
        /// directory does not exist. Caller owns the returned slice and each
        /// string in it.
        listFiles: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, dir_path: []const u8) anyerror![][]u8,
    };

    /// Read `path` with the default size ceiling (`default_max_read_size`).
    /// This is the right choice for almost every caller; reach for
    /// `readFileLimit` only when you have a specific, different bound in
    /// mind (e.g. you already know the exact expected size from other
    /// metadata and want to fail fast on a mismatch).
    pub fn readFile(self: FileSystem, alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
        return self.vtable.readFile(self.ptr, alloc, path, default_max_read_size);
    }

    /// Read `path`, failing with `error.FileTooBig` if it exceeds `max_size`.
    pub fn readFileLimit(self: FileSystem, alloc: std.mem.Allocator, path: []const u8, max_size: usize) !?[]u8 {
        return self.vtable.readFile(self.ptr, alloc, path, max_size);
    }

    pub fn writeFile(self: FileSystem, alloc: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
        return self.vtable.writeFile(self.ptr, alloc, path, contents);
    }

    pub fn deleteFile(self: FileSystem, path: []const u8) !void {
        return self.vtable.deleteFile(self.ptr, path);
    }

    pub fn fileExists(self: FileSystem, path: []const u8) !bool {
        return self.vtable.fileExists(self.ptr, path);
    }

    pub fn statFile(self: FileSystem, path: []const u8) !?FileStat {
        return self.vtable.statFile(self.ptr, path);
    }

    pub fn renameFile(self: FileSystem, old_path: []const u8, new_path: []const u8) !void {
        return self.vtable.renameFile(self.ptr, old_path, new_path);
    }

    pub fn copyFile(self: FileSystem, old_path: []const u8, new_path: []const u8) !void {
        return self.vtable.copyFile(self.ptr, old_path, new_path);
    }

    pub fn deleteDir(self: FileSystem, dir_path: []const u8) !void {
        return self.vtable.deleteDir(self.ptr, dir_path);
    }

    pub fn listFiles(self: FileSystem, alloc: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
        return self.vtable.listFiles(self.ptr, alloc, dir_path);
    }
};

/// Metadata about a file. `mtime_ns` is nanoseconds since the Unix epoch;
/// `TestFs` doesn't track real timestamps and always reports `0`.
pub const FileStat = struct {
    size: u64,
    mtime_ns: i128,
};

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub const RealFs = struct {
    dir: std.fs.Dir,

    pub fn init(dir: std.fs.Dir) RealFs {
        return .{ .dir = dir };
    }

    pub fn fs(self: *RealFs) FileSystem {
        return .{
            .ptr = self,
            .vtable = &.{
                .readFile = readFileImpl,
                .writeFile = writeFileImpl,
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

    fn readFileImpl(ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, max_size: usize) !?[]u8 {
        const self: *RealFs = @ptrCast(@alignCast(ptr));
        return self.dir.readFileAlloc(alloc, path, max_size) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    }

    fn writeFileImpl(ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
        const self: *RealFs = @ptrCast(@alignCast(ptr));

        if (std.fs.path.dirname(path)) |parent| {
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

    fn deleteFileImpl(ptr: *anyopaque, path: []const u8) !void {
        const self: *RealFs = @ptrCast(@alignCast(ptr));
        try self.dir.deleteFile(path);
        self.pruneEmptyParents(path);
    }

    fn pruneEmptyParents(self: *RealFs, deleted_path: []const u8) void {
        var current: []const u8 = deleted_path;
        while (std.fs.path.dirname(current)) |parent| {
            if (parent.len == 0) break;
            self.dir.deleteDir(parent) catch break;
            current = parent;
        }
    }

    fn fileExistsImpl(ptr: *anyopaque, path: []const u8) !bool {
        const self: *RealFs = @ptrCast(@alignCast(ptr));
        self.dir.access(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn statFileImpl(ptr: *anyopaque, path: []const u8) !?FileStat {
        const self: *RealFs = @ptrCast(@alignCast(ptr));
        const stat = self.dir.statFile(path) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return FileStat{ .size = stat.size, .mtime_ns = stat.mtime };
    }

    fn renameFileImpl(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) !void {
        const self: *RealFs = @ptrCast(@alignCast(ptr));

        if (std.fs.path.dirname(new_path)) |parent| {
            try self.dir.makePath(parent);
        }
        try self.dir.rename(old_path, new_path);
        self.pruneEmptyParents(old_path);
    }

    fn copyFileImpl(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) !void {
        const self: *RealFs = @ptrCast(@alignCast(ptr));

        if (std.fs.path.dirname(new_path)) |parent| {
            try self.dir.makePath(parent);
        }
        try self.dir.copyFile(old_path, self.dir, new_path, .{});
    }

    fn deleteDirImpl(ptr: *anyopaque, dir_path: []const u8) !void {
        const self: *RealFs = @ptrCast(@alignCast(ptr));
        // `deleteTree` already treats a nonexistent `dir_path` as a
        // successful no-op rather than an error, which matches the
        // idempotent semantics documented on `VTable.deleteDir`.
        try self.dir.deleteTree(dir_path);
    }

    fn listFilesImpl(ptr: *anyopaque, alloc: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
        const self: *RealFs = @ptrCast(@alignCast(ptr));

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

    fn normalizePath(alloc: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
        if (std.fs.path.sep == '/') {
            return try alloc.dupe(u8, path);
        }
        const normalized = try alloc.alloc(u8, path.len);
        for (path, 0..) |c, i| {
            normalized[i] = if (c == std.fs.path.sep) '/' else c;
        }
        return normalized;
    }
};

pub const TestFs = struct {
    alloc: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn init(alloc: std.mem.Allocator) TestFs {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *TestFs) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.files.deinit(self.alloc);
    }

    pub fn fs(self: *TestFs) FileSystem {
        return .{
            .ptr = self,
            .vtable = &.{
                .readFile = readFileImpl,
                .writeFile = writeFileImpl,
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

    pub fn fileCount(self: *const TestFs) usize {
        return self.files.count();
    }

    pub fn hasFile(self: *const TestFs, path: []const u8) bool {
        return self.files.contains(path);
    }

    fn readFileImpl(ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, max_size: usize) !?[]u8 {
        const self: *TestFs = @ptrCast(@alignCast(ptr));
        const entry = self.files.get(path) orelse return null;
        if (entry.len > max_size) return error.FileTooBig;
        return try alloc.dupe(u8, entry);
    }

    fn writeFileImpl(ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
        // Deliberately ignore the caller-supplied allocator: TestFs owns its
        // backing storage for the lifetime of the struct (freed in
        // `deinit`), independent of whatever allocator any one caller passes
        // in for a single call. `readFile`, by contrast, uses the passed-in
        // allocator because the caller owns *that* returned slice
        _ = alloc;
        const self: *TestFs = @ptrCast(@alignCast(ptr));

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

    fn deleteFileImpl(ptr: *anyopaque, path: []const u8) !void {
        const self: *TestFs = @ptrCast(@alignCast(ptr));
        const kv = self.files.fetchRemove(path) orelse return error.FileNotFound;
        self.alloc.free(kv.key);
        self.alloc.free(kv.value);
    }

    fn fileExistsImpl(ptr: *anyopaque, path: []const u8) !bool {
        const self: *TestFs = @ptrCast(@alignCast(ptr));
        return self.files.contains(path);
    }

    fn statFileImpl(ptr: *anyopaque, path: []const u8) !?FileStat {
        const self: *TestFs = @ptrCast(@alignCast(ptr));
        const entry = self.files.get(path) orelse return null;
        return FileStat{ .size = entry.len, .mtime_ns = 0 };
    }

    fn renameFileImpl(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) !void {
        const self: *TestFs = @ptrCast(@alignCast(ptr));

        if (std.mem.eql(u8, old_path, new_path)) {
            if (!self.files.contains(old_path)) return error.FileNotFound;
            return;
        }

        const kv = self.files.fetchRemove(old_path) orelse return error.FileNotFound;
        errdefer self.alloc.free(kv.value);
        defer self.alloc.free(kv.key); // the old key is never reused

        if (self.files.fetchRemove(new_path)) |old_dest| {
            self.alloc.free(old_dest.key);
            self.alloc.free(old_dest.value);
        }

        const new_key = try self.alloc.dupe(u8, new_path);
        errdefer self.alloc.free(new_key);

        try self.files.put(self.alloc, new_key, kv.value);
    }

    fn copyFileImpl(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) !void {
        const self: *TestFs = @ptrCast(@alignCast(ptr));

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

    fn deleteDirImpl(ptr: *anyopaque, dir_path: []const u8) !void {
        const self: *TestFs = @ptrCast(@alignCast(ptr));

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

    fn listFilesImpl(ptr: *anyopaque, alloc: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
        const self: *TestFs = @ptrCast(@alignCast(ptr));

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

test "TestFs: read returns null for missing file" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    const result = try tfs.fs().readFile(alloc, "missing.txt");
    defer if (result) |r| alloc.free(r);

    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "TestFs: write and read round-trip" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "hello.txt", "world");
    try std.testing.expectEqual(@as(usize, 1), tfs.fileCount());

    const contents = try tfs.fs().readFile(alloc, "hello.txt");
    defer if (contents) |c| alloc.free(c);

    try std.testing.expect(contents != null);
    try std.testing.expectEqualStrings("world", contents.?);
}

test "TestFs: readFileLimit enforces the caller's bound" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "big.txt", "0123456789");

    try std.testing.expectError(error.FileTooBig, tfs.fs().readFileLimit(alloc, "big.txt", 5));

    const ok = try tfs.fs().readFileLimit(alloc, "big.txt", 10);
    defer if (ok) |c| alloc.free(c);
    try std.testing.expect(ok != null);
}

test "TestFs: overwrite updates contents" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "foo", "first");
    try tfs.fs().writeFile(alloc, "foo", "second");

    const contents = try tfs.fs().readFile(alloc, "foo");
    defer if (contents) |c| alloc.free(c);

    try std.testing.expectEqualStrings("second", contents.?);
    try std.testing.expectEqual(@as(usize, 1), tfs.fileCount());
}

test "TestFs: delete removes file" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "tmp", "data");
    try std.testing.expect(tfs.hasFile("tmp"));

    try tfs.fs().deleteFile("tmp");
    try std.testing.expect(!tfs.hasFile("tmp"));
    try std.testing.expectEqual(@as(usize, 0), tfs.fileCount());
}

test "TestFs: delete missing file returns error" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try std.testing.expectError(error.FileNotFound, tfs.fs().deleteFile("nope"));
}

test "TestFs: fileExists reflects writes and deletes" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try std.testing.expect(!try tfs.fs().fileExists("x"));

    try tfs.fs().writeFile(alloc, "x", "y");
    try std.testing.expect(try tfs.fs().fileExists("x"));

    try tfs.fs().deleteFile("x");
    try std.testing.expect(!try tfs.fs().fileExists("x"));
}

test "TestFs: statFile reports size and null-for-missing" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try std.testing.expectEqual(@as(?FileStat, null), try tfs.fs().statFile("nope"));

    try tfs.fs().writeFile(alloc, "sized", "12345");
    const stat = try tfs.fs().statFile("sized");
    try std.testing.expect(stat != null);
    try std.testing.expectEqual(@as(u64, 5), stat.?.size);
}

test "TestFs: renameFile moves content and updates existence" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "old", "payload");
    try tfs.fs().renameFile("old", "new");

    try std.testing.expect(!tfs.hasFile("old"));
    try std.testing.expect(tfs.hasFile("new"));

    const contents = try tfs.fs().readFile(alloc, "new");
    defer if (contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("payload", contents.?);
}

test "TestFs: renameFile overwrites an existing destination" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "src", "new-data");
    try tfs.fs().writeFile(alloc, "dst", "stale-data");

    try tfs.fs().renameFile("src", "dst");

    try std.testing.expect(!tfs.hasFile("src"));
    try std.testing.expectEqual(@as(usize, 1), tfs.fileCount());

    const contents = try tfs.fs().readFile(alloc, "dst");
    defer if (contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("new-data", contents.?);
}

test "TestFs: renameFile onto itself is a no-op" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "same", "data");
    try tfs.fs().renameFile("same", "same");

    const contents = try tfs.fs().readFile(alloc, "same");
    defer if (contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("data", contents.?);
}

test "TestFs: renameFile missing source errors" {
    var tfs = TestFs.init(std.testing.allocator);
    defer tfs.deinit();

    try std.testing.expectError(error.FileNotFound, tfs.fs().renameFile("ghost", "somewhere"));
}

test "TestFs: copyFile leaves source untouched and independent" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "src", "original");
    try tfs.fs().copyFile("src", "dst");

    try std.testing.expect(tfs.hasFile("src"));
    try std.testing.expect(tfs.hasFile("dst"));

    // Mutate the destination and confirm the source is unaffected.
    try tfs.fs().writeFile(alloc, "dst", "mutated");

    const src_contents = try tfs.fs().readFile(alloc, "src");
    defer if (src_contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("original", src_contents.?);
}

test "TestFs: copyFile missing source errors" {
    var tfs = TestFs.init(std.testing.allocator);
    defer tfs.deinit();

    try std.testing.expectError(error.FileNotFound, tfs.fs().copyFile("ghost", "somewhere"));
}

test "TestFs: copyFile overwrites an existing destination" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "src", "new-data");
    try tfs.fs().writeFile(alloc, "dst", "stale-data");

    try tfs.fs().copyFile("src", "dst");

    const contents = try tfs.fs().readFile(alloc, "dst");
    defer if (contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("new-data", contents.?);
}

test "TestFs: listFiles returns empty for missing dir" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    const names = try tfs.fs().listFiles(alloc, "nonexistent");
    defer alloc.free(names);

    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "TestFs: listFiles returns sorted relative paths under a prefix" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "refs/heads/main", "aaa");
    try tfs.fs().writeFile(alloc, "refs/heads/feature/x", "bbb");
    try tfs.fs().writeFile(alloc, "refs/tags/v1", "ccc");

    const names = try tfs.fs().listFiles(alloc, "refs/heads");
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    try std.testing.expectEqual(@as(usize, 2), names.len);
    // Sorted lexicographically: "feature/x" < "main"
    try std.testing.expectEqualStrings("feature/x", names[0]);
    try std.testing.expectEqualStrings("main", names[1]);
}

test "TestFs: deleteDir removes everything under a prefix" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    try tfs.fs().writeFile(alloc, "refs/heads/main", "aaa");
    try tfs.fs().writeFile(alloc, "refs/heads/feature/x", "bbb");
    try tfs.fs().writeFile(alloc, "refs/tags/v1", "ccc");

    try tfs.fs().deleteDir("refs/heads");

    try std.testing.expect(!tfs.hasFile("refs/heads/main"));
    try std.testing.expect(!tfs.hasFile("refs/heads/feature/x"));
    try std.testing.expect(tfs.hasFile("refs/tags/v1"));
    try std.testing.expectEqual(@as(usize, 1), tfs.fileCount());
}

test "TestFs: deleteDir on a missing directory is a no-op, not an error" {
    var tfs = TestFs.init(std.testing.allocator);
    defer tfs.deinit();

    try tfs.fs().deleteDir("nowhere/at/all");
}

test "TestFs: deleteDir does not touch similarly-prefixed siblings" {
    const alloc = std.testing.allocator;
    var tfs = TestFs.init(alloc);
    defer tfs.deinit();

    // "refs/heading" should NOT be treated as being under "refs/head".
    try tfs.fs().writeFile(alloc, "refs/head/a", "1");
    try tfs.fs().writeFile(alloc, "refs/heading/b", "2");

    try tfs.fs().deleteDir("refs/head");

    try std.testing.expect(!tfs.hasFile("refs/head/a"));
    try std.testing.expect(tfs.hasFile("refs/heading/b"));
}

test "RealFs: write and read round-trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "a/b/c.txt", "nested");

    const contents = try real.fs().readFile(alloc, "a/b/c.txt");
    defer if (contents) |c| alloc.free(c);

    try std.testing.expect(contents != null);
    try std.testing.expectEqualStrings("nested", contents.?);
}

test "RealFs: read missing returns null" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    const result = try real.fs().readFile(alloc, "ghost");
    defer if (result) |r| alloc.free(r);

    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "RealFs: readFileLimit enforces the caller's bound" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "big.txt", "0123456789");

    try std.testing.expectError(error.FileTooBig, real.fs().readFileLimit(alloc, "big.txt", 5));

    const ok = try real.fs().readFileLimit(alloc, "big.txt", 10);
    defer if (ok) |c| alloc.free(c);
    try std.testing.expect(ok != null);
}

test "RealFs: delete removes file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "delme", "bye");
    const result = try real.fs().readFile(alloc, "delme");
    try std.testing.expect(result != null);
    defer if (result) |r| alloc.free(r);

    try real.fs().deleteFile("delme");
    try std.testing.expectEqual(@as(?[]u8, null), try real.fs().readFile(alloc, "delme"));
}

test "RealFs: delete missing returns FileNotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try std.testing.expectError(error.FileNotFound, real.fs().deleteFile("nope"));
}

test "RealFs: fileExists reflects writes and deletes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try std.testing.expect(!try real.fs().fileExists("x"));

    try real.fs().writeFile(alloc, "x", "y");
    try std.testing.expect(try real.fs().fileExists("x"));

    try real.fs().deleteFile("x");
    try std.testing.expect(!try real.fs().fileExists("x"));
}

test "RealFs: statFile reports size and null-for-missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try std.testing.expectEqual(@as(?FileStat, null), try real.fs().statFile("nope"));

    try real.fs().writeFile(alloc, "sized", "12345");
    const stat = try real.fs().statFile("sized");
    try std.testing.expect(stat != null);
    try std.testing.expectEqual(@as(u64, 5), stat.?.size);
}

test "RealFs: renameFile moves content, creates dest dirs, and prunes now-empty source dirs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
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

test "RealFs: renameFile overwrites an existing destination" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "src", "new-data");
    try real.fs().writeFile(alloc, "dst", "stale-data");

    try real.fs().renameFile("src", "dst");

    try std.testing.expect(!try real.fs().fileExists("src"));
    const contents = try real.fs().readFile(alloc, "dst");
    defer if (contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("new-data", contents.?);
}

test "RealFs: renameFile missing source errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try std.testing.expectError(error.FileNotFound, real.fs().renameFile("ghost", "somewhere"));
}

test "RealFs: pruneEmptyParents stops at a directory that still has siblings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
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

test "RealFs: copyFile leaves source untouched and independent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "src", "original");
    try real.fs().copyFile("src", "nested/dst");

    try std.testing.expect(try real.fs().fileExists("src"));
    try std.testing.expect(try real.fs().fileExists("nested/dst"));

    try real.fs().writeFile(alloc, "nested/dst", "mutated");

    const src_contents = try real.fs().readFile(alloc, "src");
    defer if (src_contents) |c| alloc.free(c);
    try std.testing.expectEqualStrings("original", src_contents.?);
}

test "RealFs: copyFile missing source errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try std.testing.expectError(error.FileNotFound, real.fs().copyFile("ghost", "somewhere"));
}

test "RealFs: listFiles returns normalized, sorted forward-slash paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
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

test "RealFs: listFiles empty for missing directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    const names = try real.fs().listFiles(alloc, "does/not/exist");
    defer alloc.free(names);

    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "RealFs: deleteDir removes everything under a prefix" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try real.fs().writeFile(alloc, "refs/heads/main", "aaa");
    try real.fs().writeFile(alloc, "refs/heads/feature/x", "bbb");
    try real.fs().writeFile(alloc, "refs/tags/v1", "ccc");

    try real.fs().deleteDir("refs/heads");

    try std.testing.expect(!try real.fs().fileExists("refs/heads/main"));
    try std.testing.expect(!try real.fs().fileExists("refs/heads/feature/x"));
    try std.testing.expect(try real.fs().fileExists("refs/tags/v1"));
}

test "RealFs: deleteDir on a missing directory is a no-op, not an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real = RealFs.init(tmp.dir);
    try real.fs().deleteDir("nowhere/at/all");
}
