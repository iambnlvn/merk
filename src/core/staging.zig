const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const crypto = @import("crypto");
const storage = @import("storage");
const merkle_mod = @import("merkle");

const Store = @import("object.zig").Store;
const ComponentDir = @import("./staging/repo_paths.zig").ComponentDir;

const Vfs = storage.Vfs;
const MemoryFs = storage.MemoryFs;
const OsFs = storage.OsFs;
const Hash = crypto.Hash;
const Entry = merkle_mod.Entry;
const WorktreeState = merkle_mod.WorktreeState;
const EntryChange = merkle_mod.EntryChange;
const hashEq = merkle_mod.hashEq;
const PageStore = merkle_mod.PageStore;

pub const EntryIndex = @import("./staging/entry_index.zig").EntryIndex;

/// The staging area: tracks files staged for the next commit.
///
/// On-disk layout, rooted at `staging_dir`:
/// ```md
/// staging/
/// ├── root   <- BLAKE3 hash of the root page of the serialized B-tree
/// └── pages/ <- the B-tree's serialized pages, keyed by hash
/// ```
///
/// In-memory bookkeeping — the sorted entry list and the path -> index
/// lookup map — is delegated to `EntryIndex`. `Staging` itself owns
/// disk I/O (loading/persisting `root` and the page store) and the
/// Merkle-tree operations (build/collect/diff) layered on top of it.
pub const Staging = struct {
    alloc: Allocator,
    fs: Vfs,
    /// Where the staging area's on-disk state (`root` file, page
    /// store) lives, relative to `fs`'s root. Typically ".merk/staging"
    /// when `fs` is rooted at the repo root.
    dir: ComponentDir,
    index: EntryIndex,
    /// The BLAKE3 hash of the root page of the serialized B-tree.
    root: Hash = crypto.zero_hash,

    pub fn init(alloc: Allocator, fs: Vfs, staging_dir: []const u8) Staging {
        return .{
            .alloc = alloc,
            .fs = fs,
            .dir = ComponentDir.init(staging_dir),
            .index = EntryIndex.init(alloc),
        };
    }

    pub fn deinit(self: *Staging) void {
        self.index.deinit();
    }

    /// Load the staging area from disk. If none exists yet, starts empty.
    pub fn load(self: *Staging) !void {
        self.index.clear();
        self.root = crypto.zero_hash;

        const root_path = try self.dir.join(self.alloc, "root");
        defer self.alloc.free(root_path);

        const root = (try readRoot(self.fs, self.alloc, root_path)) orelse {
            // Nothing on disk yet — ensure in-memory state is consistent.
            try self.index.sortAndReindex();
            return;
        };

        self.root = root;
        if (hashEq(root, crypto.zero_hash)) return;

        const pages_dir = try self.dir.join(self.alloc, "pages");
        defer self.alloc.free(pages_dir);
        const store = PageStore.init(self.alloc, self.fs, pages_dir);

        try merkle_mod.collect(self.alloc, &store, root, &self.index.entries);
        try self.index.sortAndReindex();
    }

    /// Persist the current entries to disk as a Merkle B-tree.
    pub fn save(self: *Staging) !void {
        // Ensure path-sorted order for deterministic output and path_index consistency.
        try self.index.sortAndReindex();

        const pages_dir = try self.dir.join(self.alloc, "pages");
        defer self.alloc.free(pages_dir);
        const store = PageStore.init(self.alloc, self.fs, pages_dir);

        const root = try merkle_mod.build(self.alloc, &store, self.index.entries.items);

        const root_path = try self.dir.join(self.alloc, "root");
        defer self.alloc.free(root_path);
        try self.fs.writeFile(self.alloc, root_path, &root);

        self.root = root;
    }

    /// Look up a staged entry by its repository-relative path.
    pub fn lookup(self: *const Staging, path: []const u8) ?Entry {
        return self.index.lookup(path);
    }

    /// Remove a staged path. Does not touch the worktree file — callers
    /// that want that too (e.g. `Repository.revert` undoing an addition)
    /// delete it themselves. Returns `error.NotFound` if the path isn't
    /// currently staged.
    pub fn remove(self: *Staging, path: []const u8) !void {
        try self.index.remove(path);
    }

    /// Add or update a file in the staging area, reading from `repo_root/path`.
    /// The blob content is stored via `store`.
    pub fn addFile(
        self: *Staging,
        store: *const Store,
        repo_root: []const u8,
        path: []const u8,
    ) !Hash {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, path });
        defer self.alloc.free(full_path);
        return self.addFileFromDir(store, cwd, full_path, path);
    }

    /// Add or update a file, reading from an explicit directory handle.
    ///
    /// NOTE: this reads worktree files (arbitrary user content anywhere
    /// on disk), which is a different concern from the staging area's
    /// own storage above — it deliberately stays on `std.fs.Dir` rather
    /// than `Vfs`.
    pub fn addFileFromDir(
        self: *Staging,
        store: *const Store,
        dir: std.fs.Dir,
        fs_path: []const u8,
        staged_path: []const u8,
    ) !Hash {
        try merkle_mod.validatePath(staged_path);

        const file = try dir.openFile(fs_path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.kind != .file) return error.NotAFile;

        const blob_hash = try store.putReader(.blob, stat.size, file);

        try self.index.upsert(.{
            .path = try self.alloc.dupe(u8, staged_path),
            .blob_hash = blob_hash,
            .size = stat.size,
            .mode = stat.mode,
            .mtime = stat.mtime,
        });

        return blob_hash;
    }

    /// Determine whether a staged entry matches the current worktree file.
    pub fn stateOf(self: *const Staging, repo_root: []const u8, entry: Entry) !WorktreeState {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, entry.path });
        defer self.alloc.free(full_path);
        return self.stateOfInDir(cwd, full_path, entry);
    }

    /// Determine worktree state using an explicit directory handle.
    /// NOTE: Uses exact mtime comparison; some filesystems may not
    /// preserve nanosecond precision reliably.
    pub fn stateOfInDir(_: *const Staging, dir: std.fs.Dir, fs_path: []const u8, entry: Entry) !WorktreeState {
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

    /// Read-only view of every staged entry, sorted by path. Callers
    /// that just need to iterate (`status`, writing the worktree, ...)
    /// should use this instead of reaching into the staging area's
    /// internal storage directly — keeps `Staging` free to change how
    /// it stores entries without every caller breaking.
    pub fn allEntries(self: *const Staging) []const Entry {
        return self.index.allEntries();
    }

    /// Number of staged entries.
    pub fn count(self: *const Staging) usize {
        return self.index.count();
    }

    /// Insert or replace an entry directly — the entry-metadata-in-hand
    /// counterpart to `addFile`/`addFileFromDir`, for callers that
    /// already have an `Entry` rather than a worktree file to read
    /// (tests, or restoring entries from a snapshot). Does not persist;
    /// call `save()` when done.
    pub fn put(self: *Staging, entry: Entry) !void {
        try self.index.upsert(entry);
    }

    /// Discard current entries and reload from a commit snapshot's
    /// Merkle root, then persist — the "jump the staging area to match
    /// this snapshot" step behind `reset --mixed`/`--hard`. `page_store`
    /// is the store the snapshot's tree pages live in (may differ from
    /// the staging area's own on-disk page store).
    pub fn resetTo(self: *Staging, page_store: *const PageStore, snapshot_root: Hash) !void {
        self.index.clear();
        try merkle_mod.collect(self.alloc, page_store, snapshot_root, &self.index.entries);
        try self.index.sortAndReindex();
        try self.save();
    }

    /// Compute entry-level changes between `other_root` and the current
    /// staging root. Caller owns the returned slice; free with `freeChanges`.
    pub fn diffAgainst(self: *const Staging, other_root: Hash) merkle_mod.DiffError![]EntryChange {
        const pages_dir = try self.dir.join(self.alloc, "pages");
        defer self.alloc.free(pages_dir);
        const store = PageStore.init(self.alloc, self.fs, pages_dir);
        return merkle_mod.diffRoots(self.alloc, &store, other_root, self.root);
    }
};

