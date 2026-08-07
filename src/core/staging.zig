const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

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

pub const EntryIndex = @import("./staging/entry_index.zig").EntryIndex;

/// The staging area: tracks files staged for the next commit.
// NOTE:
/// Deliberately holds no Merkle tree and no page store of its own.
/// Earlier versions built and persisted a tree on every `save()`, into a
/// private "staging/pages" directory separate from the repository's
/// permanent "index/pages" store. That meant a staged tree's hash was
/// only ever resolvable in the store it was built into — committing had
/// to remember to re-materialize it into the permanent store, and any
/// path that forgot (or that read a staged hash before that step ran)
/// hit `error.NotFound` looking up pages that only existed in the other
/// store.
///
/// A flat, in-memory (persisted as a plain list, not a tree) entry list
/// removes the hazard entirely: there is nothing here that can be valid
/// in one store and missing from another, because nothing here is
/// store-addressed at all. The one Merkle tree Merk ever needs from
/// staged content is built on demand — directly into the repository's
/// shared, permanent `PageStore` — at the two moments that actually need
/// a hash: committing, and diffing staged vs. HEAD (see
/// `Repository.stagingTreeRoot`, `Repository.commit`, `Repository.status`
/// in repo.zig). Because pages are content-addressed, rebuilding the same
/// entries repeatedly is cheap — `PageStore.put` skips any page that's
/// already on disk — so there's no real cost to never caching the root
/// here.
///
/// On-disk layout, rooted at `staging_dir`:
/// ```md
/// staging/
/// └── entries   <- flat, length-prefixed serialization of the entry list
/// ```
///
/// In-memory bookkeeping — the sorted entry list and the path -> index
pub const Staging = struct {
    alloc: Allocator,
    fs: Vfs,
    /// Where the staging area's on-disk state (the `entries` file)
    /// lives, relative to `fs`'s root. Typically ".merk/staging" when
    /// `fs` is rooted at the repo root.
    dir: ComponentDir,
    index: EntryIndex,

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

        const entries_path = try self.dir.join(self.alloc, "entries");
        defer self.alloc.free(entries_path);

        const bytes = (try self.fs.readFile(self.alloc, entries_path)) orelse {
            // Nothing on disk yet — ensure in-memory state is consistent.
            try self.index.sortAndReindex();
            return;
        };
        defer self.alloc.free(bytes);

        try deserializeEntries(self.alloc, bytes, &self.index.entries);
        try self.index.sortAndReindex();
    }

    /// Persist the current entries to disk as a flat list. No Merkle
    /// tree is built or written here — see the type doc comment above.
    pub fn save(self: *Staging) !void {
        // Ensure path-sorted order for deterministic output and path_index consistency.
        try self.index.sortAndReindex();

        const bytes = try serializeEntries(self.alloc, self.index.allEntries());
        defer self.alloc.free(bytes);

        const entries_path = try self.dir.join(self.alloc, "entries");
        defer self.alloc.free(entries_path);
        try self.fs.writeFile(self.alloc, entries_path, bytes);
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

    /// Discard current entries and replace with `entries`, then persist.
    /// Takes ownership of `entries` (each `Entry.path` is freed by this
    /// `Staging`'s later `deinit`/`remove`/replace, same as any other
    /// staged entry) — callers should not free `entries[i].path`
    /// themselves after this call, and must not reuse the backing slice.
    pub fn replaceAll(self: *Staging, entries: []Entry) !void {
        self.index.clear();
        for (entries) |e| try self.index.entries.append(self.alloc, e);
        try self.index.sortAndReindex();
        try self.save();
    }
};

/// Flat serialization: `u32` entry count, then per entry —
/// `u32` path length, path bytes, 32-byte blob hash, `u64` size (LE),
/// `u64` mode (LE), `i128` mtime (LE). Field widths match `Entry`'s own
/// types exactly (and the same widths `node.zig`'s leaf-entry wire
/// format already uses for size/mode/mtime) — no narrowing casts. No
/// tree structure, no page chunking — this is just "the list," written
/// out plainly.
fn serializeEntries(alloc: Allocator, entries: []const Entry) ![]u8 {
    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, @intCast(entries.len), .little);
    try out.appendSlice(alloc, &count_buf);

    for (entries) |e| {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(e.path.len), .little);
        try out.appendSlice(alloc, &len_buf);
        try out.appendSlice(alloc, e.path);
        try out.appendSlice(alloc, &e.blob_hash);

        var size_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &size_buf, e.size, .little);
        try out.appendSlice(alloc, &size_buf);

        var mode_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &mode_buf, e.mode, .little);
        try out.appendSlice(alloc, &mode_buf);

        var mtime_buf: [16]u8 = undefined;
        std.mem.writeInt(i128, &mtime_buf, e.mtime, .little);
        try out.appendSlice(alloc, &mtime_buf);
    }

    return try out.toOwnedSlice(alloc);
}

