const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

pub const MAGIC: u32 = 0x4E_4F_44_55;
pub const VERSION: u8 = 1;

pub const PAGE_SIZE: usize = 4096;
pub const LEAF_PAGE: u8 = 0x01;
pub const INTERNAL_PAGE: u8 = 0x02;
pub const PathKey = u64;

const max_legacy_index_bytes = 64 * 1024 * 1024;
const page_rel_path_len = 11 + 1 + 2 + 1 + 2 + 1 + 64;
const page_dir_path_len = 11 + 1 + 2 + 1 + 2;
const leaf_header_len = 8;
const internal_header_len = 8;
const child_ref_len = 40;
const min_leaf_entry_len = 8 + 2 + 32 + 8 + 8 + 16;

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

pub const LeafEntry = struct {
    key: PathKey,
    path: []u8,
    blob_hash: Hash,
    size: u64,
    mode: u64,
    mtime: i128,

    fn fromEntry(entry: Entry) LeafEntry {
        return .{
            .key = pathKey(entry.path),
            .path = entry.path,
            .blob_hash = entry.blob_hash,
            .size = entry.size,
            .mode = entry.mode,
            .mtime = entry.mtime,
        };
    }
};

pub const ChildRef = struct {
    separator: PathKey,
    page_hash: Hash,
};

pub const Page = union(enum) {
    leaf: std.ArrayList(LeafEntry),
    internal: std.ArrayList(ChildRef),

    pub fn deinit(self: *Page, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .leaf => |*entries| {
                for (entries.items) |*entry| alloc.free(entry.path);
                entries.deinit(alloc);
            },
            .internal => |*children| children.deinit(alloc),
        }
    }
};

pub const WorktreeState = enum {
    clean,
    modified,
    deleted,
};

pub fn pathKey(path: []const u8) PathKey {
    const h = hash_mod.blake3(path);
    var key: PathKey = 0;
    for (h[0..8]) |byte| {
        key = (key << 8) | byte;
    }
    return key;
}

pub const PageStore = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,

    pub fn ensure(self: *const PageStore) !void {
        try self.dir.makePath("index/pages");
    }

    pub fn put(self: *const PageStore, page_bytes: *const [PAGE_SIZE]u8) !Hash {
        try self.ensure();

        const page_hash = hash_mod.blake3(page_bytes);
        var path_buf: [page_rel_path_len]u8 = undefined;
        const path = pagePath(&path_buf, page_hash);

        if (self.dir.access(path, .{})) |_| return page_hash else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        try self.dir.makePath(".tmp");

        var rand_buf: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        const tmp_path = try std.fmt.allocPrint(self.alloc, ".tmp/{x}.idx", .{rand_buf});
        defer self.alloc.free(tmp_path);

        const file = try self.dir.createFile(tmp_path, .{});
        var file_closed = false;
        defer if (!file_closed) file.close();
        errdefer {
            if (!file_closed) {
                file.close();
                file_closed = true;
            }
            self.dir.deleteFile(tmp_path) catch {};
        }

        try file.writeAll(page_bytes);
        try file.sync();
        file.close();
        file_closed = true;

        var dir_buf: [page_dir_path_len]u8 = undefined;
        const dir_path = pageDirPath(&dir_buf, page_hash);
        self.dir.rename(tmp_path, path) catch |err| switch (err) {
            error.FileNotFound => {
                try self.dir.makePath(dir_path);
                try self.dir.rename(tmp_path, path);
            },
            error.PathAlreadyExists => {
                self.dir.deleteFile(tmp_path) catch {};
            },
            else => return err,
        };

        return page_hash;
    }

    pub fn getBytes(self: *const PageStore, page_hash: Hash) ![PAGE_SIZE]u8 {
        var path_buf: [page_rel_path_len]u8 = undefined;
        const path = pagePath(&path_buf, page_hash);

        const file = self.dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return err,
        };
        defer file.close();

        var bytes: [PAGE_SIZE]u8 = undefined;
        var reader_buf: [PAGE_SIZE]u8 = undefined;
        var file_reader = file.readerStreaming(&reader_buf);
        @memcpy(&bytes, try file_reader.interface.take(PAGE_SIZE));

        const computed = hash_mod.blake3(&bytes);
        if (!std.mem.eql(u8, &computed, &page_hash)) return error.HashMismatch;
        return bytes;
    }

    pub fn get(self: *const PageStore, page_hash: Hash) !Page {
        const bytes = try self.getBytes(page_hash);
        return parsePage(self.alloc, &bytes);
    }
};

