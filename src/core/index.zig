const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");

const format = @import("index/format.zig");
const entry_mod = @import("index/entry.zig");
const page_store_mod = @import("index/page_store.zig");
const btree = @import("index/btree.zig");
const entry_diff = @import("index/entry_diff.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

pub const MAGIC = format.MAGIC;
pub const VERSION = format.VERSION;
pub const PAGE_SIZE = format.PAGE_SIZE;
pub const LEAF_PAGE = format.LEAF_PAGE;
pub const INTERNAL_PAGE = format.INTERNAL_PAGE;
pub const PathKey = format.PathKey;
pub const DiffError = format.DiffError;
pub const LeafEntry = format.LeafEntry;
pub const ChildRef = format.ChildRef;
pub const Page = format.Page;
pub const hashEq = format.hashEq;
pub const foldHashPrefix = format.foldHashPrefix;

pub const Entry = entry_mod.Entry;
pub const WorktreeState = entry_mod.WorktreeState;
pub const ChangeKind = entry_mod.ChangeKind;
pub const EntryChange = entry_mod.EntryChange;
pub const freeChanges = entry_mod.freeChanges;
pub const pathKey = entry_mod.pathKey;

pub const PageStore = page_store_mod.PageStore;

pub const diffRoots = entry_diff.diffRoots;

/// The primary in-memory index of tracked files.
///
/// Maintains:
/// - `entries`: A sorted list of all tracked entries (by path).
/// - `path_index`: A hash map for O(1) path lookups.
/// - `index_root`: The BLAKE3 hash of the root page of the serialized B-tree.
pub const Index = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    entries: std.ArrayList(Entry),
    /// path -> index into `entries`. Updated by `upsert()` and `rebuildPathIndex()`.
    path_index: std.StringHashMapUnmanaged(usize) = .empty,
    index_root: Hash = hash_mod.ZERO_HASH,

    /// Open an index in `repo_root/.nodus`, creating the directory if needed.
    pub fn init(alloc: std.mem.Allocator, repo_root: []const u8) !Index {
        return initInDir(alloc, std.fs.cwd(), repo_root);
    }

    /// Same as `init`, but resolves `repo_root` against `base_dir` instead
    /// of assuming the real process cwd. This lets Repository (and tests)
    /// open a repo rooted anywhere, e.g. inside a `std.testing.tmpDir`,
    /// without every other call site having to care.
    pub fn initInDir(alloc: std.mem.Allocator, base_dir: std.fs.Dir, repo_root: []const u8) !Index {
        const nodus_path = try std.fs.path.join(alloc, &.{ repo_root, ".nodus" });
        defer alloc.free(nodus_path);

        try base_dir.makePath(nodus_path);
        const dir = try base_dir.openDir(nodus_path, .{});

        return .{
            .alloc = alloc,
            .dir = dir,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Index) void {
        clearEntries(self);
        self.entries.deinit(self.alloc);
        self.path_index.deinit(self.alloc);
        self.dir.close();
    }

    /// Load the index from disk. If no index exists, starts empty
    pub fn load(self: *Index) !void {
        clearEntries(self);
        self.index_root = hash_mod.ZERO_HASH;

        const root = readIndexRoot(self.dir) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                // No existing index. Ensure in-memory state is consistent
                std.mem.sort(Entry, self.entries.items, {}, entry_mod.pathLessThan);
                try self.rebuildPathIndex();
                return;
            },
            else => return err,
        };

        self.index_root = root;
        if (format.hashEq(root, hash_mod.ZERO_HASH)) return;

        var store = PageStore{ .alloc = self.alloc, .dir = self.dir };
        try btree.collect(self.alloc, &store, root, &self.entries);
        std.mem.sort(Entry, self.entries.items, {}, entry_mod.pathLessThan);
        try self.rebuildPathIndex();
    }

    /// Persist the current entries to disk as a Merkle B-tree
    pub fn save(self: *Index) !void {
        // Ensure path-sorted order for deterministic output and path_index consistency
        std.mem.sort(Entry, self.entries.items, {}, entry_mod.pathLessThan);
        try self.rebuildPathIndex();

        // Remove old root metadata and write new tree
        self.dir.deleteFile("index") catch {};
        try self.dir.makePath("index/pages");

        var store = PageStore{ .alloc = self.alloc, .dir = self.dir };
        const root = try btree.build(self.alloc, &store, self.entries.items);
        try writeIndexRoot(self.dir, root);
        self.index_root = root;
    }

    /// Look up an entry by its repository-relative path
    pub fn lookup(self: *const Index, path: []const u8) ?Entry {
        const idx = self.path_index.get(path) orelse return null;
        return self.entries.items[idx];
    }

    /// Remove a tracked path from the index. Does not touch the worktree
    /// file — callers that want that too (e.g. `Repository.revert` undoing
    /// an addition) delete it themselves. Returns `error.NotFound` if the
    /// path isn't currently tracked
    pub fn remove(self: *Index, path: []const u8) !void {
        const idx = self.path_index.get(path) orelse return error.NotFound;
        var removed = self.entries.orderedRemove(idx);
        removed.deinit(self.alloc);
        try self.rebuildPathIndex();
    }

    /// Add or update a file in the index, reading from `repo_root/path`
    /// The blob content is stored via `store`
    pub fn addFile(self: *Index, store: *const Store, repo_root: []const u8, path: []const u8) !Hash {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, path });
        defer self.alloc.free(full_path);
        return self.addFileFromDir(store, cwd, full_path, path);
    }

    /// Add or update a file, reading from an explicit directory handle
    pub fn addFileFromDir(
        self: *Index,
        store: *const Store,
        dir: std.fs.Dir,
        fs_path: []const u8,
        index_path: []const u8,
    ) !Hash {
        try entry_mod.validatePath(index_path);

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

    /// Determine whether a tracked entry matches the current worktree file
    pub fn stateOf(self: *const Index, repo_root: []const u8, entry: Entry) !WorktreeState {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, entry.path });
        defer self.alloc.free(full_path);
        return self.stateOfInDir(cwd, full_path, entry);
    }

    /// Determine worktree state using an explicit directory handle
    /// NOTE: Uses exact mtime comparison; some filesystems may not preserve
    /// nanosecond precision reliably
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

    /// Compute entry-level changes between `other_root` and the current index root
    /// Caller owns the returned slice; free with `freeChanges`
    pub fn diffAgainst(self: *const Index, other_root: Hash) DiffError![]EntryChange {
        return entry_diff.diffRoots(self.alloc, self.dir, other_root, self.index_root);
    }

    fn rebuildPathIndex(self: *Index) !void {
        self.path_index.clearRetainingCapacity();
        try self.path_index.ensureTotalCapacity(self.alloc, @intCast(self.entries.items.len));
        for (self.entries.items, 0..) |e, i| {
            self.path_index.putAssumeCapacity(e.path, i);
        }
    }

    /// Insert a new entry or replace an existing one, keeping `path_index` in sync
    fn upsert(self: *Index, new_entry: Entry) !void {
        // If allocation fails after we've already mutated the entry array,
        // we must not leak the new path
        errdefer {
            var owned = new_entry;
            owned.deinit(self.alloc);
        }

        if (self.path_index.get(new_entry.path)) |idx| {
            // Replace existing entry
            try self.path_index.ensureUnusedCapacity(self.alloc, 1);
            const e = &self.entries.items[idx];
            _ = self.path_index.remove(e.path);
            e.deinit(self.alloc);
            e.* = new_entry;
            self.path_index.putAssumeCapacity(e.path, idx);
            return;
        }

        // Append new entry
        try self.path_index.ensureUnusedCapacity(self.alloc, 1);
        try self.entries.append(self.alloc, new_entry);
        const idx = self.entries.items.len - 1;
        self.path_index.putAssumeCapacity(self.entries.items[idx].path, idx);
    }
};

