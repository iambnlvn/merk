const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

pub const MAGIC: u32 = 0x4E_4F_44_55;
pub const VERSION: u8 = 1;
const max_index_bytes = 64 * 1024 * 1024;

pub const Entry = struct {
    path: []u8,
    blob_hash: Hash,
    size: u64,
    mode: u64,
    mtime: i128,

    pub fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};

pub const WorktreeState = enum {
    clean,
    modified,
    deleted,
};

pub const Index = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    entries: std.ArrayList(Entry),

    pub fn init(alloc: std.mem.Allocator, repo_root: []const u8) !Index {
        const cwd = std.fs.cwd();
        const nodus_path = try std.fs.path.join(alloc, &.{ repo_root, ".nodus" });
        defer alloc.free(nodus_path);

        try cwd.makePath(nodus_path);
        const dir = try cwd.openDir(nodus_path, .{});

        return .{
            .alloc = alloc,
            .dir = dir,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.alloc);
        }
        self.entries.deinit(self.alloc);
        self.dir.close();
    }

    pub fn load(self: *Index) !void {
        const file = self.dir.openFile("index", .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const bytes = try file.readToEndAlloc(self.alloc, max_index_bytes);
        defer self.alloc.free(bytes);

        var reader = std.io.Reader.fixed(bytes);
        if (try reader.takeInt(u32, .little) != MAGIC) return error.CorruptIndex;
        if (try reader.takeByte() != VERSION) return error.UnsupportedIndexVersion;

        const entry_count = try reader.takeInt(u32, .little);
        var loaded: std.ArrayList(Entry) = .empty;
        errdefer {
            for (loaded.items) |*entry| entry.deinit(self.alloc);
            loaded.deinit(self.alloc);
        }

        for (0..entry_count) |_| {
            const path_len = try reader.takeInt(u32, .little);
            if (path_len == 0) return error.CorruptIndex;

            const path = try self.alloc.alloc(u8, path_len);
            errdefer self.alloc.free(path);
            @memcpy(path, try reader.take(path_len));

            var blob_hash: Hash = undefined;
            @memcpy(&blob_hash, try reader.take(blob_hash.len));

            const size = try reader.takeInt(u64, .little);
            const mode = try reader.takeInt(u64, .little);
            const mtime = try reader.takeInt(i128, .little);

            try loaded.append(self.alloc, .{
                .path = path,
                .blob_hash = blob_hash,
                .size = size,
                .mode = mode,
                .mtime = mtime,
            });
        }

        if (reader.takeByte()) |_| return error.CorruptIndex else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }

        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.clearRetainingCapacity();
        try self.entries.appendSlice(self.alloc, loaded.items);
        loaded.deinit(self.alloc);
    }

    pub fn save(self: *Index) !void {
        std.mem.sort(Entry, self.entries.items, {}, entryLessThan);

        const file = try self.dir.createFile("index.tmp", .{ .truncate = true });
        var file_closed = false;
        defer if (!file_closed) file.close();
        errdefer {
            if (!file_closed) {
                file.close();
                file_closed = true;
            }
            self.dir.deleteFile("index.tmp") catch {};
        }

        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(&write_buf);
        const writer = &file_writer.interface;

        try writer.writeInt(u32, MAGIC, .little);
        try writer.writeByte(VERSION);
        try writer.writeInt(u32, @intCast(self.entries.items.len), .little);

        for (self.entries.items) |entry| {
            try writer.writeInt(u32, @intCast(entry.path.len), .little);
            try writer.writeAll(entry.path);
            try writer.writeAll(&entry.blob_hash);
            try writer.writeInt(u64, entry.size, .little);
            try writer.writeInt(u64, entry.mode, .little);
            try writer.writeInt(i128, entry.mtime, .little);
        }

        try writer.flush();
        file.close();
        file_closed = true;

        self.dir.rename("index.tmp", "index") catch |err| switch (err) {
            error.PathAlreadyExists => {
                try self.dir.deleteFile("index");
                try self.dir.rename("index.tmp", "index");
            },
            else => return err,
        };
    }

    pub fn addFile(self: *Index, store: *const Store, repo_root: []const u8, path: []const u8) !Hash {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, path });
        defer self.alloc.free(full_path);
        return self.addFileFromDir(store, cwd, full_path, path);
    }

    pub fn addFileFromDir(self: *Index, store: *const Store, dir: std.fs.Dir, fs_path: []const u8, index_path: []const u8) !Hash {
        try validatePath(index_path);

        const file = try dir.openFile(fs_path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.kind != .file) return error.NotAFile;

        var read_buf: [4096]u8 = undefined;
        var file_reader = file.reader(&read_buf);
        const blob_hash = try store.putReader(.blob, stat.size, &file_reader.interface);

        try self.upsert(.{
            .path = try self.alloc.dupe(u8, index_path),
            .blob_hash = blob_hash,
            .size = stat.size,
            .mode = stat.mode,
            .mtime = stat.mtime,
        });

        return blob_hash;
    }

    pub fn stateOf(self: *const Index, repo_root: []const u8, entry: Entry) !WorktreeState {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, entry.path });
        defer self.alloc.free(full_path);
        return self.stateOfInDir(cwd, full_path, entry);
    }

    pub fn stateOfInDir(_: *const Index, dir: std.fs.Dir, fs_path: []const u8, entry: Entry) !WorktreeState {
        const stat = dir.statFile(fs_path) catch |err| switch (err) {
            error.FileNotFound => return .deleted,
            else => return err,
        };

        if (stat.kind != .file) return .modified;
        if (stat.size != entry.size) return .modified;
        if (stat.mode != entry.mode) return .modified;
        if (stat.mtime != entry.mtime) return .modified;
        return .clean;
    }

    fn upsert(self: *Index, new_entry: Entry) !void {
        errdefer {
            var owned = new_entry;
            owned.deinit(self.alloc);
        }

        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, new_entry.path)) {
                entry.deinit(self.alloc);
                entry.* = new_entry;
                return;
            }
        }

        try self.entries.append(self.alloc, new_entry);
    }
};