pub const Index = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    entries: std.ArrayList(Entry),
    index_root: Hash = hash_mod.ZERO_HASH,

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
        clearEntries(self);
        self.entries.deinit(self.alloc);
        self.dir.close();
    }

    pub fn load(self: *Index) !void {
        clearEntries(self);
        self.index_root = hash_mod.ZERO_HASH;

        const root = readIndexRoot(self.dir) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return self.loadLegacyFlatFile(),
            else => return err,
        };

        self.index_root = root;
        if (std.mem.eql(u8, &root, &hash_mod.ZERO_HASH)) return;

        var store = PageStore{ .alloc = self.alloc, .dir = self.dir };
        try self.collectPageEntries(&store, root);
        std.mem.sort(Entry, self.entries.items, {}, entryLessThan);
    }

    pub fn save(self: *Index) !void {
        std.mem.sort(Entry, self.entries.items, {}, entryLessThan);

        self.dir.deleteFile("index") catch {};
        try self.dir.makePath("index/pages");

        const root = try self.writeTree();
        try self.writeIndexRoot(root);
        self.index_root = root;
    }

    pub fn lookup(self: *const Index, path: []const u8) ?Entry {
        var left: usize = 0;
        var right: usize = self.entries.items.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const entry = self.entries.items[mid];
            if (std.mem.lessThan(u8, entry.path, path)) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        if (left < self.entries.items.len and std.mem.eql(u8, self.entries.items[left].path, path)) {
            return self.entries.items[left];
        }
        return null;
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

    fn writeTree(self: *Index) !Hash {
        if (self.entries.items.len == 0) return hash_mod.ZERO_HASH;

        var store = PageStore{ .alloc = self.alloc, .dir = self.dir };
        var level: std.ArrayList(ChildRef) = .empty;
        defer level.deinit(self.alloc);

        const sorted_entries = try self.alloc.alloc(Entry, self.entries.items.len);
        defer self.alloc.free(sorted_entries);
        @memcpy(sorted_entries, self.entries.items);
        std.mem.sort(Entry, sorted_entries, {}, entryKeyLessThan);

        var offset: usize = 0;
        while (offset < sorted_entries.len) {
            var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
            page[0] = LEAF_PAGE;

            var writer = std.Io.Writer.fixed(page[leaf_header_len..]);
            const first_key = pathKey(sorted_entries[offset].path);
            var count: u16 = 0;

            while (offset < sorted_entries.len) {
                const entry = sorted_entries[offset];
                const needed = leafEntrySize(entry);
                if (needed > PAGE_SIZE - leaf_header_len) return error.IndexEntryTooLarge;
                if (writer.end + needed > page.len - leaf_header_len and count > 0) break;

                try writeLeafEntry(&writer, LeafEntry.fromEntry(entry));
                count += 1;
                offset += 1;
            }

            std.mem.writeInt(u16, page[2..4], count, .little);
            const page_hash = try store.put(&page);
            try level.append(self.alloc, .{
                .separator = first_key,
                .page_hash = page_hash,
            });
        }

        while (level.items.len > 1) {
            var next: std.ArrayList(ChildRef) = .empty;
            errdefer next.deinit(self.alloc);

            var child_offset: usize = 0;
            while (child_offset < level.items.len) {
                var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
                page[0] = INTERNAL_PAGE;

                var writer = std.Io.Writer.fixed(page[internal_header_len..]);
                const first_separator = level.items[child_offset].separator;
                var child_count: u16 = 0;

                while (child_offset < level.items.len) {
                    if (writer.end + child_ref_len > page.len - internal_header_len and child_count > 0) break;
                    try writer.writeInt(u64, level.items[child_offset].separator, .little);
                    try writer.writeAll(&level.items[child_offset].page_hash);
                    child_count += 1;
                    child_offset += 1;
                }

                std.mem.writeInt(u16, page[2..4], child_count, .little);
                const page_hash = try store.put(&page);
                try next.append(self.alloc, .{
                    .separator = first_separator,
                    .page_hash = page_hash,
                });
            }

            level.deinit(self.alloc);
            level = next;
        }

        return level.items[0].page_hash;
    }

    fn writeIndexRoot(self: *Index, root: Hash) !void {
        self.dir.deleteFile("index") catch {};
        try self.dir.makePath("index");

        const file = try self.dir.createFile("index/index_root.tmp", .{ .truncate = true });
        var file_closed = false;
        defer if (!file_closed) file.close();
        errdefer {
            if (!file_closed) {
                file.close();
                file_closed = true;
            }
            self.dir.deleteFile("index/index_root.tmp") catch {};
        }

        try file.writeAll(&root);
        try file.sync();
        file.close();
        file_closed = true;

        self.dir.rename("index/index_root.tmp", "index/index_root") catch |err| switch (err) {
            error.PathAlreadyExists => {
                try self.dir.deleteFile("index/index_root");
                try self.dir.rename("index/index_root.tmp", "index/index_root");
            },
            else => return err,
        };
    }

    fn collectPageEntries(self: *Index, store: *const PageStore, page_hash: Hash) !void {
        var page = try store.get(page_hash);
        defer page.deinit(self.alloc);

        switch (page) {
            .leaf => |entries| {
                for (entries.items) |leaf_entry| {
                    try self.entries.append(self.alloc, .{
                        .path = try self.alloc.dupe(u8, leaf_entry.path),
                        .blob_hash = leaf_entry.blob_hash,
                        .size = leaf_entry.size,
                        .mode = leaf_entry.mode,
                        .mtime = leaf_entry.mtime,
                    });
                }
            },
            .internal => |children| {
                for (children.items) |child| {
                    try self.collectPageEntries(store, child.page_hash);
                }
            },
        }
    }

    fn loadLegacyFlatFile(self: *Index) !void {
        const file = self.dir.openFile("index", .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const bytes = try file.readToEndAlloc(self.alloc, max_legacy_index_bytes);
        defer self.alloc.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        if (try reader.takeInt(u32, .little) != MAGIC) return error.CorruptIndex;
        if (try reader.takeByte() != VERSION) return error.UnsupportedIndexVersion;

        const entry_count = try reader.takeInt(u32, .little);

        for (0..entry_count) |_| {
            const path_len = try reader.takeInt(u32, .little);
            if (path_len == 0 or path_len > std.math.maxInt(u16)) return error.CorruptIndex;

            const path = try self.alloc.alloc(u8, path_len);
            errdefer self.alloc.free(path);
            @memcpy(path, try reader.take(path_len));

            var blob_hash: Hash = undefined;
            @memcpy(&blob_hash, try reader.take(blob_hash.len));

            try self.entries.append(self.alloc, .{
                .path = path,
                .blob_hash = blob_hash,
                .size = try reader.takeInt(u64, .little),
                .mode = try reader.takeInt(u64, .little),
                .mtime = try reader.takeInt(i128, .little),
            });
        }

        if (reader.takeByte()) |_| return error.CorruptIndex else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }

        std.mem.sort(Entry, self.entries.items, {}, entryLessThan);
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

fn parsePage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8) !Page {
    return switch (bytes[0]) {
        LEAF_PAGE => try parseLeafPage(alloc, bytes),
        INTERNAL_PAGE => try parseInternalPage(alloc, bytes),
        else => error.CorruptIndexPage,
    };
}

fn parseLeafPage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8) !Page {
    const count = std.mem.readInt(u16, bytes[2..4], .little);
    var reader = std.Io.Reader.fixed(bytes[leaf_header_len..]);
    var entries: std.ArrayList(LeafEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| alloc.free(entry.path);
        entries.deinit(alloc);
    }

    var last_key: ?PathKey = null;
    for (0..count) |_| {
        const key = try reader.takeInt(u64, .little);
        const path_len = try reader.takeInt(u16, .little);
        if (path_len == 0) return error.CorruptIndexPage;

        const path = try alloc.alloc(u8, path_len);
        errdefer alloc.free(path);
        @memcpy(path, try reader.take(path_len));

        var blob_hash: Hash = undefined;
        @memcpy(&blob_hash, try reader.take(blob_hash.len));

        if (last_key) |prev| {
            if (key < prev) return error.CorruptIndexPage;
        }
        last_key = key;

        try entries.append(alloc, .{
            .key = key,
            .path = path,
            .blob_hash = blob_hash,
            .size = try reader.takeInt(u64, .little),
            .mode = try reader.takeInt(u64, .little),
            .mtime = try reader.takeInt(i128, .little),
        });
    }

    return .{ .leaf = entries };
}

