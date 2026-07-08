const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

pub const MAGIC: u32 = 0x4E_4F_44_55;
pub const VERSION: u8 = 1;

/// Fixed page size for all index pages. Must be large enough to hold at least
/// one entry plus headers.
pub const PAGE_SIZE: usize = 4096;

pub const LEAF_PAGE: u8 = 0x01;
pub const INTERNAL_PAGE: u8 = 0x02;

/// Derived key used for B-tree ordering and content-defined chunking.
pub const PathKey = u64;

// Layout constants for page paths (hex-encoded BLAKE3 hashes).
const PAGE_REL_PATH_LEN: usize = 11 + 1 + 2 + 1 + 2 + 1 + 64;
const PAGE_DIR_PATH_LEN: usize = 11 + 1 + 2 + 1 + 2;

// Header and element sizes.
const LEAF_HEADER_LEN: usize = 8;
const INTERNAL_HEADER_LEN: usize = 8;
const CHILD_REF_LEN: usize = 40;
const MIN_LEAF_ENTRY_LEN: usize = 8 + 2 + 32 + 8 + 8 + 16;

/// Content-defined chunking threshold for leaf pages.
/// When the low bits of an entry's key are all zero, the page is cut here.
/// Expected average: ~32 entries per leaf page.
const LEAF_BOUNDARY_MASK: u64 = 0x1F;

/// Content-defined chunking threshold for internal pages.
/// Expected average: ~16 children per internal page.
const INTERNAL_BOUNDARY_MASK: u64 = 0xF;

pub const DiffError = error{
    OutOfMemory,
    NotFound,
    HashMismatch,
    CorruptIndexPage,
    CorruptIndex,
    EndOfStream,
    ReadFailed,
} || std.fs.File.OpenError || std.fs.File.ReadError;

/// Represents a tracked file in the repository.
/// The `path` slice is owned by this struct and must be freed with `deinit`.
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