fn readRoot(fs: Vfs, alloc: Allocator, path: []const u8) !?Hash {
    const bytes = (try fs.readFile(alloc, path)) orelse return null;
    defer alloc.free(bytes);

    if (bytes.len != @sizeOf(Hash)) return error.CorruptIndex;

    var root: Hash = undefined;
    @memcpy(&root, bytes[0..@sizeOf(Hash)]);
    return root;
}

test "staging save and load round-trip through page store" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();
    try staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "src/main.zig"),
        .blob_hash = crypto.blake3("main"),
        .size = 4,
        .mode = 0o100644,
        .mtime = 123,
    });
    try staging.save();

    try testing.expect(mem_fs.hasFile("merk/root"));
    try testing.expect(!hashEq(staging.root, crypto.zero_hash));

    var loaded = Staging.init(alloc, mem_fs.fs(), "merk");
    defer loaded.deinit();
    try loaded.load();

    try testing.expectEqualSlices(u8, &staging.root, &loaded.root);
    try testing.expectEqual(@as(usize, 1), loaded.index.entries.items.len);
    try testing.expectEqualStrings("src/main.zig", loaded.index.entries.items[0].path);
    try testing.expectEqualSlices(u8, &crypto.blake3("main"), &loaded.index.entries.items[0].blob_hash);
    try testing.expectEqual(@as(u64, 4), loaded.index.entries.items[0].size);
    try testing.expectEqual(@as(u64, 0o100644), loaded.index.entries.items[0].mode);
    try testing.expectEqual(@as(i128, 123), loaded.index.entries.items[0].mtime);
}