fn parseInternalPage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8) !Page {
    const count = std.mem.readInt(u16, bytes[2..4], .little);
    if (count == 0) return error.CorruptIndexPage;

    var reader = std.Io.Reader.fixed(bytes[internal_header_len..]);
    var children: std.ArrayList(ChildRef) = .empty;
    errdefer children.deinit(alloc);

    var last_separator: ?PathKey = null;
    for (0..count) |_| {
        const separator = try reader.takeInt(u64, .little);
        if (last_separator) |prev| {
            if (separator < prev) return error.CorruptIndexPage;
        }
        last_separator = separator;

        var page_hash: Hash = undefined;
        @memcpy(&page_hash, try reader.take(page_hash.len));
        try children.append(alloc, .{ .separator = separator, .page_hash = page_hash });
    }

    return .{ .internal = children };
}

fn readIndexRoot(dir: std.fs.Dir) !Hash {
    const file = try dir.openFile("index/index_root", .{});
    defer file.close();

    var root: Hash = undefined;
    var reader_buf: [32]u8 = undefined;
    var file_reader = file.readerStreaming(&reader_buf);
    @memcpy(&root, try file_reader.interface.take(root.len));

    if (file_reader.interface.takeByte()) |_| return error.CorruptIndex else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    return root;
}

fn writeLeafEntry(writer: *std.Io.Writer, entry: LeafEntry) !void {
    try writer.writeInt(u64, entry.key, .little);
    try writer.writeInt(u16, @intCast(entry.path.len), .little);
    try writer.writeAll(entry.path);
    try writer.writeAll(&entry.blob_hash);
    try writer.writeInt(u64, entry.size, .little);
    try writer.writeInt(u64, entry.mode, .little);
    try writer.writeInt(i128, entry.mtime, .little);
}