fn clearEntries(index: *Index) void {
    for (index.entries.items) |*entry| {
        entry.deinit(index.alloc);
    }
    index.entries.clearRetainingCapacity();
    index.path_index.clearRetainingCapacity();
}

fn readIndexRoot(dir: std.fs.Dir) format.DiffError!Hash {
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

fn writeIndexRoot(dir: std.fs.Dir, root: Hash) !void {
    dir.deleteFile("index") catch {};
    try dir.makePath("index");

    const tmp_name = "index/index_root.tmp";
    const final_name = "index/index_root";

    const file = try dir.createFile(tmp_name, .{ .truncate = true });
    var file_closed = false;
    defer if (!file_closed) file.close();
    errdefer {
        if (!file_closed) {
            file.close();
            file_closed = true;
        }
        dir.deleteFile(tmp_name) catch {};
    }

    try file.writeAll(&root);
    try file.sync();
    file.close();
    file_closed = true;

    dir.rename(tmp_name, final_name) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try dir.deleteFile(final_name);
            try dir.rename(tmp_name, final_name);
        },
        else => return err,
    };
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
    try std.testing.expect(!hashEq(index.index_root, hash_mod.ZERO_HASH));

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
    try std.testing.expect(!hashEq(hash1, hash2));
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

test "index lookup works after addFile without an intervening save" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "zzz.txt", .data = "z" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "aaa.txt", .data = "a" });

    var objects_dir = try tmp_dir.dir.makeOpenPath(".nodus/objects", .{});
    defer objects_dir.close();
    const nodus_dir = try tmp_dir.dir.openDir(".nodus", .{});

    var store = Store{ .dir = objects_dir, .alloc = alloc };
    var index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();

    // Insert lexicographically out of order (z before a). A binary-search
    // lookup over an unsorted `entries` array would fail to find "aaa.txt"
    // here; the path_index map must not care about ordering.
    _ = try index.addFileFromDir(&store, tmp_dir.dir, "zzz.txt", "zzz.txt");
    _ = try index.addFileFromDir(&store, tmp_dir.dir, "aaa.txt", "aaa.txt");

    try std.testing.expect(index.lookup("zzz.txt") != null);
    try std.testing.expect(index.lookup("aaa.txt") != null);
    try std.testing.expect(index.lookup("missing.txt") == null);
}

