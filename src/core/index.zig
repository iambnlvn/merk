const std = @import("std");

const merk = @import("merk");
const merkle_mod = merk.merkle;
const object_mod = @import("object/object.zig");
const hash_mod = merk.crypto.hash;
const io = merk.io;

const Hash = hash_mod.Hash;
const Store = object_mod.Store;

/// The primary in-memory index of tracked files.
///
/// Maintains:
/// - `entries`: A sorted list of all tracked entries (by path).
/// - `path_index`: A hash map for O(1) path lookups.
/// - `index_root`: The BLAKE3 hash of the root page of the serialized B-tree.
pub const Index = struct {
    alloc: std.mem.Allocator,
    fs: io.FileSystem,
    /// Directory the index's on-disk state (index_root file, page store)
    /// lives under, relative to `fs`'s root. May be "" if `fs` is already
    /// rooted there. Mirrors `object.Store`'s `objects_dir` convention —
    /// typically ".merk" when `fs` is rooted at the repo root.
    index_dir: []const u8,
    entries: std.ArrayList(merkle_mod.Entry),
    /// path -> index into `entries`. Updated by `upsert()` and `rebuildPathIndex()`.
    path_index: std.StringHashMapUnmanaged(usize) = .empty,
    index_root: Hash = hash_mod.zero_hash,

    pub fn init(alloc: std.mem.Allocator, fs: io.FileSystem, index_dir: []const u8) Index {
        return .{ .alloc = alloc, .fs = fs, .index_dir = index_dir, .entries = .empty };
    }

    pub fn deinit(self: *Index) void {
        clearEntries(self);
        self.entries.deinit(self.alloc);
        self.path_index.deinit(self.alloc);
    }

    /// Load the index from disk. If no index exists, starts empty
    pub fn load(self: *Index) !void {
        clearEntries(self);
        self.index_root = hash_mod.zero_hash;

        const root_path = try self.subPath("index/index_root");
        defer self.alloc.free(root_path);

        const root = (try readIndexRoot(self.fs, self.alloc, root_path)) orelse {
            // No existing index. Ensure in-memory state is consistent
            std.mem.sort(merkle_mod.Entry, self.entries.items, {}, merkle_mod.pathLessThan);
            try self.rebuildPathIndex();
            return;
        };

        self.index_root = root;
        if (merkle_mod.hashEq(root, hash_mod.zero_hash)) return;

        const pages_dir = try self.subPath("index/pages");
        defer self.alloc.free(pages_dir);
        const store = merkle_mod.PageStore.init(self.alloc, self.fs, pages_dir);

        try merkle_mod.collect(self.alloc, &store, root, &self.entries);
        std.mem.sort(merkle_mod.Entry, self.entries.items, {}, merkle_mod.pathLessThan);
        try self.rebuildPathIndex();
    }

    /// Persist the current entries to disk as a Merkle B-tree
    pub fn save(self: *Index) !void {
        // Ensure path-sorted order for deterministic output and path_index consistency
        std.mem.sort(merkle_mod.Entry, self.entries.items, {}, merkle_mod.pathLessThan);
        try self.rebuildPathIndex();

        // Best-effort cleanup of a legacy single-file "index" blob from an
        // older on-disk format, which would otherwise block RealFs from
        // creating "index/" as a directory
        const legacy_index_path = try self.subPath("index");
        defer self.alloc.free(legacy_index_path);
        self.fs.deleteFile(legacy_index_path) catch {};

        const pages_dir = try self.subPath("index/pages");
        defer self.alloc.free(pages_dir);
        const store = merkle_mod.PageStore.init(self.alloc, self.fs, pages_dir);

        const root = try merkle_mod.build(self.alloc, &store, self.entries.items);

        const root_path = try self.subPath("index/index_root");
        defer self.alloc.free(root_path);
        try self.fs.writeFile(self.alloc, root_path, &root);

        self.index_root = root;
    }

    /// Look up an entry by its repository-relative path
    pub fn lookup(self: *const Index, path: []const u8) ?merkle_mod.Entry {
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

    /// Add or update a file, reading from an explicit directory handle.
    ///
    /// NOTE: this reads worktree files (arbitrary user content anywhere on
    /// disk), which is a different concern from the index's own storage
    /// above — it deliberately stays on `std.fs.Dir` rather than `io.FileSystem`
    pub fn addFileFromDir(
        self: *Index,
        store: *const Store,
        dir: std.fs.Dir,
        fs_path: []const u8,
        index_path: []const u8,
    ) !Hash {
        try merkle_mod.validatePath(index_path);

        const file = try dir.openFile(fs_path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.kind != .file) return error.NotAFile;

        const blob_hash = try store.putReader(.blob, stat.size, file);

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
    pub fn stateOf(self: *const Index, repo_root: []const u8, entry: merkle_mod.Entry) !merkle_mod.WorktreeState {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, entry.path });
        defer self.alloc.free(full_path);
        return self.stateOfInDir(cwd, full_path, entry);
    }

    /// Determine worktree state using an explicit directory handle
    /// NOTE: Uses exact mtime comparison; some filesystems may not preserve
    /// nanosecond precision reliably
    pub fn stateOfInDir(_: *const Index, dir: std.fs.Dir, fs_path: []const u8, entry: merkle_mod.Entry) !merkle_mod.WorktreeState {
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
    pub fn diffAgainst(self: *const Index, other_root: Hash) merkle_mod.DiffError![]merkle_mod.EntryChange {
        const pages_dir = try self.subPath("index/pages");
        defer self.alloc.free(pages_dir);
        const store = merkle_mod.PageStore.init(self.alloc, self.fs, pages_dir);
        return merkle_mod.diffRoots(self.alloc, &store, other_root, self.index_root);
    }

    /// Join `self.index_dir` with a sub-path, e.g. "index/pages" ->
    /// "<index_dir>/index/pages". Caller owns and must free the result.
    fn subPath(self: *const Index, sub: []const u8) ![]u8 {
        if (self.index_dir.len == 0) return self.alloc.dupe(u8, sub);
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.index_dir, sub });
    }

    fn rebuildPathIndex(self: *Index) !void {
        self.path_index.clearRetainingCapacity();
        try self.path_index.ensureTotalCapacity(self.alloc, @intCast(self.entries.items.len));
        for (self.entries.items, 0..) |e, i| {
            self.path_index.putAssumeCapacity(e.path, i);
        }
    }

    /// Insert a new entry or replace an existing one, keeping `path_index` in sync
    fn upsert(self: *Index, new_entry: merkle_mod.Entry) !void {
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

fn readIndexRoot(fs: io.FileSystem, alloc: std.mem.Allocator, path: []const u8) !?Hash {
    const bytes = (try fs.readFile(alloc, path)) orelse return null;
    defer alloc.free(bytes);

    if (bytes.len != @sizeOf(Hash)) return error.CorruptIndex;

    var root: Hash = undefined;
    @memcpy(&root, bytes[0..@sizeOf(Hash)]);
    return root;
}

test "index save and load round-trip through page store" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    var index = Index.init(alloc, tfs.fs(), "merk");
    defer index.deinit();
    try index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "src/main.zig"),
        .blob_hash = hash_mod.blake3("main"),
        .size = 4,
        .mode = 0o100644,
        .mtime = 123,
    });
    try index.save();

    try std.testing.expect(tfs.hasFile("merk/index/index_root"));
    try std.testing.expect(!merkle_mod.hashEq(index.index_root, hash_mod.zero_hash));

    var loaded = Index.init(alloc, tfs.fs(), "merk");
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
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    var index = Index.init(alloc, tfs.fs(), "merk");
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

    const store = merkle_mod.PageStore.init(alloc, tfs.fs(), "merk/index/pages");
    var root_page = try store.get(index.index_root);
    defer root_page.deinit(alloc);

    switch (root_page) {
        .internal => |children| try std.testing.expect(children.items.len > 1),
        .leaf => return error.ExpectedInternalRoot,
    }

    var loaded = Index.init(alloc, tfs.fs(), "merk");
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

    var real_fs = io.RealFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, real_fs.fs(), "merk/objects");
    var index = Index.init(alloc, real_fs.fs(), "merk");
    defer index.deinit();

    const hash1 = try index.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");
    try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
    try std.testing.expect(object_store.exists(hash1));

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "second" });
    const hash2 = try index.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");
    try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
    try std.testing.expect(!merkle_mod.hashEq(hash1, hash2));
    try std.testing.expect(object_store.exists(hash2));
}