fn validatePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidPath;
    if (std.mem.eql(u8, path, ".nodus")) return error.InvalidPath;
    if (std.mem.startsWith(u8, path, ".nodus/")) return error.InvalidPath;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
}

fn entryLessThan(_: void, lhs: Entry, rhs: Entry) bool {
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

test "index save and load round-trip" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var nodus_dir = try tmp_dir.dir.makeOpenPath(".nodus", .{});
    defer nodus_dir.close();

    var index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    try index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "src/main.zig"),
        .blob_hash = hash_mod.blake3("main"),
        .size = 4,
        .mode = 0o100644,
        .mtime = 123,
    });
    try index.save();

    const read_dir = try tmp_dir.dir.openDir(".nodus", .{});
    var loaded = Index{ .alloc = alloc, .dir = read_dir, .entries = .empty };
    defer loaded.deinit();
    try loaded.load();

    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
    try std.testing.expectEqualStrings("src/main.zig", loaded.entries.items[0].path);
    try std.testing.expectEqualSlices(u8, &hash_mod.blake3("main"), &loaded.entries.items[0].blob_hash);
    try std.testing.expectEqual(@as(u64, 4), loaded.entries.items[0].size);
    try std.testing.expectEqual(@as(u64, 0o100644), loaded.entries.items[0].mode);
    try std.testing.expectEqual(@as(i128, 123), loaded.entries.items[0].mtime);

    for (index.entries.items) |*entry| entry.deinit(alloc);
    index.entries.deinit(alloc);
}

test "index addFile stores blob and upserts entry" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "first" });
    var objects_dir = try tmp_dir.dir.makeOpenPath(".nodus/objects", .{});
    defer objects_dir.close();
    const nodus_dir = try tmp_dir.dir.openDir(".nodus", .{});

    var store = Store{ .dir = objects_dir, .alloc = alloc };
    var index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();

    const hash1 = try index.addFileFromDir(&store, tmp_dir.dir, "note.txt", "note.txt");
    try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
    try std.testing.expect(store.exists(hash1));

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "second" });
    const hash2 = try index.addFileFromDir(&store, tmp_dir.dir, "note.txt", "note.txt");
    try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
    try std.testing.expect(store.exists(hash2));
}

test "index stateOf reports deleted file" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const nodus_dir = try tmp_dir.dir.makeOpenPath(".nodus", .{});
    var index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();

    const entry = Entry{
        .path = try alloc.dupe(u8, "missing.txt"),
        .blob_hash = hash_mod.blake3("missing"),
        .size = 7,
        .mode = 0o100644,
        .mtime = 123,
    };
    defer alloc.free(entry.path);

    try std.testing.expectEqual(WorktreeState.deleted, try index.stateOfInDir(tmp_dir.dir, "missing.txt", entry));
}