test "staging writes multiple leaves behind internal root" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    for (0..140) |i| {
        const path = try std.fmt.allocPrint(alloc, "src/file-{d:0>3}.zig", .{i});
        try staging.index.entries.append(alloc, .{
            .path = path,
            .blob_hash = crypto.blake3(path),
            .size = i,
            .mode = 0o100644,
            .mtime = @intCast(i),
        });
    }

    try staging.save();

    const store = PageStore.init(alloc, mem_fs.fs(), "merk/pages");
    var root_page = try store.get(staging.root);
    defer root_page.deinit(alloc);

    switch (root_page) {
        .internal => |children| try testing.expect(children.items.len > 1),
        .leaf => return error.ExpectedInternalRoot,
    }

    var loaded = Staging.init(alloc, mem_fs.fs(), "merk");
    defer loaded.deinit();
    try loaded.load();
    try testing.expectEqual(@as(usize, 140), loaded.index.entries.items.len);
    try testing.expect(loaded.lookup("src/file-042.zig") != null);
}

test "staging addFile stores blob and upserts entry" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "first" });

    var os_fs = OsFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, os_fs.fs(), "merk/objects");
    var staging = Staging.init(alloc, os_fs.fs(), "merk");
    defer staging.deinit();

    const hash1 = try staging.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");
    try testing.expectEqual(@as(usize, 1), staging.count());
    try testing.expect(object_store.exists(hash1));

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "second" });
    const hash2 = try staging.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");
    try testing.expectEqual(@as(usize, 1), staging.count());
    try testing.expect(!hashEq(hash1, hash2));
    try testing.expect(object_store.exists(hash2));
}

test "staging stateOf reports deleted file" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();
    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    const entry = Entry{
        .path = try alloc.dupe(u8, "missing.txt"),
        .blob_hash = crypto.blake3("missing"),
        .size = 7,
        .mode = 0o100644,
        .mtime = 123,
    };
    defer alloc.free(entry.path);

    try testing.expectEqual(WorktreeState.deleted, try staging.stateOfInDir(tmp_dir.dir, "missing.txt", entry));
}

