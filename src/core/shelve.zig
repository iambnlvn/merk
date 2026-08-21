const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const crypto = @import("crypto");
const storage = @import("storage");
const merkle_mod = @import("merkle");

const ComponentDir = @import("./staging/repo_paths.zig").ComponentDir;

const Vfs = storage.Vfs;
const Hash = crypto.Hash;
const Entry = merkle_mod.Entry;

const current_shelves_format_version: u8 = 0;

pub const Shelve = struct {
    entries: []Entry,

    parent: ?Hash,

    message: []u8,
    created_at: i128,

    pub fn deinit(self: *Shelve, alloc: Allocator) void {
        for (self.entries) |*e| e.deinit(alloc);
        alloc.free(self.entries);
        alloc.free(self.message);
    }
};

pub const ShelveSummary = struct {
    message: []const u8,
    created_at: i128,
    entry_count: usize,
    parent: ?Hash,
};

pub const ShelveStack = struct {
    alloc: Allocator,
    fs: Vfs,
    dir: ComponentDir,
    shelves_path: ?[]u8 = null,
    shelves: ArrayList(Shelve) = .empty,

    pub fn init(alloc: Allocator, fs: Vfs, shelves_dir: []const u8) ShelveStack {
        return .{ .alloc = alloc, .fs = fs, .dir = ComponentDir.init(shelves_dir) };
    }

    pub fn deinit(self: *ShelveStack) void {
        for (self.shelves.items) |*e| e.deinit(self.alloc);
        self.shelves.deinit(self.alloc);
        if (self.shelves_path) |p| self.alloc.free(p);
    }

    fn shelvesPath(self: *ShelveStack) ![]const u8 {
        if (self.shelves_path) |p| return p;
        const p = try self.dir.join(self.alloc, "shelves");
        self.shelves_path = p;
        return p;
    }

    pub fn load(self: *ShelveStack) !void {
        for (self.shelves.items) |*e| e.deinit(self.alloc);
        self.shelves.clearRetainingCapacity();

        const path = try self.shelvesPath();
        const bytes = (try self.fs.readFile(self.alloc, path)) orelse return;
        defer self.alloc.free(bytes);

        try deserializeShelves(self.alloc, bytes, &self.shelves);
    }

    fn save(self: *ShelveStack) !void {
        const path = try self.shelvesPath();

        if (self.shelves.items.len == 0) {
            self.fs.deleteFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            return;
        }

        const bytes = try serializeShelves(self.alloc, self.shelves.items);
        defer self.alloc.free(bytes);

        const tmp_path = try std.fmt.allocPrint(self.alloc, "{s}.merk-tmp-{d}", .{ path, std.time.nanoTimestamp() });
        defer self.alloc.free(tmp_path);

        try self.fs.writeFile(self.alloc, tmp_path, bytes);
        errdefer self.fs.deleteFile(tmp_path) catch {};
        try self.fs.renameFile(tmp_path, path);
    }

    pub fn push(self: *ShelveStack, shelve: Shelve) !void {
        try self.shelves.append(self.alloc, shelve);
        try self.save();
    }

    pub fn pop(self: *ShelveStack) !Shelve {
        if (self.shelves.items.len == 0) return error.NoStash;
        const shelve = self.shelves.orderedRemove(self.shelves.items.len - 1);
        try self.save();
        return shelve;
    }

    pub fn drop(self: *ShelveStack, index: usize) !void {
        if (index >= self.shelves.items.len) return error.NoSuchStash;
        var removed = self.shelves.orderedRemove(index);
        removed.deinit(self.alloc);
        try self.save();
    }

    pub fn count(self: *const ShelveStack) usize {
        return self.shelves.items.len;
    }

    pub fn list(self: *const ShelveStack, alloc: Allocator) ![]ShelveSummary {
        const out = try alloc.alloc(ShelveSummary, self.shelves.items.len);
        errdefer alloc.free(out);
        const n = self.shelves.items.len;
        for (self.shelves.items, 0..) |e, i| {
            out[n - 1 - i] = .{
                .message = e.message,
                .created_at = e.created_at,
                .entry_count = e.entries.len,
                .parent = e.parent,
            };
        }
        return out;
    }
};

fn serializeShelves(alloc: Allocator, shelves: []const Shelve) ![]u8 {
    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.append(alloc, current_shelves_format_version);

    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, @intCast(shelves.len), .little);
    try out.appendSlice(alloc, &count_buf);

    for (shelves) |e| {
        var msg_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &msg_len_buf, @intCast(e.message.len), .little);
        try out.appendSlice(alloc, &msg_len_buf);
        try out.appendSlice(alloc, e.message);

        var created_buf: [16]u8 = undefined;
        std.mem.writeInt(i128, &created_buf, e.created_at, .little);
        try out.appendSlice(alloc, &created_buf);

        try out.append(alloc, if (e.parent != null) 1 else 0);
        if (e.parent) |p| try out.appendSlice(alloc, &p);

        var entry_count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &entry_count_buf, @intCast(e.entries.len), .little);
        try out.appendSlice(alloc, &entry_count_buf);

        for (e.entries) |entry| {
            var path_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &path_len_buf, @intCast(entry.path.len), .little);
            try out.appendSlice(alloc, &path_len_buf);
            try out.appendSlice(alloc, entry.path);
            try out.appendSlice(alloc, &entry.blob_hash);

            var size_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &size_buf, entry.size, .little);
            try out.appendSlice(alloc, &size_buf);

            var mode_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &mode_buf, entry.mode, .little);
            try out.appendSlice(alloc, &mode_buf);

            var mtime_buf: [16]u8 = undefined;
            std.mem.writeInt(i128, &mtime_buf, entry.mtime, .little);
            try out.appendSlice(alloc, &mtime_buf);
        }
    }

    return try out.toOwnedSlice(alloc);
}