test "index upsert replaces an existing entry in place" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "v1" });
    var objects_dir = try tmp_dir.dir.makeOpenPath(".nodus/objects", .{});
    defer objects_dir.close();
    const nodus_dir = try tmp_dir.dir.openDir(".nodus", .{});

    var store = Store{ .dir = objects_dir, .alloc = alloc };
    var index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();

    _ = try index.addFileFromDir(&store, tmp_dir.dir, "note.txt", "note.txt");
    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "v2-longer" });
    _ = try index.addFileFromDir(&store, tmp_dir.dir, "note.txt", "note.txt");

    try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
    const entry = index.lookup("note.txt") orelse return error.ExpectedEntry;
    try std.testing.expectEqual(@as(u64, 9), entry.size);
}

test "index remove drops a tracked path and reports NotFound afterward" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const nodus_dir = try tmp_dir.dir.makeOpenPath(".nodus", .{});
    var index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();

    try index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "keep.txt"),
        .blob_hash = hash_mod.blake3("keep"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "drop.txt"),
        .blob_hash = hash_mod.blake3("drop"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try index.rebuildPathIndex();

    try index.remove("drop.txt");
    try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
    try std.testing.expect(index.lookup("drop.txt") == null);
    try std.testing.expect(index.lookup("keep.txt") != null);
    try std.testing.expectError(error.NotFound, index.remove("drop.txt"));
}

test "index diffAgainst short-circuits on identical roots" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const nodus_dir = try tmp_dir.dir.makeOpenPath(".nodus", .{});
    var index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();
    try index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "a.txt"),
        .blob_hash = hash_mod.blake3("a"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try index.save();

    const changes = try index.diffAgainst(index.index_root);
    defer freeChanges(alloc, changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "index diffAgainst detects added, removed, and modified entries" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const nodus_dir = try tmp_dir.dir.makeOpenPath(".nodus", .{});

    var old_index = Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer old_index.deinit();
    try old_index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "keep.txt"),
        .blob_hash = hash_mod.blake3("keep"),
        .size = 4,
        .mode = 0o100644,
        .mtime = 1,
    });
    try old_index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "remove.txt"),
        .blob_hash = hash_mod.blake3("remove"),
        .size = 6,
        .mode = 0o100644,
        .mtime = 1,
    });
    try old_index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "change.txt"),
        .blob_hash = hash_mod.blake3("before"),
        .size = 6,
        .mode = 0o100644,
        .mtime = 1,
    });
    try old_index.save();
    const old_root = old_index.index_root;

    const read_dir = try tmp_dir.dir.openDir(".nodus", .{});
    var new_index = Index{ .alloc = alloc, .dir = read_dir, .entries = .empty };
    defer new_index.deinit();
    try new_index.load();

    for (new_index.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.path, "remove.txt")) {
            var removed = new_index.entries.orderedRemove(i);
            removed.deinit(alloc);
            break;
        }
    }
    try new_index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "new.txt"),
        .blob_hash = hash_mod.blake3("new"),
        .size = 3,
        .mode = 0o100644,
        .mtime = 2,
    });
    for (new_index.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, "change.txt")) {
            entry.deinit(alloc);
            entry.* = .{
                .path = try alloc.dupe(u8, "change.txt"),
                .blob_hash = hash_mod.blake3("after"),
                .size = 6,
                .mode = 0o100644,
                .mtime = 3,
            };
        }
    }
    try new_index.save();

    const changes = try new_index.diffAgainst(old_root);
    defer freeChanges(alloc, changes);

    var saw_added = false;
    var saw_removed = false;
    var saw_modified = false;
    for (changes) |c| {
        if (c.kind == .added and std.mem.eql(u8, c.path, "new.txt")) saw_added = true;
        if (c.kind == .removed and std.mem.eql(u8, c.path, "remove.txt")) saw_removed = true;
        if (c.kind == .modified and std.mem.eql(u8, c.path, "change.txt")) saw_modified = true;
    }
    try std.testing.expect(saw_added);
    try std.testing.expect(saw_removed);
    try std.testing.expect(saw_modified);
    try std.testing.expectEqual(@as(usize, 3), changes.len);
}