/// Serialized form of an entry as stored in a leaf page.
/// The `path` slice is owned and must be freed when the containing `Page` is deinitialized.
const LeafEntry = struct {
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

/// Reference to a child page from an internal node.
const ChildRef = struct {
    /// The minimum key contained in the child subtree.
    separator: PathKey,
    /// Content hash of the child page.
    page_hash: Hash,
};

/// In-memory representation of a parsed page.
/// Memory is managed by the allocator passed to `parsePage` and must be freed
/// with `Page.deinit`.
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

/// Worktree status of an indexed entry relative to the filesystem.
pub const WorktreeState = enum {
    clean,
    modified,
    deleted,
};

pub const ChangeKind = enum {
    added,
    removed,
    modified,
};

/// Describes a single change between two index states.
/// The `path` slice is owned and must be freed with `EntryChange.deinit`.
pub const EntryChange = struct {
    kind: ChangeKind,
    path: []u8,
    old_blob_hash: ?Hash = null,
    new_blob_hash: ?Hash = null,
    old_size: ?u64 = null,
    new_size: ?u64 = null,
    old_mode: ?u64 = null,
    new_mode: ?u64 = null,

    pub fn deinit(self: *EntryChange, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};

/// Release all memory associated with a slice of changes.
pub fn freeChanges(alloc: std.mem.Allocator, changes: []EntryChange) void {
    for (changes) |*c| c.deinit(alloc);
    alloc.free(changes);
}

/// Fold the first 8 bytes of a BLAKE3 digest into a big-endian u64.
/// Used for both path keys (B-tree ordering) and content-defined chunking.
pub fn foldHashPrefix(h: Hash) u64 {
    var key: u64 = 0;
    for (h[0..8]) |byte| {
        key = (key << 8) | byte;
    }
    return key;
}

/// Compute the B-tree key for a given path.
pub fn pathKey(path: []const u8) PathKey {
    return foldHashPrefix(hash_mod.blake3(path));
}

/// Test whether a key represents a content-defined chunk boundary.
fn isChunkBoundary(key: u64, mask: u64) bool {
    return (key & mask) == 0;
}

fn hashEq(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Manages persistent storage of fixed-size index pages.
/// Pages are stored in a sharded directory tree based on their hash.
pub const PageStore = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,

    /// Ensure the pages directory exists.
    pub fn ensure(self: *const PageStore) !void {
        try self.dir.makePath("index/pages");
        try self.dir.makePath(".tmp");
    }

    /// Write a page to the store if it doesn't already exist.
    /// Returns the content hash (which is also the key).
    pub fn put(self: *const PageStore, page_bytes: *const [PAGE_SIZE]u8) !Hash {
        try self.ensure();

        const page_hash = hash_mod.blake3(page_bytes);
        var path_buf: [PAGE_REL_PATH_LEN]u8 = undefined;
        const path = pageRelPath(&path_buf, page_hash);

        // Fast path: page already exists.
        if (self.dir.access(path, .{})) |_| {
            return page_hash;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        // Write to a temporary file and rename for atomicity.
        var rand_buf: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        const tmp_path = try std.fmt.allocPrint(self.alloc, ".tmp/{x}.idx", .{rand_buf});
        defer self.alloc.free(tmp_path);

        var file = try self.dir.createFile(tmp_path, .{});
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

        // Rename into place, creating parent directories if necessary.
        var dir_buf: [PAGE_DIR_PATH_LEN]u8 = undefined;
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

    /// Read a page from the store and verify its hash.
    pub fn getBytes(self: *const PageStore, page_hash: Hash) ![PAGE_SIZE]u8 {
        var path_buf: [PAGE_REL_PATH_LEN]u8 = undefined;
        const path = pageRelPath(&path_buf, page_hash);

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
        if (!hashEq(computed, page_hash)) return error.HashMismatch;
        return bytes;
    }

    /// Parse a page from disk into an in-memory representation.
    pub fn get(self: *const PageStore, page_hash: Hash) !Page {
        const bytes = try self.getBytes(page_hash);
        return parsePage(self.alloc, &bytes);
    }
};

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

    /// Load the index from disk. If no index exists, starts empty.
    pub fn load(self: *Index) !void {
        clearEntries(self);
        self.index_root = hash_mod.ZERO_HASH;

        const root = readIndexRoot(self.dir) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                // No existing index. Ensure in-memory state is consistent.
                std.mem.sort(Entry, self.entries.items, {}, entryPathLessThan);
                try self.rebuildPathIndex();
                return;
            },
            else => return err,
        };

        self.index_root = root;
        if (hashEq(root, hash_mod.ZERO_HASH)) return;

        var store = PageStore{ .alloc = self.alloc, .dir = self.dir };
        try self.collectPageEntries(&store, root);
        std.mem.sort(Entry, self.entries.items, {}, entryPathLessThan);
        try self.rebuildPathIndex();
    }

    /// Persist the current entries to disk as a Merkle B-tree.
    pub fn save(self: *Index) !void {
        // Ensure path-sorted order for deterministic output and path_index consistency.
        std.mem.sort(Entry, self.entries.items, {}, entryPathLessThan);
        try self.rebuildPathIndex();

        // Remove old root metadata and write new tree.
        self.dir.deleteFile("index") catch {};
        try self.dir.makePath("index/pages");

        const root = try self.writeTree();
        try writeIndexRoot(self.dir, root);
        self.index_root = root;
    }

    /// Look up an entry by its repository-relative path.
    pub fn lookup(self: *const Index, path: []const u8) ?Entry {
        const idx = self.path_index.get(path) orelse return null;
        return self.entries.items[idx];
    }

    /// Add or update a file in the index, reading from `repo_root/path`.
    /// The blob content is stored via `store`.
    pub fn addFile(self: *Index, store: *const Store, repo_root: []const u8, path: []const u8) !Hash {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, path });
        defer self.alloc.free(full_path);
        return self.addFileFromDir(store, cwd, full_path, path);
    }

    /// Add or update a file, reading from an explicit directory handle.
    pub fn addFileFromDir(
        self: *Index,
        store: *const Store,
        dir: std.fs.Dir,
        fs_path: []const u8,
        index_path: []const u8,
    ) !Hash {
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

    /// Determine whether a tracked entry matches the current worktree file.
    pub fn stateOf(self: *const Index, repo_root: []const u8, entry: Entry) !WorktreeState {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, entry.path });
        defer self.alloc.free(full_path);
        return self.stateOfInDir(cwd, full_path, entry);
    }

    /// Determine worktree state using an explicit directory handle.
    /// NOTE: Uses exact mtime comparison; some filesystems may not preserve
    /// nanosecond precision reliably.
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

    /// Compute entry-level changes between `other_root` and the current index root.
    /// Caller owns the returned slice; free with `freeChanges`.
    pub fn diffAgainst(self: *const Index, other_root: Hash) DiffError![]EntryChange {
        return diffRoots(self.alloc, self.dir, other_root, self.index_root);
    }

    fn rebuildPathIndex(self: *Index) !void {
        self.path_index.clearRetainingCapacity();
        try self.path_index.ensureTotalCapacity(self.alloc, @intCast(self.entries.items.len));
        for (self.entries.items, 0..) |entry, i| {
            self.path_index.putAssumeCapacity(entry.path, i);
        }
    }

    /// Serialize the current entries into a content-defined Merkle B-tree.
    fn writeTree(self: *Index) !Hash {
        if (self.entries.items.len == 0) return hash_mod.ZERO_HASH;

        var store = PageStore{ .alloc = self.alloc, .dir = self.dir };
        var level: std.ArrayList(ChildRef) = .empty;
        defer level.deinit(self.alloc);

        // Sort entries by B-tree key for page construction.
        const sorted_entries = try self.alloc.alloc(Entry, self.entries.items.len);
        defer self.alloc.free(sorted_entries);
        @memcpy(sorted_entries, self.entries.items);
        std.mem.sort(Entry, sorted_entries, {}, entryBtreeLessThan);

        // Build leaf pages.
        var offset: usize = 0;
        while (offset < sorted_entries.len) {
            var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
            page[0] = LEAF_PAGE;

            var writer = std.Io.Writer.fixed(page[LEAF_HEADER_LEN..]);
            const first_key = pathKey(sorted_entries[offset].path);
            var count: u16 = 0;

            while (offset < sorted_entries.len) {
                const entry = sorted_entries[offset];
                const needed = leafEntrySize(entry);
                if (needed > PAGE_SIZE - LEAF_HEADER_LEN) return error.IndexEntryTooLarge;

                // Hard page-size boundary: if we can't fit this entry and we've already
                // written at least one entry, start a new page.
                if (writer.end + needed > page.len - LEAF_HEADER_LEN and count > 0) break;

                try writeLeafEntry(&writer, LeafEntry.fromEntry(entry));
                count += 1;
                offset += 1;

                // Content-defined boundary: probabilistically cut here based on key.
                if (isChunkBoundary(pathKey(entry.path), LEAF_BOUNDARY_MASK)) break;
            }

            std.mem.writeInt(u16, page[2..4], count, .little);
            const page_hash = try store.put(&page);
            try level.append(self.alloc, .{
                .separator = first_key,
                .page_hash = page_hash,
            });
        }

        // Build internal levels until only the root remains.
        while (level.items.len > 1) {
            var next: std.ArrayList(ChildRef) = .empty;
            errdefer next.deinit(self.alloc);

            var child_offset: usize = 0;
            while (child_offset < level.items.len) {
                var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
                page[0] = INTERNAL_PAGE;

                var writer = std.Io.Writer.fixed(page[INTERNAL_HEADER_LEN..]);
                const first_separator = level.items[child_offset].separator;
                var child_count: u16 = 0;

                while (child_offset < level.items.len) {
                    // Hard boundary check.
                    if (writer.end + CHILD_REF_LEN > page.len - INTERNAL_HEADER_LEN and child_count > 0) break;

                    const child = level.items[child_offset];
                    try writer.writeInt(u64, child.separator, .little);
                    try writer.writeAll(&child.page_hash);
                    child_count += 1;
                    child_offset += 1;

                    // Content-defined boundary based on child page hash.
                    if (isChunkBoundary(foldHashPrefix(child.page_hash), INTERNAL_BOUNDARY_MASK)) break;
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

    /// Insert a new entry or replace an existing one, keeping `path_index` in sync.
    fn upsert(self: *Index, new_entry: Entry) !void {
        // If allocation fails after we've already mutated the entry array,
        // we must not leak the new path.
        errdefer {
            var owned = new_entry;
            owned.deinit(self.alloc);
        }

        if (self.path_index.get(new_entry.path)) |idx| {
            // Replace existing entry.
            try self.path_index.ensureUnusedCapacity(self.alloc, 1);
            const entry = &self.entries.items[idx];
            _ = self.path_index.remove(entry.path);
            entry.deinit(self.alloc);
            entry.* = new_entry;
            self.path_index.putAssumeCapacity(entry.path, idx);
            return;
        }

        // Append new entry.
        try self.path_index.ensureUnusedCapacity(self.alloc, 1);
        try self.entries.append(self.alloc, new_entry);
        const idx = self.entries.items.len - 1;
        self.path_index.putAssumeCapacity(self.entries.items[idx].path, idx);
    }
};

/// Diff two index-root hashes directly, without loading a full `Index`.
/// Useful for comparing commit index states.
/// Caller owns the returned slice; free with `freeChanges`.
pub fn diffRoots(alloc: std.mem.Allocator, dir: std.fs.Dir, old_root: Hash, new_root: Hash) DiffError![]EntryChange {
    var store = PageStore{ .alloc = alloc, .dir = dir };
    var changes: std.ArrayList(EntryChange) = .empty;
    errdefer {
        for (changes.items) |*c| c.deinit(alloc);
        changes.deinit(alloc);
    }

    try diffNodes(alloc, &store, old_root, new_root, &changes);
    return try changes.toOwnedSlice(alloc);
}

/// Recursively diff two subtrees.
/// NOTE: identical page hashes short-circuit without disk access.
fn diffNodes(
    alloc: std.mem.Allocator,
    store: *const PageStore,
    old_hash: Hash,
    new_hash: Hash,
    changes: *std.ArrayList(EntryChange),
) DiffError!void {
    if (hashEq(old_hash, new_hash)) return;

    const old_zero = hashEq(old_hash, hash_mod.ZERO_HASH);
    const new_zero = hashEq(new_hash, hash_mod.ZERO_HASH);
    if (old_zero and new_zero) return;
    if (old_zero) return collectSubtree(alloc, store, new_hash, .added, changes);
    if (new_zero) return collectSubtree(alloc, store, old_hash, .removed, changes);

    var old_page = try store.get(old_hash);
    defer old_page.deinit(alloc);
    var new_page = try store.get(new_hash);
    defer new_page.deinit(alloc);

    switch (old_page) {
        .leaf => |old_entries| switch (new_page) {
            .leaf => |new_entries| try diffLeafLists(alloc, old_entries.items, new_entries.items, changes),
            .internal => |new_children| {
                const new_flat = try flattenChildren(alloc, store, new_children.items);
                defer freeFlat(alloc, new_flat);
                try diffLeafLists(alloc, old_entries.items, new_flat, changes);
            },
        },
        .internal => |old_children| switch (new_page) {
            .leaf => |new_entries| {
                const old_flat = try flattenChildren(alloc, store, old_children.items);
                defer freeFlat(alloc, old_flat);
                try diffLeafLists(alloc, old_flat, new_entries.items, changes);
            },
            .internal => |new_children| try diffInternal(alloc, store, old_children.items, new_children.items, changes),
        },
    }
}

/// Diff two internal nodes by aligning matching prefixes/suffixes and recursing
/// into the mismatched middle region.
fn diffInternal(
    alloc: std.mem.Allocator,
    store: *const PageStore,
    old_children: []const ChildRef,
    new_children: []const ChildRef,
    changes: *std.ArrayList(EntryChange),
) DiffError!void {
    // Find matching prefix — these subtrees are identical and can be skipped.
    var old_lo: usize = 0;
    var old_hi: usize = old_children.len;
    var new_lo: usize = 0;
    var new_hi: usize = new_children.len;

    while (old_lo < old_hi and new_lo < new_hi and
        old_children[old_lo].separator == new_children[new_lo].separator and
        hashEq(old_children[old_lo].page_hash, new_children[new_lo].page_hash))
    {
        old_lo += 1;
        new_lo += 1;
    }

    // Find matching suffix.
    while (old_hi > old_lo and new_hi > new_lo and
        old_children[old_hi - 1].separator == new_children[new_hi - 1].separator and
        hashEq(old_children[old_hi - 1].page_hash, new_children[new_hi - 1].page_hash))
    {
        old_hi -= 1;
        new_hi -= 1;
    }

    // Recurse into aligned separators in the middle.
    var oi = old_lo;
    var nj = new_lo;
    while (oi < old_hi and nj < new_hi and old_children[oi].separator == new_children[nj].separator) {
        try diffNodes(alloc, store, old_children[oi].page_hash, new_children[nj].page_hash, changes);
        oi += 1;
        nj += 1;
    }

    // Any remaining misaligned region is flattened to leaf entries and diffed directly.
    if (oi < old_hi or nj < new_hi) {
        const old_flat = try flattenChildren(alloc, store, old_children[oi..old_hi]);
        defer freeFlat(alloc, old_flat);
        const new_flat = try flattenChildren(alloc, store, new_children[nj..new_hi]);
        defer freeFlat(alloc, new_flat);
        try diffLeafLists(alloc, old_flat, new_flat, changes);
    }
}

/// Three-way merge of two sorted leaf entry lists.
fn diffLeafLists(
    alloc: std.mem.Allocator,
    old: []const LeafEntry,
    new: []const LeafEntry,
    changes: *std.ArrayList(EntryChange),
) DiffError!void {
    var i: usize = 0;
    var j: usize = 0;

    while (i < old.len and j < new.len) {
        const oe = old[i];
        const ne = new[j];

        if (oe.key == ne.key and std.mem.eql(u8, oe.path, ne.path)) {
            if (!hashEq(oe.blob_hash, ne.blob_hash) or oe.size != ne.size or oe.mode != ne.mode) {
                try changes.append(alloc, .{
                    .kind = .modified,
                    .path = try alloc.dupe(u8, oe.path),
                    .old_blob_hash = oe.blob_hash,
                    .new_blob_hash = ne.blob_hash,
                    .old_size = oe.size,
                    .new_size = ne.size,
                    .old_mode = oe.mode,
                    .new_mode = ne.mode,
                });
            }
            i += 1;
            j += 1;
        } else if (oe.key < ne.key or (oe.key == ne.key and std.mem.lessThan(u8, oe.path, ne.path))) {
            try changes.append(alloc, .{
                .kind = .removed,
                .path = try alloc.dupe(u8, oe.path),
                .old_blob_hash = oe.blob_hash,
                .old_size = oe.size,
                .old_mode = oe.mode,
            });
            i += 1;
        } else {
            try changes.append(alloc, .{
                .kind = .added,
                .path = try alloc.dupe(u8, ne.path),
                .new_blob_hash = ne.blob_hash,
                .new_size = ne.size,
                .new_mode = ne.mode,
            });
            j += 1;
        }
    }

    while (i < old.len) : (i += 1) {
        try changes.append(alloc, .{
            .kind = .removed,
            .path = try alloc.dupe(u8, old[i].path),
            .old_blob_hash = old[i].blob_hash,
            .old_size = old[i].size,
            .old_mode = old[i].mode,
        });
    }
    while (j < new.len) : (j += 1) {
        try changes.append(alloc, .{
            .kind = .added,
            .path = try alloc.dupe(u8, new[j].path),
            .new_blob_hash = new[j].blob_hash,
            .new_size = new[j].size,
            .new_mode = new[j].mode,
        });
    }
}

/// Collect all entries under a subtree into a flat change list.
fn collectSubtree(
    alloc: std.mem.Allocator,
    store: *const PageStore,
    page_hash: Hash,
    kind: ChangeKind,
    changes: *std.ArrayList(EntryChange),
) DiffError!void {
    if (hashEq(page_hash, hash_mod.ZERO_HASH)) return;

    var page = try store.get(page_hash);
    defer page.deinit(alloc);

    switch (page) {
        .leaf => |entries| {
            for (entries.items) |e| {
                try changes.append(alloc, switch (kind) {
                    .added => .{
                        .kind = .added,
                        .path = try alloc.dupe(u8, e.path),
                        .new_blob_hash = e.blob_hash,
                        .new_size = e.size,
                        .new_mode = e.mode,
                    },
                    .removed => .{
                        .kind = .removed,
                        .path = try alloc.dupe(u8, e.path),
                        .old_blob_hash = e.blob_hash,
                        .old_size = e.size,
                        .old_mode = e.mode,
                    },
                    .modified => unreachable,
                });
            }
        },
        .internal => |children| {
            for (children.items) |child| {
                try collectSubtree(alloc, store, child.page_hash, kind, changes);
            }
        },
    }
}

/// Flatten a slice of child references into a sorted leaf entry array.
fn flattenChildren(alloc: std.mem.Allocator, store: *const PageStore, children: []const ChildRef) DiffError![]LeafEntry {
    var out: std.ArrayList(LeafEntry) = .empty;
    errdefer {
        for (out.items) |*e| alloc.free(e.path);
        out.deinit(alloc);
    }
    for (children) |child| {
        try flattenSubtree(alloc, store, child.page_hash, &out);
    }
    return try out.toOwnedSlice(alloc);
}

/// Recursively append all leaf entries under a page hash to `out`.
fn flattenSubtree(
    alloc: std.mem.Allocator,
    store: *const PageStore,
    page_hash: Hash,
    out: *std.ArrayList(LeafEntry),
) DiffError!void {
    if (hashEq(page_hash, hash_mod.ZERO_HASH)) return;

    var page = try store.get(page_hash);
    defer page.deinit(alloc);

    switch (page) {
        .leaf => |entries| {
            for (entries.items) |e| {
                try out.append(alloc, .{
                    .key = e.key,
                    .path = try alloc.dupe(u8, e.path),
                    .blob_hash = e.blob_hash,
                    .size = e.size,
                    .mode = e.mode,
                    .mtime = e.mtime,
                });
            }
        },
        .internal => |children| {
            for (children.items) |child| {
                try flattenSubtree(alloc, store, child.page_hash, out);
            }
        },
    }
}

fn freeFlat(alloc: std.mem.Allocator, entries: []LeafEntry) void {
    for (entries) |*e| alloc.free(e.path);
    alloc.free(entries);
}

fn parsePage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8) DiffError!Page {
    return switch (bytes[0]) {
        LEAF_PAGE => try parseLeafPage(alloc, bytes),
        INTERNAL_PAGE => try parseInternalPage(alloc, bytes),
        else => error.CorruptIndexPage,
    };
}

fn parseLeafPage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8) DiffError!Page {
    const count = std.mem.readInt(u16, bytes[2..4], .little);
    var reader = std.Io.Reader.fixed(bytes[LEAF_HEADER_LEN..]);
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

        // Enforce sorted order invariant.
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

fn parseInternalPage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8) DiffError!Page {
    const count = std.mem.readInt(u16, bytes[2..4], .little);
    if (count == 0) return error.CorruptIndexPage;

    var reader = std.Io.Reader.fixed(bytes[INTERNAL_HEADER_LEN..]);
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
    return MIN_LEAF_ENTRY_LEN + entry.path.len;
}

fn readIndexRoot(dir: std.fs.Dir) DiffError!Hash {
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

fn pageRelPath(buf: *[PAGE_REL_PATH_LEN]u8, page_hash: Hash) []const u8 {
    var hex_buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{page_hash}) catch unreachable;
    return std.fmt.bufPrint(buf, "index/pages/{s}/{s}/{s}", .{
        hex[0..2],
        hex[2..4],
        hex,
    }) catch unreachable;
}

fn pageDirPath(buf: *[PAGE_DIR_PATH_LEN]u8, page_hash: Hash) []const u8 {
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
    index.path_index.clearRetainingCapacity();
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

/// Sort by repository-relative path (lexicographic).
fn entryPathLessThan(_: void, lhs: Entry, rhs: Entry) bool {
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

/// Sort by B-tree key (hash-derived), falling back to path for stability.
fn entryBtreeLessThan(_: void, lhs: Entry, rhs: Entry) bool {
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