test "index stateOf reports deleted file" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    var index = Index.init(alloc, tfs.fs(), "merk");
    defer index.deinit();

    const entry = merkle_mod.Entry{
        .path = try alloc.dupe(u8, "missing.txt"),
        .blob_hash = hash_mod.blake3("missing"),
        .size = 7,
        .mode = 0o100644,
        .mtime = 123,
    };
    defer alloc.free(entry.path);

    try std.testing.expectEqual(merkle_mod.WorktreeState.deleted, try index.stateOfInDir(tmp_dir.dir, "missing.txt", entry));
}

test "index lookup works after addFile without an intervening save" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "zzz.txt", .data = "z" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "aaa.txt", .data = "a" });

    var real_fs = io.RealFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, real_fs.fs(), "merk/objects");
    var index = Index.init(alloc, real_fs.fs(), "merk");
    defer index.deinit();

    // Insert lexicographically out of order (z before a). A binary-search
    // lookup over an unsorted `entries` array would fail to find "aaa.txt"
    // here; the path_index map must not care about ordering.
    _ = try index.addFileFromDir(&object_store, tmp_dir.dir, "zzz.txt", "zzz.txt");
    _ = try index.addFileFromDir(&object_store, tmp_dir.dir, "aaa.txt", "aaa.txt");

    try std.testing.expect(index.lookup("zzz.txt") != null);
    try std.testing.expect(index.lookup("aaa.txt") != null);
    try std.testing.expect(index.lookup("missing.txt") == null);
}

test "index upsert replaces an existing entry in place" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "v1" });

    var real_fs = io.RealFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, real_fs.fs(), "merk/objects");
    var index = Index.init(alloc, real_fs.fs(), "merk");
    defer index.deinit();

    _ = try index.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");
    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "v2-longer" });
    _ = try index.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");

    try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
    const entry = index.lookup("note.txt") orelse return error.ExpectedEntry;
    try std.testing.expectEqual(@as(u64, 9), entry.size);
}

test "index remove drops a tracked path and reports NotFound afterward" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    var index = Index.init(alloc, tfs.fs(), "merk");
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
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    var index = Index.init(alloc, tfs.fs(), "merk");
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
    defer merkle_mod.freeChanges(alloc, changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "index diffAgainst detects added, removed, and modified entries" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    var old_index = Index.init(alloc, tfs.fs(), "merk");
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

    var new_index = Index.init(alloc, tfs.fs(), "merk");
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
    defer merkle_mod.freeChanges(alloc, changes);

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