fn leafEntrySize(entry: Entry) usize {
    return min_leaf_entry_len + entry.path.len;
}

fn pagePath(buf: *[page_rel_path_len]u8, page_hash: Hash) []const u8 {
    var hex_buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{page_hash}) catch unreachable;
    return std.fmt.bufPrint(buf, "index/pages/{s}/{s}/{s}", .{
        hex[0..2],
        hex[2..4],
        hex,
    }) catch unreachable;
}

fn pageDirPath(buf: *[page_dir_path_len]u8, page_hash: Hash) []const u8 {
    var hex_buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{page_hash}) catch unreachable;
    return std.fmt.bufPrint(buf, "index/pages/{s}/{s}", .{
        hex[0..2],
        hex[2..4],
    }) catch unreachable;
}

fn clearEntries(index: *Index) void {
    for (index.entries.items) |*entry| {
        entry.deinit(index.alloc);
    }
    index.entries.clearRetainingCapacity();
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPath;
    if (path.len > std.math.maxInt(u16)) return error.InvalidPath;
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

fn entryKeyLessThan(_: void, lhs: Entry, rhs: Entry) bool {
    const lhs_key = pathKey(lhs.path);
    const rhs_key = pathKey(rhs.path);
    if (lhs_key == rhs_key) return std.mem.lessThan(u8, lhs.path, rhs.path);
    return lhs_key < rhs_key;
}

test "pathKey is deterministic big-endian prefix" {
    const h = hash_mod.blake3("src/main.zig");
    var expected: PathKey = 0;
    for (h[0..8]) |byte| expected = (expected << 8) | byte;
    try std.testing.expectEqual(expected, pathKey("src/main.zig"));
}

test "index save and load round-trip through page store" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const nodus_dir = try tmp_dir.dir.makeOpenPath(".nodus", .{});

    var index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();
    try index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "src/main.zig"),
        .blob_hash = hash_mod.blake3("main"),
        .size = 4,
        .mode = 0o100644,
        .mtime = 123,
    });
    try index.save();

    try tmp_dir.dir.access(".nodus/index/index_root", .{});
    try std.testing.expect(!std.mem.eql(u8, &index.index_root, &hash_mod.ZERO_HASH));

    const read_dir = try tmp_dir.dir.openDir(".nodus", .{});
    var loaded = Index{ .alloc = alloc, .dir = read_dir, .entries = .empty };
    defer loaded.deinit();
    try loaded.load();

    try std.testing.expectEqualSlices(u8, &index.index_root, &loaded.index_root);
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
    try std.testing.expectEqualStrings("src/main.zig", loaded.entries.items[0].path);
    try std.testing.expectEqualSlices(u8, &hash_mod.blake3("main"), &loaded.entries.items[0].blob_hash);
    try std.testing.expectEqual(@as(u64, 4), loaded.entries.items[0].size);
    try std.testing.expectEqual(@as(u64, 0o100644), loaded.entries.items[0].mode);
    try std.testing.expectEqual(@as(i128, 123), loaded.entries.items[0].mtime);
}

test "index writes multiple leaves behind internal root" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const nodus_dir = try tmp_dir.dir.makeOpenPath(".nodus", .{});

    var index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();

    for (0..140) |i| {
        const path = try std.fmt.allocPrint(alloc, "src/file-{d:0>3}.zig", .{i});
        try index.entries.append(alloc, .{
            .path = path,
            .blob_hash = hash_mod.blake3(path),
            .size = i,
            .mode = 0o100644,
            .mtime = @intCast(i),
        });
    }

    try index.save();

    var store = PageStore{ .alloc = alloc, .dir = index.dir };
    var root_page = try store.get(index.index_root);
    defer root_page.deinit(alloc);

    switch (root_page) {
        .internal => |children| try std.testing.expect(children.items.len > 1),
        .leaf => return error.ExpectedInternalRoot,
    }

    const read_dir = try tmp_dir.dir.openDir(".nodus", .{});
    var loaded = Index{ .alloc = alloc, .dir = read_dir, .entries = .empty };
    defer loaded.deinit();
    try loaded.load();
    try std.testing.expectEqual(@as(usize, 140), loaded.entries.items.len);
    try std.testing.expect(loaded.lookup("src/file-042.zig") != null);
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