test "staging lookup works after addFile without an intervening save" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "zzz.txt", .data = "z" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "aaa.txt", .data = "a" });

    var os_fs = OsFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, os_fs.fs(), "merk/objects");
    var staging = Staging.init(alloc, os_fs.fs(), "merk");
    defer staging.deinit();

    // Insert lexicographically out of order (z before a). A binary-search
    // lookup over an unsorted `entries` array would fail to find "aaa.txt"
    // here; the path_index map must not care about ordering.
    _ = try staging.addFileFromDir(&object_store, tmp_dir.dir, "zzz.txt", "zzz.txt");
    _ = try staging.addFileFromDir(&object_store, tmp_dir.dir, "aaa.txt", "aaa.txt");

    try testing.expect(staging.lookup("zzz.txt") != null);
    try testing.expect(staging.lookup("aaa.txt") != null);
    try testing.expect(staging.lookup("missing.txt") == null);
}

test "staging upsert replaces an existing entry in place" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "v1" });

    var os_fs = OsFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, os_fs.fs(), "merk/objects");
    var staging = Staging.init(alloc, os_fs.fs(), "merk");
    defer staging.deinit();

    _ = try staging.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");
    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "v2-longer" });
    _ = try staging.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");

    try testing.expectEqual(@as(usize, 1), staging.count());
    const entry = staging.lookup("note.txt") orelse return error.ExpectedEntry;
    try testing.expectEqual(@as(u64, 9), entry.size);
}

test "staging remove drops a tracked path and reports NotFound afterward" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    try staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "keep.txt"),
        .blob_hash = crypto.blake3("keep"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "drop.txt"),
        .blob_hash = crypto.blake3("drop"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.index.sortAndReindex();

    try staging.remove("drop.txt");
    try testing.expectEqual(@as(usize, 1), staging.count());
    try testing.expect(staging.lookup("drop.txt") == null);
    try testing.expect(staging.lookup("keep.txt") != null);
    try testing.expectError(error.NotFound, staging.remove("drop.txt"));
}

test "staging diffAgainst short-circuits on identical roots" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();
    try staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "a.txt"),
        .blob_hash = crypto.blake3("a"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.save();

    const changes = try staging.diffAgainst(staging.root);
    defer merkle_mod.freeChanges(alloc, changes);
    try testing.expectEqual(@as(usize, 0), changes.len);
}

test "staging diffAgainst detects added, removed, and modified entries" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var old_staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer old_staging.deinit();
    try old_staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "keep.txt"),
        .blob_hash = crypto.blake3("keep"),
        .size = 4,
        .mode = 0o100644,
        .mtime = 1,
    });
    try old_staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "remove.txt"),
        .blob_hash = crypto.blake3("remove"),
        .size = 6,
        .mode = 0o100644,
        .mtime = 1,
    });
    try old_staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "change.txt"),
        .blob_hash = crypto.blake3("before"),
        .size = 6,
        .mode = 0o100644,
        .mtime = 1,
    });
    try old_staging.save();
    const old_root = old_staging.root;

    var new_staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer new_staging.deinit();
    try new_staging.load();

    for (new_staging.index.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.path, "remove.txt")) {
            var removed = new_staging.index.entries.orderedRemove(i);
            removed.deinit(alloc);
            break;
        }
    }
    try new_staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "new.txt"),
        .blob_hash = crypto.blake3("new"),
        .size = 3,
        .mode = 0o100644,
        .mtime = 2,
    });
    for (new_staging.index.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, "change.txt")) {
            entry.deinit(alloc);
            entry.* = .{
                .path = try alloc.dupe(u8, "change.txt"),
                .blob_hash = crypto.blake3("after"),
                .size = 6,
                .mode = 0o100644,
                .mtime = 3,
            };
        }
    }
    try new_staging.save();

    const changes = try new_staging.diffAgainst(old_root);
    defer merkle_mod.freeChanges(alloc, changes);

    var saw_added = false;
    var saw_removed = false;
    var saw_modified = false;
    for (changes) |c| {
        if (c.kind == .added and std.mem.eql(u8, c.path, "new.txt")) saw_added = true;
        if (c.kind == .removed and std.mem.eql(u8, c.path, "remove.txt")) saw_removed = true;
        if (c.kind == .modified and std.mem.eql(u8, c.path, "change.txt")) saw_modified = true;
    }
    try testing.expect(saw_added);
    try testing.expect(saw_removed);
    try testing.expect(saw_modified);
    try testing.expectEqual(@as(usize, 3), changes.len);
}