fn deserializeEntries(alloc: Allocator, bytes: []const u8, out: *ArrayList(Entry)) !void {
    if (bytes.len < 4) return error.CorruptStagingEntries;
    var pos: usize = 0;

    const entry_count = std.mem.readInt(u32, bytes[0..4], .little);
    pos += 4;

    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        if (pos + 4 > bytes.len) return error.CorruptStagingEntries;
        const path_len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;

        if (pos + path_len > bytes.len) return error.CorruptStagingEntries;
        const path = try alloc.dupe(u8, bytes[pos..][0..path_len]);
        errdefer alloc.free(path);
        pos += path_len;

        if (pos + 32 > bytes.len) return error.CorruptStagingEntries;
        var blob_hash: Hash = undefined;
        @memcpy(&blob_hash, bytes[pos..][0..32]);
        pos += 32;

        if (pos + 8 > bytes.len) return error.CorruptStagingEntries;
        const size = std.mem.readInt(u64, bytes[pos..][0..8], .little);
        pos += 8;

        if (pos + 8 > bytes.len) return error.CorruptStagingEntries;
        const mode = std.mem.readInt(u64, bytes[pos..][0..8], .little);
        pos += 8;

        if (pos + 16 > bytes.len) return error.CorruptStagingEntries;
        const mtime = std.mem.readInt(i128, bytes[pos..][0..16], .little);
        pos += 16;

        try out.append(alloc, .{
            .path = path,
            .blob_hash = blob_hash,
            .size = size,
            .mode = mode,
            .mtime = mtime,
        });
    }
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
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));
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

test "staging save and load round-trip as a flat list" {
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

    try testing.expect(mem_fs.hasFile("merk/entries"));
    try testing.expect(!mem_fs.hasFile("merk/root"));

    var loaded = Staging.init(alloc, mem_fs.fs(), "merk");
    defer loaded.deinit();
    try loaded.load();

    try testing.expectEqual(@as(usize, 1), loaded.index.entries.items.len);
    try testing.expectEqualStrings("src/main.zig", loaded.index.entries.items[0].path);
    try testing.expectEqualSlices(u8, &crypto.blake3("main"), &loaded.index.entries.items[0].blob_hash);
    try testing.expectEqual(@as(u64, 4), loaded.index.entries.items[0].size);
    try testing.expectEqual(@as(u64, 0o100644), loaded.index.entries.items[0].mode);
    try testing.expectEqual(@as(i128, 123), loaded.index.entries.items[0].mtime);
}

test "staging save and load round-trip many entries out of insertion order" {
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

    var loaded = Staging.init(alloc, mem_fs.fs(), "merk");
    defer loaded.deinit();
    try loaded.load();
    try testing.expectEqual(@as(usize, 140), loaded.index.entries.items.len);
    try testing.expect(loaded.lookup("src/file-042.zig") != null);
}

test "staging replaceAll discards current entries and persists the replacement" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();
    try staging.put(.{
        .path = try alloc.dupe(u8, "old.txt"),
        .blob_hash = crypto.blake3("old"),
        .size = 3,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.save();

    var replacement: ArrayList(Entry) = .empty;
    try replacement.append(alloc, .{
        .path = try alloc.dupe(u8, "new.txt"),
        .blob_hash = crypto.blake3("new"),
        .size = 3,
        .mode = 0o100644,
        .mtime = 2,
    });
    try staging.replaceAll(replacement.items);
    replacement.deinit(alloc); // ownership of each entry's .path moved into staging.index

    try testing.expectEqual(@as(usize, 1), staging.count());
    try testing.expect(staging.lookup("old.txt") == null);
    try testing.expect(staging.lookup("new.txt") != null);

    var loaded = Staging.init(alloc, mem_fs.fs(), "merk");
    defer loaded.deinit();
    try loaded.load();
    try testing.expectEqual(@as(usize, 1), loaded.count());
    try testing.expect(loaded.lookup("new.txt") != null);
}

test "staging replaceAll with an empty slice clears staging (force reinit path)" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();
    try staging.put(.{
        .path = try alloc.dupe(u8, "a.txt"),
        .blob_hash = crypto.blake3("a"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.save();

    // This is the exact call `Repository.init(force=true)` makes — no
    // Merkle tree, no zero_hash, no store lookup involved at all, so
    // there's nothing here to crash the way the original bug did.
    try staging.replaceAll(&.{});

    try testing.expectEqual(@as(usize, 0), staging.count());
}