fn deserializeShelves(alloc: Allocator, bytes: []const u8, out: *ArrayList(Shelve)) !void {
    if (bytes.len < 1) return error.CorruptShelves;
    var pos: usize = 0;

    const version = bytes[0];
    pos += 1;
    if (version != current_shelves_format_version) return error.UnsupportedShelvesFormat;

    if (pos + 4 > bytes.len) return error.CorruptShelves;
    const shelve_count = std.mem.readInt(u32, bytes[pos..][0..4], .little);
    pos += 4;

    try out.ensureTotalCapacityPrecise(alloc, shelve_count);
    errdefer for (out.items) |*e| e.deinit(alloc);

    var i: u32 = 0;
    while (i < shelve_count) : (i += 1) {
        if (pos + 4 > bytes.len) return error.CorruptShelves;
        const msg_len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;

        if (pos + msg_len > bytes.len) return error.CorruptShelves;
        const message = try alloc.dupe(u8, bytes[pos..][0..msg_len]);
        errdefer alloc.free(message);
        pos += msg_len;

        if (pos + 16 > bytes.len) return error.CorruptShelves;
        const created_at = std.mem.readInt(i128, bytes[pos..][0..16], .little);
        pos += 16;

        if (pos + 1 > bytes.len) return error.CorruptShelves;
        const has_parent = bytes[pos] != 0;
        pos += 1;

        var parent: ?Hash = null;
        if (has_parent) {
            if (pos + 32 > bytes.len) return error.CorruptShelves;
            var p: Hash = undefined;
            @memcpy(&p, bytes[pos..][0..32]);
            parent = p;
            pos += 32;
        }

        if (pos + 4 > bytes.len) return error.CorruptShelves;
        const entry_count = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;

        var entries: ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |*e| e.deinit(alloc);
            entries.deinit(alloc);
        }
        try entries.ensureTotalCapacityPrecise(alloc, entry_count);

        var j: u32 = 0;
        while (j < entry_count) : (j += 1) {
            if (pos + 4 > bytes.len) return error.CorruptShelves;
            const path_len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            pos += 4;

            if (pos + path_len > bytes.len) return error.CorruptShelves;
            const path_slice = bytes[pos..][0..path_len];
            merkle_mod.validatePath(path_slice) catch return error.CorruptShelves;
            pos += path_len;

            if (pos + 32 > bytes.len) return error.CorruptShelves;
            var blob_hash: Hash = undefined;
            @memcpy(&blob_hash, bytes[pos..][0..32]);
            pos += 32;

            if (pos + 8 > bytes.len) return error.CorruptShelves;
            const size = std.mem.readInt(u64, bytes[pos..][0..8], .little);
            pos += 8;

            if (pos + 8 > bytes.len) return error.CorruptShelves;
            const mode = std.mem.readInt(u64, bytes[pos..][0..8], .little);
            pos += 8;

            if (pos + 16 > bytes.len) return error.CorruptShelves;
            const mtime = std.mem.readInt(i128, bytes[pos..][0..16], .little);
            pos += 16;

            const path = try alloc.dupe(u8, path_slice);
            entries.appendAssumeCapacity(.{
                .path = path,
                .blob_hash = blob_hash,
                .size = size,
                .mode = mode,
                .mtime = mtime,
            });
        }

        out.appendAssumeCapacity(.{
            .entries = try entries.toOwnedSlice(alloc),
            .parent = parent,
            .message = message,
            .created_at = created_at,
        });
    }
}

const testing = std.testing;
const MemoryFs = storage.MemoryFs;

fn testEntry(alloc: Allocator, path: []const u8, seed: u8) !Entry {
    var hash: Hash = undefined;
    @memset(&hash, seed);
    return .{
        .path = try alloc.dupe(u8, path),
        .blob_hash = hash,
        .size = 10,
        .mode = 0o100644,
        .mtime = 1,
    };
}

test "push then pop round-trips entries, message, and parent" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var stack = ShelveStack.init(alloc, mem_fs.fs(), "merk");
    defer stack.deinit();

    var entries = try alloc.alloc(Entry, 1);
    entries[0] = try testEntry(alloc, "a.txt", 1);

    var parent_hash: Hash = undefined;
    @memset(&parent_hash, 0xAB);

    try stack.push(.{
        .entries = entries,
        .parent = parent_hash,
        .message = try alloc.dupe(u8, "WIP on main"),
        .created_at = 123,
    });
    try testing.expectEqual(@as(usize, 1), stack.count());

    var popped = try stack.pop();
    defer popped.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), stack.count());
    try testing.expectEqualStrings("WIP on main", popped.message);
    try testing.expectEqual(@as(i128, 123), popped.created_at);
    try testing.expectEqualStrings("a.txt", popped.entries[0].path);
    try testing.expect(popped.parent != null);
}

test "pop on an empty stack returns NoStash" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var stack = ShelveStack.init(alloc, mem_fs.fs(), "merk");
    defer stack.deinit();

    try testing.expectError(error.NoStash, stack.pop());
}

test "stack survives a save/load round trip and stays LIFO across three pushes" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var stack = ShelveStack.init(alloc, mem_fs.fs(), "merk");
    defer stack.deinit();

    inline for (.{ "first", "second", "third" }) |msg| {
        var entries = try alloc.alloc(Entry, 1);
        entries[0] = try testEntry(alloc, "f.txt", 1);
        try stack.push(.{
            .entries = entries,
            .parent = null,
            .message = try alloc.dupe(u8, msg),
            .created_at = 1,
        });
    }

    var loaded = ShelveStack.init(alloc, mem_fs.fs(), "merk");
    defer loaded.deinit();
    try loaded.load();
    try testing.expectEqual(@as(usize, 3), loaded.count());

    var top = try loaded.pop();
    defer top.deinit(alloc);
    try testing.expectEqualStrings("third", top.message);
}

test "list returns summaries newest first without consuming the stack" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var stack = ShelveStack.init(alloc, mem_fs.fs(), "merk");
    defer stack.deinit();

    inline for (.{ "older", "newer" }) |msg| {
        var entries = try alloc.alloc(Entry, 1);
        entries[0] = try testEntry(alloc, "f.txt", 1);
        try stack.push(.{
            .entries = entries,
            .parent = null,
            .message = try alloc.dupe(u8, msg),
            .created_at = 1,
        });
    }

    const summaries = try stack.list(alloc);
    defer alloc.free(summaries);

    try testing.expectEqual(@as(usize, 2), summaries.len);
    try testing.expectEqualStrings("newer", summaries[0].message);
    try testing.expectEqualStrings("older", summaries[1].message);
    try testing.expectEqual(@as(usize, 2), stack.count()); // untouched
}

test "drop removes the targeted shelve without disturbing the others" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var stack = ShelveStack.init(alloc, mem_fs.fs(), "merk");
    defer stack.deinit();

    inline for (.{ "bottom", "middle", "top" }) |msg| {
        var entries = try alloc.alloc(Entry, 1);
        entries[0] = try testEntry(alloc, "f.txt", 1);
        try stack.push(.{
            .entries = entries,
            .parent = null,
            .message = try alloc.dupe(u8, msg),
            .created_at = 1,
        });
    }

    try stack.drop(1); // "middle"
    try testing.expectEqual(@as(usize, 2), stack.count());

    var top = try stack.pop();
    defer top.deinit(alloc);
    try testing.expectEqualStrings("top", top.message);

    var bottom = try stack.pop();
    defer bottom.deinit(alloc);
    try testing.expectEqualStrings("bottom", bottom.message);
}

test "draining the stack to empty removes the shelves file entirely" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var stack = ShelveStack.init(alloc, mem_fs.fs(), "merk");
    defer stack.deinit();

    var entries = try alloc.alloc(Entry, 1);
    entries[0] = try testEntry(alloc, "f.txt", 1);
    try stack.push(.{ .entries = entries, .parent = null, .message = try alloc.dupe(u8, "only"), .created_at = 1 });

    const path = try stack.shelvesPath();
    try testing.expect((try mem_fs.fs().readFile(alloc, path)) != null);

    var popped = try stack.pop();
    popped.deinit(alloc);

    try testing.expect((try mem_fs.fs().readFile(alloc, path)) == null);
}

test "corrupt shelves file fails cleanly on load rather than reading garbage" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var stack = ShelveStack.init(alloc, mem_fs.fs(), "merk");
    defer stack.deinit();

    var entries = try alloc.alloc(Entry, 1);
    entries[0] = try testEntry(alloc, "f.txt", 1);
    try stack.push(.{ .entries = entries, .parent = null, .message = try alloc.dupe(u8, "x"), .created_at = 1 });

    const path = try stack.shelvesPath();
    const good_bytes = (try mem_fs.fs().readFile(alloc, path)).?;
    defer alloc.free(good_bytes);

    const truncated = try alloc.dupe(u8, good_bytes[0 .. good_bytes.len - 3]);
    defer alloc.free(truncated);
    try mem_fs.fs().writeFile(alloc, path, truncated);

    var reloaded = ShelveStack.init(alloc, mem_fs.fs(), "merk");
    defer reloaded.deinit();
    try testing.expectError(error.CorruptShelves, reloaded.load());
}

test {
    testing.refAllDecls(@This());
}
