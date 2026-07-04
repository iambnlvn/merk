//  Two passes on every changed file:
//    * Line-level unified diff  (for display, `nodus show`)
//    * Word-level diff          (for precision, intent classifier)
//
//  Neither pass requires the AST to work — they operate on raw source bytes.
//  The AST delta layer lives in an intent layer and consumes these results.
//

//  Myers     — O(ND) shortest edit script.  Minimal edits, can produce noisy
//              hunks when coincidental matches exist deep in changed regions
//
//  Patience  — Anchors the LCS on unique lines first (function signatures,
//              closing braces, etc), then recurses.  Produces human-readable
//              hunks on typical source code.  Falls back to Myers for segments
//              that have no unique anchors.
//
//  Histogram — uses occurrence-frequency buckets so rarer
//              lines are preferred as anchors even when not strictly unique
//              Degrades to Myers when the histogram finds nothing useful
//

const std = @import("std");

pub const Op = enum(u8) {
    eq = 0,
    ins = 1,
    del = 2,
};

const object_mod = @import("object.zig");
const tree_mod = @import("tree.zig");
const hash_mod = @import("hash.zig");
const commit_mod = @import("commit.zig");
const index_mod = @import("index.zig");

/// Diff the tree of `new_commit` against the tree of `old_commit`
/// Pass `null` for `old_commit` to diff against an empty tree, e.g. for
/// the root commit, where there is no parent to compare against
pub fn diffCommits(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    old_commit: ?hash_mod.Hash,
    new_commit: hash_mod.Hash,
    algo: Algorithm,
) !CommitDiff {
    var new_c = try commit_mod.read(alloc, store, new_commit);
    defer new_c.deinit(alloc);

    var old_tree: ?hash_mod.Hash = null;
    var old_c: ?commit_mod.Commit = null;
    defer if (old_c) |*c| c.deinit(alloc);

    if (old_commit) |oc| {
        old_c = try commit_mod.read(alloc, store, oc);
        old_tree = old_c.?.snapshot.tree;
    }

    return diffTreeHashes(alloc, store, old_tree, new_c.snapshot.tree, algo);
}

/// Diff commits whose snapshots point at index roots. If either root is not
/// present in the index page store, falls back to the legacy tree-object diff.
pub fn diffCommitsFromIndexRoots(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    old_commit: ?hash_mod.Hash,
    new_commit: hash_mod.Hash,
    algo: Algorithm,
) !CommitDiff {
    var new_c = try commit_mod.read(alloc, store, new_commit);
    defer new_c.deinit(alloc);

    var old_root: ?hash_mod.Hash = null;
    var old_c: ?commit_mod.Commit = null;
    defer if (old_c) |*c| c.deinit(alloc);

    if (old_commit) |oc| {
        old_c = try commit_mod.read(alloc, store, oc);
        old_root = old_c.?.snapshot.tree;
    }

    return diffSnapshotRoots(alloc, store, page_store, old_root, new_c.snapshot.tree, algo);
}

/// Diff `new_commit` against its first parent. If `new_commit` has no
/// parents (a root commit), diffs against an empty tree
pub fn diffCommitAgainstParent(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    new_commit: hash_mod.Hash,
    algo: Algorithm,
) !CommitDiff {
    var new_c = try commit_mod.read(alloc, store, new_commit);
    defer new_c.deinit(alloc);

    const old_tree: ?hash_mod.Hash = if (new_c.snapshot.parents.len > 0) blk: {
        var parent_c = try commit_mod.read(alloc, store, new_c.snapshot.parents[0]);
        defer parent_c.deinit(alloc);
        break :blk parent_c.snapshot.tree;
    } else null;

    return diffTreeHashes(alloc, store, old_tree, new_c.snapshot.tree, algo);
}

/// Diff `new_commit` against its first parent using index-root Merkle pruning.
/// Falls back to legacy tree-object diff when comparing old commits.
pub fn diffCommitAgainstParentFromIndexRoot(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    new_commit: hash_mod.Hash,
    algo: Algorithm,
) !CommitDiff {
    var new_c = try commit_mod.read(alloc, store, new_commit);
    defer new_c.deinit(alloc);

    const old_root: ?hash_mod.Hash = if (new_c.snapshot.parents.len > 0) blk: {
        var parent_c = try commit_mod.read(alloc, store, new_c.snapshot.parents[0]);
        defer parent_c.deinit(alloc);
        break :blk parent_c.snapshot.tree;
    } else null;

    return diffSnapshotRoots(alloc, store, page_store, old_root, new_c.snapshot.tree, algo);
}

/// Diff two trees directly. `old_tree == null` means "empty tree" (nothing
/// on the old side — every file in `new_tree` shows up as added)
pub fn diffTreeHashes(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    old_tree: ?hash_mod.Hash,
    new_tree: hash_mod.Hash,
    algo: Algorithm,
) !CommitDiff {
    const old_flat: []tree_mod.FlatEntry = if (old_tree) |t|
        try tree_mod.readToFlatEntries(alloc, store, t)
    else
        &[_]tree_mod.FlatEntry{};
    defer if (old_tree != null) tree_mod.freeFlatEntries(alloc, old_flat);

    const new_flat = try tree_mod.readToFlatEntries(alloc, store, new_tree);
    defer tree_mod.freeFlatEntries(alloc, new_flat);

    var blobs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (blobs.items) |b| alloc.free(b);
        blobs.deinit(alloc);
    }

    const old_snaps = try alloc.alloc(FileSnapshot, old_flat.len);
    defer alloc.free(old_snaps);
    for (old_flat, 0..) |e, i| {
        const obj = try store.get(e.hash);
        try blobs.append(alloc, obj.payload);
        old_snaps[i] = .{ .path = e.path, .content = obj.payload };
    }

    const new_snaps = try alloc.alloc(FileSnapshot, new_flat.len);
    defer alloc.free(new_snaps);
    for (new_flat, 0..) |e, i| {
        const obj = try store.get(e.hash);
        try blobs.append(alloc, obj.payload);
        new_snaps[i] = .{ .path = e.path, .content = obj.payload };
    }

    var cd = try diffCommitWith(alloc, old_snaps, new_snaps, algo);
    cd.blobs = try blobs.toOwnedSlice(alloc);
    return cd;
}

/// Diff two persisted index roots. Equal page hashes prune whole subtrees
/// without reading entries or blobs under that subtree.
pub fn diffIndexRoots(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    old_root: ?hash_mod.Hash,
    new_root: hash_mod.Hash,
    algo: Algorithm,
) !CommitDiff {
    var file_diffs: std.ArrayList(FileDiff) = .empty;
    var blobs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (file_diffs.items) |*f| f.deinit(alloc);
        file_diffs.deinit(alloc);
        for (blobs.items) |b| alloc.free(b);
        blobs.deinit(alloc);
    }

    const normalized_old = if (old_root) |root| root else hash_mod.ZERO_HASH;
    try diffIndexRecursive(
        alloc,
        store,
        page_store,
        maybeNonZero(normalized_old),
        maybeNonZero(new_root),
        algo,
        &file_diffs,
        &blobs,
    );

    const files = try file_diffs.toOwnedSlice(alloc);
    errdefer {
        for (files) |*f| f.deinit(alloc);
        alloc.free(files);
    }

    return .{
        .files = files,
        .line_diff_hash = .{0} ** 32,
        .word_diff_hash = .{0} ** 32,
        .blobs = try blobs.toOwnedSlice(alloc),
    };
}

fn diffSnapshotRoots(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    old_root: ?hash_mod.Hash,
    new_root: hash_mod.Hash,
    algo: Algorithm,
) !CommitDiff {
    const old_is_index = if (old_root) |root| rootLooksLikeIndexRoot(page_store, root) else true;
    const new_is_index = rootLooksLikeIndexRoot(page_store, new_root);

    if (old_is_index and new_is_index) {
        return diffIndexRoots(alloc, store, page_store, old_root, new_root, algo);
    }
    if (!old_is_index and !new_is_index) {
        return diffTreeHashes(alloc, store, old_root, new_root, algo);
    }

    return diffMixedSnapshotRoots(
        alloc,
        store,
        page_store,
        old_root,
        old_is_index,
        new_root,
        new_is_index,
        algo,
    );
}

pub const LineDelta = struct {
    op: Op,
    /// Line content, NOT including the trailing newline
    content: []const u8,
    /// 1-based line number in the old file (0 = not present in old)
    old_lineno: u32,
    /// 1-based line number in the new file (0 = not present in new)
    new_lineno: u32,
};

pub const WordDelta = struct {
    op: Op,
    word: []const u8,
    /// Which line (1-based in new file, or old file for deletions) this word
    /// belongs to.  Lets the renderer re-associate words with lines
    lineno: u32,
};

pub const FileDiff = struct {
    path: []const u8,
    line_deltas: []LineDelta,
    word_deltas: []WordDelta,

    lines_added: u32,
    lines_removed: u32,
    words_added: u32,
    words_removed: u32,

    pub fn deinit(self: *FileDiff, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.line_deltas);
        alloc.free(self.word_deltas);
    }
};

pub const CommitDiff = struct {
    files: []FileDiff,
    /// Hash of the serialized unified line diff (stored as a blob)
    line_diff_hash: [32]u8,
    /// Hash of the serialized word diff (stored as a blob)
    word_diff_hash: [32]u8,
    /// Backing blob buffers that FileDiff.line_deltas[].content slices
    /// point into. Owned by the CommitDiff for its whole lifetime —
    /// freeing these before deinit() dangles every content slice.
    blobs: [][]u8 = &.{},

    pub fn deinit(self: *CommitDiff, alloc: std.mem.Allocator) void {
        for (self.files) |*f| f.deinit(alloc);
        alloc.free(self.files);
        for (self.blobs) |b| alloc.free(b);
        alloc.free(self.blobs);
    }
};
/// A (path, content) snapshot of a single file
pub const FileSnapshot = struct {
    path: []const u8,
    content: []const u8,
};

pub const Algorithm = enum {
    myers,
    patience,
    histogram,
};

pub const Format = enum {
    unified,
    side_by_side,
    blocks,
    ops,
    summary,
};

pub const Level = enum {
    file,
    hunk,
    line,
    word,
};

pub const Context = union(enum) {
    exact: u32,
    minimal,
    normal,
    full,

    pub fn lines(self: Context) u32 {
        return switch (self) {
            .exact => |n| n,
            .minimal => 0,
            .normal => 3,
            .full => std.math.maxInt(u32),
        };
    }
};

pub const GroupBy = enum {
    none,
    files,
    dirs,
};

pub const FileStatus = enum { added, deleted, modified, unchanged };

pub const ChangeFilter = struct {
    show_added: bool = true,
    show_deleted: bool = true,
    show_modified: bool = true,

    pub fn allows(self: ChangeFilter, status: FileStatus) bool {
        return switch (status) {
            .added => self.show_added,
            .deleted => self.show_deleted,
            .modified => self.show_modified,
            .unchanged => false,
        };
    }

    pub fn parse(raw: []const u8) !ChangeFilter {
        var f = ChangeFilter{ .show_added = false, .show_deleted = false, .show_modified = false };
        var it = std.mem.splitScalar(u8, raw, ',');
        var seen = false;
        while (it.next()) |part| {
            seen = true;
            if (std.mem.eql(u8, part, "added")) {
                f.show_added = true;
            } else if (std.mem.eql(u8, part, "deleted")) {
                f.show_deleted = true;
            } else if (std.mem.eql(u8, part, "modified")) {
                f.show_modified = true;
            } else {
                return error.InvalidChangeFilter;
            }
        }
        if (!seen) return error.InvalidChangeFilter;
        return f;
    }
};

pub const RenderConfig = struct {
    format: Format = .unified,
    level: Level = .line,
    context: Context = .normal,
    group_by: GroupBy = .none,
    filter: ChangeFilter = .{},
    word_mode: bool = false,
    detect_moves: bool = false,
    max_width: u32 = 60,
    /// Which diff algorithm to use for line-level diffing
    algorithm: Algorithm = .histogram,

    pub fn contextLines(self: RenderConfig) u32 {
        return self.context.lines();
    }
};

pub fn diffFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    old_src: []const u8,
    new_src: []const u8,
) !FileDiff {
    return diffFileWith(alloc, path, old_src, new_src, .histogram);
}

pub fn diffFileWith(
    alloc: std.mem.Allocator,
    path: []const u8,
    old_src: []const u8,
    new_src: []const u8,
    algo: Algorithm,
) !FileDiff {
    const old_lines = try splitLines(alloc, old_src);
    defer alloc.free(old_lines);
    const new_lines = try splitLines(alloc, new_src);
    defer alloc.free(new_lines);

    const line_deltas = try runLineDiff(alloc, old_lines, new_lines, algo);
    errdefer alloc.free(line_deltas);

    var lines_added: u32 = 0;
    var lines_removed: u32 = 0;
    for (line_deltas) |d| switch (d.op) {
        .ins => lines_added += 1,
        .del => lines_removed += 1,
        .eq => {},
    };

    const word_deltas = try diffWords(alloc, line_deltas);
    errdefer alloc.free(word_deltas);

    var words_added: u32 = 0;
    var words_removed: u32 = 0;
    for (word_deltas) |d| switch (d.op) {
        .ins => words_added += 1,
        .del => words_removed += 1,
        .eq => {},
    };

    return .{
        .path = try alloc.dupe(u8, path),
        .line_deltas = line_deltas,
        .word_deltas = word_deltas,
        .lines_added = lines_added,
        .lines_removed = lines_removed,
        .words_added = words_added,
        .words_removed = words_removed,
    };
}

pub fn diffCommit(
    alloc: std.mem.Allocator,
    old_files: []const FileSnapshot,
    new_files: []const FileSnapshot,
) !CommitDiff {
    return diffCommitWith(alloc, old_files, new_files, .histogram);
}

pub fn diffCommitWith(
    alloc: std.mem.Allocator,
    old_files: []const FileSnapshot,
    new_files: []const FileSnapshot,
    algo: Algorithm,
) !CommitDiff {
    var file_diffs: std.ArrayList(FileDiff) = .empty;
    errdefer {
        for (file_diffs.items) |*f| f.deinit(alloc);
        file_diffs.deinit(alloc);
    }

    var oi: usize = 0;
    var ni: usize = 0;
    while (oi < old_files.len or ni < new_files.len) {
        const cmp: std.math.Order = blk: {
            if (oi >= old_files.len) break :blk .gt;
            if (ni >= new_files.len) break :blk .lt;
            break :blk std.mem.order(u8, old_files[oi].path, new_files[ni].path);
        };

        const path = if (cmp != .gt) old_files[oi].path else new_files[ni].path;
        const old_src = if (cmp != .gt) old_files[oi].content else "";
        const new_src = if (cmp != .lt) new_files[ni].content else "";

        if (!std.mem.eql(u8, old_src, new_src)) {
            const fd = try diffFileWith(alloc, path, old_src, new_src, algo);
            try file_diffs.append(alloc, fd);
        }

        if (cmp != .gt) oi += 1;
        if (cmp != .lt) ni += 1;
    }

    const files = try file_diffs.toOwnedSlice(alloc);
    return .{
        .files = files,
        .line_diff_hash = .{0} ** 32,
        .word_diff_hash = .{0} ** 32,
    };
}

fn maybeNonZero(hash: hash_mod.Hash) ?hash_mod.Hash {
    if (std.mem.eql(u8, &hash, &hash_mod.ZERO_HASH)) return null;
    return hash;
}

fn rootLooksLikeIndexRoot(page_store: *const index_mod.PageStore, root: hash_mod.Hash) bool {
    if (std.mem.eql(u8, &root, &hash_mod.ZERO_HASH)) return true;
    _ = page_store.getBytes(root) catch return false;
    return true;
}

fn diffMixedSnapshotRoots(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    old_root: ?hash_mod.Hash,
    old_is_index: bool,
    new_root: hash_mod.Hash,
    new_is_index: bool,
    algo: Algorithm,
) !CommitDiff {
    var blobs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (blobs.items) |blob| alloc.free(blob);
        blobs.deinit(alloc);
    }

    var old_index_entries: std.ArrayList(index_mod.LeafEntry) = .empty;
    defer freeLeafEntries(alloc, &old_index_entries);
    var new_index_entries: std.ArrayList(index_mod.LeafEntry) = .empty;
    defer freeLeafEntries(alloc, &new_index_entries);

    var old_flat: ?[]tree_mod.FlatEntry = null;
    defer if (old_flat) |entries| tree_mod.freeFlatEntries(alloc, entries);
    var new_flat: ?[]tree_mod.FlatEntry = null;
    defer if (new_flat) |entries| tree_mod.freeFlatEntries(alloc, entries);

    const old_files = try rootToFileSnapshots(
        alloc,
        store,
        page_store,
        old_root,
        old_is_index,
        &old_index_entries,
        &old_flat,
        &blobs,
    );
    defer alloc.free(old_files);

    const new_files = try rootToFileSnapshots(
        alloc,
        store,
        page_store,
        new_root,
        new_is_index,
        &new_index_entries,
        &new_flat,
        &blobs,
    );
    defer alloc.free(new_files);

    var cd = try diffCommitWith(alloc, old_files, new_files, algo);
    cd.blobs = try blobs.toOwnedSlice(alloc);
    return cd;
}

fn rootToFileSnapshots(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    root: ?hash_mod.Hash,
    is_index: bool,
    index_entries: *std.ArrayList(index_mod.LeafEntry),
    flat_entries: *?[]tree_mod.FlatEntry,
    blobs: *std.ArrayList([]u8),
) ![]FileSnapshot {
    const actual_root = if (root) |value| value else return alloc.alloc(FileSnapshot, 0);
    if (std.mem.eql(u8, &actual_root, &hash_mod.ZERO_HASH)) return alloc.alloc(FileSnapshot, 0);

    if (is_index) {
        try collectSubtreeEntries(alloc, page_store, actual_root, index_entries);
        std.mem.sort(index_mod.LeafEntry, index_entries.items, {}, leafEntryLessThan);

        const files = try alloc.alloc(FileSnapshot, index_entries.items.len);
        for (index_entries.items, 0..) |entry, i| {
            const obj = try store.get(entry.blob_hash);
            try blobs.append(alloc, obj.payload);
            files[i] = .{ .path = entry.path, .content = obj.payload };
        }
        return files;
    }

    const flat = try tree_mod.readToFlatEntries(alloc, store, actual_root);
    flat_entries.* = flat;

    const files = try alloc.alloc(FileSnapshot, flat.len);
    for (flat, 0..) |entry, i| {
        const obj = try store.get(entry.hash);
        try blobs.append(alloc, obj.payload);
        files[i] = .{ .path = entry.path, .content = obj.payload };
    }
    return files;
}

fn diffIndexRecursive(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    old_hash: ?hash_mod.Hash,
    new_hash: ?hash_mod.Hash,
    algo: Algorithm,
    out: *std.ArrayList(FileDiff),
    blobs: *std.ArrayList([]u8),
) anyerror!void {
    if (old_hash != null and new_hash != null and std.mem.eql(u8, &old_hash.?, &new_hash.?)) return;

    if (old_hash == null and new_hash == null) return;
    if (old_hash == null) {
        try appendAddedSubtree(alloc, store, page_store, new_hash.?, algo, out, blobs);
        return;
    }
    if (new_hash == null) {
        try appendDeletedSubtree(alloc, store, page_store, old_hash.?, algo, out, blobs);
        return;
    }

    var old_page = try page_store.get(old_hash.?);
    defer old_page.deinit(alloc);
    var new_page = try page_store.get(new_hash.?);
    defer new_page.deinit(alloc);

    switch (old_page) {
        .leaf => |old_entries| switch (new_page) {
            .leaf => |new_entries| try diffLeafEntries(alloc, store, old_entries.items, new_entries.items, algo, out, blobs),
            .internal => try diffCollectedSubtrees(alloc, store, page_store, old_hash.?, new_hash.?, algo, out, blobs),
        },
        .internal => |old_children| switch (new_page) {
            .leaf => try diffCollectedSubtrees(alloc, store, page_store, old_hash.?, new_hash.?, algo, out, blobs),
            .internal => |new_children| try diffInternalChildren(
                alloc,
                store,
                page_store,
                old_children.items,
                new_children.items,
                algo,
                out,
                blobs,
            ),
        },
    }
}

fn diffInternalChildren(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    old_children: []const index_mod.ChildRef,
    new_children: []const index_mod.ChildRef,
    algo: Algorithm,
    out: *std.ArrayList(FileDiff),
    blobs: *std.ArrayList([]u8),
) !void {
    var old_i: usize = 0;
    var new_i: usize = 0;
    while (old_i < old_children.len or new_i < new_children.len) {
        const cmp: std.math.Order = blk: {
            if (old_i >= old_children.len) break :blk .gt;
            if (new_i >= new_children.len) break :blk .lt;
            break :blk comparePathKey(old_children[old_i].separator, new_children[new_i].separator);
        };

        if (cmp == .eq) {
            try diffIndexRecursive(
                alloc,
                store,
                page_store,
                old_children[old_i].page_hash,
                new_children[new_i].page_hash,
                algo,
                out,
                blobs,
            );
            old_i += 1;
            new_i += 1;
        } else if (cmp == .lt) {
            try appendDeletedSubtree(alloc, store, page_store, old_children[old_i].page_hash, algo, out, blobs);
            old_i += 1;
        } else {
            try appendAddedSubtree(alloc, store, page_store, new_children[new_i].page_hash, algo, out, blobs);
            new_i += 1;
        }
    }
}

fn diffCollectedSubtrees(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    old_hash: hash_mod.Hash,
    new_hash: hash_mod.Hash,
    algo: Algorithm,
    out: *std.ArrayList(FileDiff),
    blobs: *std.ArrayList([]u8),
) !void {
    var old_entries: std.ArrayList(index_mod.LeafEntry) = .empty;
    defer freeLeafEntries(alloc, &old_entries);
    var new_entries: std.ArrayList(index_mod.LeafEntry) = .empty;
    defer freeLeafEntries(alloc, &new_entries);

    try collectSubtreeEntries(alloc, page_store, old_hash, &old_entries);
    try collectSubtreeEntries(alloc, page_store, new_hash, &new_entries);
    std.mem.sort(index_mod.LeafEntry, old_entries.items, {}, leafEntryLessThan);
    std.mem.sort(index_mod.LeafEntry, new_entries.items, {}, leafEntryLessThan);

    try diffLeafEntries(alloc, store, old_entries.items, new_entries.items, algo, out, blobs);
}

fn appendAddedSubtree(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    page_hash: hash_mod.Hash,
    algo: Algorithm,
    out: *std.ArrayList(FileDiff),
    blobs: *std.ArrayList([]u8),
) !void {
    var entries: std.ArrayList(index_mod.LeafEntry) = .empty;
    defer freeLeafEntries(alloc, &entries);
    try collectSubtreeEntries(alloc, page_store, page_hash, &entries);
    std.mem.sort(index_mod.LeafEntry, entries.items, {}, leafEntryLessThan);

    for (entries.items) |entry| {
        try appendFileDiffFromHashes(alloc, store, entry.path, null, entry.blob_hash, algo, out, blobs);
    }
}

fn appendDeletedSubtree(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const index_mod.PageStore,
    page_hash: hash_mod.Hash,
    algo: Algorithm,
    out: *std.ArrayList(FileDiff),
    blobs: *std.ArrayList([]u8),
) !void {
    var entries: std.ArrayList(index_mod.LeafEntry) = .empty;
    defer freeLeafEntries(alloc, &entries);
    try collectSubtreeEntries(alloc, page_store, page_hash, &entries);
    std.mem.sort(index_mod.LeafEntry, entries.items, {}, leafEntryLessThan);

    for (entries.items) |entry| {
        try appendFileDiffFromHashes(alloc, store, entry.path, entry.blob_hash, null, algo, out, blobs);
    }
}

fn collectSubtreeEntries(
    alloc: std.mem.Allocator,
    page_store: *const index_mod.PageStore,
    page_hash: hash_mod.Hash,
    out: *std.ArrayList(index_mod.LeafEntry),
) anyerror!void {
    var page = try page_store.get(page_hash);
    defer page.deinit(alloc);

    switch (page) {
        .leaf => |entries| {
            for (entries.items) |entry| {
                try out.append(alloc, .{
                    .key = entry.key,
                    .path = try alloc.dupe(u8, entry.path),
                    .blob_hash = entry.blob_hash,
                    .size = entry.size,
                    .mode = entry.mode,
                    .mtime = entry.mtime,
                });
            }
        },
        .internal => |children| {
            for (children.items) |child| {
                try collectSubtreeEntries(alloc, page_store, child.page_hash, out);
            }
        },
    }
}

fn diffLeafEntries(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    old_entries: []const index_mod.LeafEntry,
    new_entries: []const index_mod.LeafEntry,
    algo: Algorithm,
    out: *std.ArrayList(FileDiff),
    blobs: *std.ArrayList([]u8),
) !void {
    var old_i: usize = 0;
    var new_i: usize = 0;
    while (old_i < old_entries.len or new_i < new_entries.len) {
        const cmp: std.math.Order = blk: {
            if (old_i >= old_entries.len) break :blk .gt;
            if (new_i >= new_entries.len) break :blk .lt;
            break :blk compareLeafEntry(old_entries[old_i], new_entries[new_i]);
        };

        if (cmp == .eq) {
            if (!std.mem.eql(u8, &old_entries[old_i].blob_hash, &new_entries[new_i].blob_hash)) {
                try appendFileDiffFromHashes(
                    alloc,
                    store,
                    new_entries[new_i].path,
                    old_entries[old_i].blob_hash,
                    new_entries[new_i].blob_hash,
                    algo,
                    out,
                    blobs,
                );
            }
            old_i += 1;
            new_i += 1;
        } else if (cmp == .lt) {
            try appendFileDiffFromHashes(alloc, store, old_entries[old_i].path, old_entries[old_i].blob_hash, null, algo, out, blobs);
            old_i += 1;
        } else {
            try appendFileDiffFromHashes(alloc, store, new_entries[new_i].path, null, new_entries[new_i].blob_hash, algo, out, blobs);
            new_i += 1;
        }
    }
}

fn appendFileDiffFromHashes(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    path: []const u8,
    old_hash: ?hash_mod.Hash,
    new_hash: ?hash_mod.Hash,
    algo: Algorithm,
    out: *std.ArrayList(FileDiff),
    blobs: *std.ArrayList([]u8),
) !void {
    const old_src = if (old_hash) |hash| blk: {
        const obj = try store.get(hash);
        try blobs.append(alloc, obj.payload);
        break :blk obj.payload;
    } else "";

    const new_src = if (new_hash) |hash| blk: {
        const obj = try store.get(hash);
        try blobs.append(alloc, obj.payload);
        break :blk obj.payload;
    } else "";

    if (std.mem.eql(u8, old_src, new_src)) return;
    try out.append(alloc, try diffFileWith(alloc, path, old_src, new_src, algo));
}

fn freeLeafEntries(alloc: std.mem.Allocator, entries: *std.ArrayList(index_mod.LeafEntry)) void {
    for (entries.items) |*entry| alloc.free(entry.path);
    entries.deinit(alloc);
}

fn leafEntryLessThan(_: void, lhs: index_mod.LeafEntry, rhs: index_mod.LeafEntry) bool {
    return compareLeafEntry(lhs, rhs) == .lt;
}

fn compareLeafEntry(lhs: index_mod.LeafEntry, rhs: index_mod.LeafEntry) std.math.Order {
    const key_order = comparePathKey(lhs.key, rhs.key);
    if (key_order != .eq) return key_order;
    return std.mem.order(u8, lhs.path, rhs.path);
}

fn comparePathKey(lhs: index_mod.PathKey, rhs: index_mod.PathKey) std.math.Order {
    if (lhs < rhs) return .lt;
    if (lhs > rhs) return .gt;
    return .eq;
}

fn runLineDiff(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    algo: Algorithm,
) ![]LineDelta {
    return switch (algo) {
        .myers => myersDiff(LineDelta, alloc, old, new, 0, old.len, 0, new.len, lineEq, makeLineDelta),
        .patience => patienceDiff(alloc, old, new),
        .histogram => histogramDiff(alloc, old, new),
    };
}

// Operates on a sub-range [old_lo, old_hi) × [new_lo, new_hi) so that
// Patience and Histogram can recurse into it without copying slices.

fn myersDiff(
    comptime T: type,
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
    eqFn: fn ([]const u8, []const u8) bool,
    makeDelta: fn (Op, []const u8, u32, u32) T,
) ![]T {
    const N = old_hi - old_lo;
    const M = new_hi - new_lo;

    if (N == 0 and M == 0) return &.{};

    if (N == 0) {
        var ops = try alloc.alloc(T, M);
        for (0..M) |i| {
            ops[i] = makeDelta(.ins, new[new_lo + i], 0, @intCast(new_lo + i + 1));
        }
        return ops;
    }
    if (M == 0) {
        var ops = try alloc.alloc(T, N);
        for (0..N) |i| {
            ops[i] = makeDelta(.del, old[old_lo + i], @intCast(old_lo + i + 1), 0);
        }
        return ops;
    }

    const max_d = N + M;
    const v_len = 2 * max_d + 1;
    const v = try alloc.alloc(isize, v_len);
    defer alloc.free(v);
    @memset(v, 0);

    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |snap| alloc.free(snap);
        trace.deinit(alloc);
    }

    const offset: isize = @intCast(max_d);

    outer: for (0..max_d + 1) |d_usize| {
        const d: isize = @intCast(d_usize);
        const snap = try alloc.dupe(isize, v);
        errdefer alloc.free(snap);
        try trace.append(alloc, snap);

        var k: isize = -d;
        while (k <= d) : (k += 2) {
            const ki: usize = @intCast(k + offset);
            const move_down = k == -d or (k != d and v[ki - 1] < v[ki + 1]);
            var x: isize = if (move_down) v[ki + 1] else v[ki - 1] + 1;
            var y: isize = x - k;

            while (x < N and y < M and eqFn(old[old_lo + @as(usize, @intCast(x))], new[new_lo + @as(usize, @intCast(y))])) {
                x += 1;
                y += 1;
            }
            v[ki] = x;

            if (x >= N and y >= M) break :outer;
        }
    }

    var ops: std.ArrayList(T) = .empty;
    errdefer ops.deinit(alloc);

    var x: isize = @intCast(N);
    var y: isize = @intCast(M);
    var d: isize = @intCast(trace.items.len - 1);

    while (d >= 0) : (d -= 1) {
        const snap = trace.items[@intCast(d)];
        const k = x - y;
        const ki: usize = @intCast(k + offset);

        const prev_k: isize = if (k == -d or (k != d and snap[ki - 1] < snap[ki + 1]))
            k + 1
        else
            k - 1;

        const prev_x = snap[@intCast(prev_k + offset)];
        const prev_y = prev_x - prev_k;

        // Walk back the snake: any number of matching steps, bounded by
        // actual line equality AND the prev_x/prev_y target.
        //  A single d-step's snake can be longer than
        // one line, and the gap to prev_x/prev_y is not guaranteed to be
        // diagonal once the snake is peeled off, so we check content here
        // rather than assuming geometry
        while (x > prev_x and y > prev_y and
            eqFn(old[old_lo + @as(usize, @intCast(x - 1))], new[new_lo + @as(usize, @intCast(y - 1))]))
        {
            x -= 1;
            y -= 1;
            try ops.append(alloc, makeDelta(
                .eq,
                old[old_lo + @as(usize, @intCast(x))],
                @intCast(old_lo + @as(usize, @intCast(x)) + 1),
                @intCast(new_lo + @as(usize, @intCast(y)) + 1),
            ));
        }

        if (d > 0) {
            if (x == prev_x) {
                y -= 1;
                try ops.append(alloc, makeDelta(
                    .ins,
                    new[new_lo + @as(usize, @intCast(y))],
                    0,
                    @intCast(new_lo + @as(usize, @intCast(y)) + 1),
                ));
            } else {
                x -= 1;
                try ops.append(alloc, makeDelta(
                    .del,
                    old[old_lo + @as(usize, @intCast(x))],
                    @intCast(old_lo + @as(usize, @intCast(x)) + 1),
                    0,
                ));
            }
        }
    }

    std.mem.reverse(T, ops.items);
    return ops.toOwnedSlice(alloc);
}

fn patienceDiff(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
) ![]LineDelta {
    return patienceDiffRange(alloc, old, new, 0, old.len, 0, new.len);
}

fn patienceDiffRange(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) ![]LineDelta {
    var alo = old_lo;
    var nlo = new_lo;
    while (alo < old_hi and nlo < new_hi and lineEq(old[alo], new[nlo])) {
        alo += 1;
        nlo += 1;
    }

    var ahi = old_hi;
    var nhi = new_hi;
    while (ahi > alo and nhi > nlo and lineEq(old[ahi - 1], new[nhi - 1])) {
        ahi -= 1;
        nhi -= 1;
    }

    var out: std.ArrayList(LineDelta) = .empty;
    errdefer out.deinit(alloc);

    for (old_lo..alo) |i| {
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_lo + (i - old_lo) + 1)));
    }

    if (alo == ahi and nlo == nhi) {
        // Nothing left after stripping common prefix/suffix
    } else {
        const anchors = try patienceAnchors(alloc, old, new, alo, ahi, nlo, nhi);
        defer alloc.free(anchors);

        if (anchors.len == 0) {
            const sub = try myersDiff(LineDelta, alloc, old, new, alo, ahi, nlo, nhi, lineEq, makeLineDelta);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        } else {
            var prev_oi = alo;
            var prev_ni = nlo;

            for (anchors) |anc| {
                const sub = try patienceDiffRange(alloc, old, new, prev_oi, anc.old_idx, prev_ni, anc.new_idx);
                defer alloc.free(sub);
                try out.appendSlice(alloc, sub);

                try out.append(alloc, makeLineDelta(
                    .eq,
                    old[anc.old_idx],
                    @intCast(anc.old_idx + 1),
                    @intCast(anc.new_idx + 1),
                ));
                prev_oi = anc.old_idx + 1;
                prev_ni = anc.new_idx + 1;
            }

            const sub = try patienceDiffRange(alloc, old, new, prev_oi, ahi, prev_ni, nhi);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        }
    }

    for (ahi..old_hi) |i| {
        const new_i = nhi + (i - ahi);
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_i + 1)));
    }

    return out.toOwnedSlice(alloc);
}

const Anchor = struct { old_idx: usize, new_idx: usize };

fn patienceAnchors(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) ![]Anchor {
    var old_map = std.StringHashMap(u32).init(alloc);
    defer old_map.deinit();
    var new_map = std.StringHashMap(u32).init(alloc);
    defer new_map.deinit();

    const MULTI: u32 = std.math.maxInt(u32);

    for (old_lo..old_hi) |i| {
        const gop = try old_map.getOrPut(old[i]);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(i);
        } else {
            gop.value_ptr.* = MULTI;
        }
    }

    for (new_lo..new_hi) |j| {
        const gop = try new_map.getOrPut(new[j]);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(j);
        } else {
            gop.value_ptr.* = MULTI;
        }
    }

    var pairs: std.ArrayList(Anchor) = .empty;
    defer pairs.deinit(alloc);

    for (new_lo..new_hi) |j| {
        const nv = new_map.get(new[j]) orelse continue;
        if (nv == MULTI) continue;
        const ov = old_map.get(new[j]) orelse continue;
        if (ov == MULTI) continue;
        try pairs.append(alloc, .{ .old_idx = ov, .new_idx = @intCast(j) });
    }

    if (pairs.items.len == 0) return &.{};

    std.sort.insertion(Anchor, pairs.items, {}, struct {
        fn lt(_: void, a: Anchor, b: Anchor) bool {
            return a.old_idx < b.old_idx;
        }
    }.lt);

    var prev = try alloc.alloc(usize, pairs.items.len);
    defer alloc.free(prev);
    var pile_top_src = try alloc.alloc(usize, pairs.items.len);
    defer alloc.free(pile_top_src);
    @memset(prev, std.math.maxInt(usize));
    var pile_count: usize = 0;

    for (pairs.items, 0..) |pair, pi| {
        var lo2: usize = 0;
        var hi2: usize = pile_count;
        while (lo2 < hi2) {
            const mid = lo2 + (hi2 - lo2) / 2;
            if (pairs.items[pile_top_src[mid]].new_idx < pair.new_idx) {
                lo2 = mid + 1;
            } else {
                hi2 = mid;
            }
        }
        if (lo2 > 0) prev[pi] = pile_top_src[lo2 - 1];
        pile_top_src[lo2] = pi;
        if (lo2 == pile_count) pile_count += 1;
    }

    var lis: std.ArrayList(Anchor) = .empty;
    defer lis.deinit(alloc);

    if (pile_count > 0) {
        var idx = pile_top_src[pile_count - 1];
        while (true) {
            try lis.append(alloc, pairs.items[idx]);
            if (prev[idx] == std.math.maxInt(usize)) break;
            idx = prev[idx];
        }
        std.mem.reverse(Anchor, lis.items);
    }

    return lis.toOwnedSlice(alloc);
}

fn histogramDiff(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
) ![]LineDelta {
    return histogramDiffRange(alloc, old, new, 0, old.len, 0, new.len);
}

fn histogramDiffRange(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) ![]LineDelta {
    var alo = old_lo;
    var nlo = new_lo;
    while (alo < old_hi and nlo < new_hi and lineEq(old[alo], new[nlo])) {
        alo += 1;
        nlo += 1;
    }
    var ahi = old_hi;
    var nhi = new_hi;
    while (ahi > alo and nhi > nlo and lineEq(old[ahi - 1], new[nhi - 1])) {
        ahi -= 1;
        nhi -= 1;
    }

    var out: std.ArrayList(LineDelta) = .empty;
    errdefer out.deinit(alloc);

    for (old_lo..alo) |i| {
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_lo + (i - old_lo) + 1)));
    }

    if (alo < ahi or nlo < nhi) {
        const region = try histogramFindRegion(alloc, old, new, alo, ahi, nlo, nhi);

        if (region == null) {
            const sub = try myersDiff(LineDelta, alloc, old, new, alo, ahi, nlo, nhi, lineEq, makeLineDelta);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        } else {
            const reg = region.?;

            const left = try histogramDiffRange(alloc, old, new, alo, reg.old_start, nlo, reg.new_start);
            defer alloc.free(left);
            try out.appendSlice(alloc, left);

            for (0..reg.len) |k| {
                try out.append(alloc, makeLineDelta(
                    .eq,
                    old[reg.old_start + k],
                    @intCast(reg.old_start + k + 1),
                    @intCast(reg.new_start + k + 1),
                ));
            }

            const right = try histogramDiffRange(
                alloc,
                old,
                new,
                reg.old_start + reg.len,
                ahi,
                reg.new_start + reg.len,
                nhi,
            );
            defer alloc.free(right);
            try out.appendSlice(alloc, right);
        }
    }

    for (ahi..old_hi) |i| {
        const new_i = nhi + (i - ahi);
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_i + 1)));
    }

    return out.toOwnedSlice(alloc);
}

const Region = struct {
    old_start: usize,
    new_start: usize,
    len: usize,
};

fn histogramFindRegion(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) !?Region {
    var freq_map = std.StringHashMap(u32).init(alloc);
    defer freq_map.deinit();

    for (old_lo..old_hi) |i| {
        const gop = try freq_map.getOrPut(old[i]);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var best: ?Region = null;
    var best_freq: u32 = std.math.maxInt(u32);
    var best_len: usize = 0;

    for (new_lo..new_hi) |nj| {
        const freq = freq_map.get(new[nj]) orelse continue;
        if (freq > best_freq) continue;

        for (old_lo..old_hi) |oi| {
            if (!lineEq(old[oi], new[nj])) continue;

            var back: usize = 0;
            while (oi >= old_lo + back + 1 and
                nj >= new_lo + back + 1 and
                lineEq(old[oi - back - 1], new[nj - back - 1]))
            {
                back += 1;
            }
            var fwd: usize = 1;
            while (oi + fwd < old_hi and
                nj + fwd < new_hi and
                lineEq(old[oi + fwd], new[nj + fwd]))
            {
                fwd += 1;
            }

            const region_len = back + fwd;
            const region_old_start = oi - back;
            const region_new_start = nj - back;

            const is_better = freq < best_freq or (freq == best_freq and region_len > best_len);
            if (is_better) {
                best_freq = freq;
                best_len = region_len;
                best = Region{
                    .old_start = region_old_start,
                    .new_start = region_new_start,
                    .len = region_len,
                };
            }
        }
    }

    return best;
}

fn diffWords(alloc: std.mem.Allocator, line_deltas: []const LineDelta) ![]WordDelta {
    var out: std.ArrayList(WordDelta) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < line_deltas.len) {
        if (line_deltas[i].op == .eq) {
            i += 1;
            continue;
        }

        var del_words: std.ArrayList([]const u8) = .empty;
        defer del_words.deinit(alloc);
        var ins_words: std.ArrayList([]const u8) = .empty;
        defer ins_words.deinit(alloc);
        var del_lineno: u32 = 0;
        var ins_lineno: u32 = 0;

        var j = i;
        while (j < line_deltas.len and line_deltas[j].op != .eq) : (j += 1) {
            const ld = line_deltas[j];
            if (ld.op == .del) {
                if (del_lineno == 0) del_lineno = ld.old_lineno;
                const words = try tokenizeWords(alloc, ld.content);
                defer alloc.free(words);
                try del_words.appendSlice(alloc, words);
            } else {
                if (ins_lineno == 0) ins_lineno = ld.new_lineno;
                const words = try tokenizeWords(alloc, ld.content);
                defer alloc.free(words);
                try ins_words.appendSlice(alloc, words);
            }
        }

        const lineno = if (ins_lineno != 0) ins_lineno else del_lineno;

        const word_ops = try myersDiff(
            WordDelta,
            alloc,
            del_words.items,
            ins_words.items,
            0,
            del_words.items.len,
            0,
            ins_words.items.len,
            wordEq,
            makeWordDelta,
        );
        defer alloc.free(word_ops);

        for (word_ops) |wd| {
            try out.append(alloc, .{ .op = wd.op, .word = wd.word, .lineno = lineno });
        }

        i = j;
    }

    return out.toOwnedSlice(alloc);
}

pub fn renderCommit(writer: anytype, cd: *const CommitDiff, config: RenderConfig, alloc: std.mem.Allocator) !void {
    var filtered: std.ArrayList(*const FileDiff) = .empty;
    defer filtered.deinit(alloc);

    for (cd.files) |*fd| {
        const status = fileStatus(fd);
        if (!config.filter.allows(status)) continue;
        try filtered.append(alloc, fd);
    }

    if (config.group_by == .dirs) {
        const groups = try groupByDirectory(alloc, filtered.items);
        defer {
            for (groups) |g| alloc.free(g.files);
            alloc.free(groups);
        }
        for (groups) |g| {
            try writer.print("{s}/\n", .{g.dir});
            for (g.files) |fd| {
                try writer.print("  {s}\n", .{std.fs.path.basename(fd.path)});
            }
            try writer.writeByte('\n');
        }
        return;
    }

    for (filtered.items) |fd| {
        try renderFileDiff(writer, fd, config);
    }
}

pub fn renderFileDiff(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    if (config.level == .file) {
        const status = fileStatus(fd);
        const sc = switch (status) {
            .added => "A",
            .deleted => "D",
            .modified => "M",
            .unchanged => "~",
        };
        try writer.print("{s} {s} (+{d} -{d})\n", .{ sc, fd.path, fd.lines_added, fd.lines_removed });
        return;
    }

    if (config.level == .word) {
        try renderWordHighlight(writer, fd);
        return;
    }

    switch (config.format) {
        .unified => try renderUnified(writer, fd, config),
        .side_by_side => try renderSideBySide(writer, fd, config),
        .blocks => try renderBlockOriented(writer, fd, config),
        .ops => try renderOperations(writer, fd, config),
        .summary => try renderSummary(writer, fd),
    }
}

pub fn renderUnified(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    try writer.print("FILE  {s}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{fd.path});
    if (fd.line_deltas.len == 0) return;

    var it = HunkIterator.init(fd.line_deltas, config.contextLines());
    while (it.next()) |hunk| {
        const line_num = hunk.displayLineNum();
        try writer.print("~ Line {d}\n", .{line_num});
        for (fd.line_deltas[hunk.start..hunk.end]) |d| {
            const prefix: []const u8 = switch (d.op) {
                .eq => "  ",
                .del => "- ",
                .ins => "+ ",
            };
            try writer.print("{s}{s}\n", .{ prefix, d.content });
        }
        try writer.writeByte('\n');
    }
}

fn renderSideBySide(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    const col_width = maxLineWidth(fd.line_deltas, @as(usize, @intCast(config.max_width)));
    const sep = " │ ";

    try writer.print("FILE  {s}\n", .{fd.path});
    try writer.writeAll("│ Before");
    padTo(writer, col_width, 6);
    try writer.writeAll(sep);
    try writer.writeAll("After");
    padTo(writer, col_width, 5);
    try writer.writeByte('\n');

    const total_width = 1 + col_width + sep.len + col_width + 1;
    for (0..total_width) |_| try writer.writeAll("─");
    try writer.writeByte('\n');

    for (fd.line_deltas) |d| {
        const left = if (d.op == .ins) "" else d.content;
        const right = if (d.op == .del) "" else d.content;
        try writer.writeAll("│");
        try writePadded(writer, left, col_width);
        try writer.writeAll(sep);
        try writePadded(writer, right, col_width);
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
}

fn renderBlockOriented(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    try writer.print("FILE: {s}\n", .{fd.path});
    if (fd.line_deltas.len == 0) return;

    var it = HunkIterator.init(fd.line_deltas, config.contextLines());
    var change_number: usize = 1;
    while (it.next()) |hunk| {
        try writer.print("CHANGE #{d}\n", .{change_number});
        try writeSectionDivider(writer, 32);
        try writer.writeAll("BEFORE\n");
        for (fd.line_deltas[hunk.start..hunk.end]) |d| if (d.op != .ins) try writer.print("{s}\n", .{d.content});
        try writer.writeAll("AFTER\n");
        for (fd.line_deltas[hunk.start..hunk.end]) |d| if (d.op != .del) try writer.print("{s}\n", .{d.content});
        try writer.writeByte('\n');
        change_number += 1;
    }
}

fn renderOperations(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    try writer.print("FILE  {s}\n", .{fd.path});
    try writer.print("STATUS: {s}\n\n", .{statusString(fileStatus(fd))});
    if (fd.line_deltas.len == 0) return;

    var it = HunkIterator.init(fd.line_deltas, config.contextLines());
    while (it.next()) |hunk| {
        const line_num = hunk.displayLineNum();
        try writer.print("FROM line {d}\n", .{line_num});
        for (fd.line_deltas[hunk.start..hunk.end]) |d| if (d.op != .ins) try writer.print("  {s}\n", .{d.content});
        try writer.print("\nTO line {d}\n", .{line_num});
        for (fd.line_deltas[hunk.start..hunk.end]) |d| if (d.op != .del) try writer.print("  {s}\n", .{d.content});
        try writer.writeByte('\n');
    }
}

fn renderSummary(writer: anytype, fd: *const FileDiff) !void {
    const status = fileStatus(fd);
    const sc = switch (status) {
        .added => "A",
        .deleted => "D",
        .modified => "M",
        .unchanged => "~",
    };
    try writer.print("{s} {s} (+{d} -{d})\n", .{ sc, fd.path, fd.lines_added, fd.lines_removed });
}

fn renderWordHighlight(writer: anytype, fd: *const FileDiff) !void {
    try writer.print("WORD HIGHLIGHT: {s}\n", .{fd.path});
    try renderWordDeltas(writer, fd.word_deltas);
}

pub fn renderWordDiff(writer: anytype, fd: *const FileDiff) !void {
    try writer.print("WORD HIGHLIGHT: {s}\n", .{fd.path});
    try renderWordDeltas(writer, fd.word_deltas);
}

fn renderWordDeltas(writer: anytype, word_deltas: []const WordDelta) !void {
    var current_line: u32 = 0;
    for (word_deltas) |d| {
        if (d.lineno != current_line) {
            if (current_line != 0) try writer.writeByte('\n');
            try writer.print("Line {d}: ", .{d.lineno});
            current_line = d.lineno;
        }
        switch (d.op) {
            .eq => try writer.print("{s}", .{d.word}),
            .ins => try writer.print("[+{s}+]", .{d.word}),
            .del => try writer.print("[-{s}-]", .{d.word}),
        }
    }
    if (current_line != 0) try writer.writeByte('\n');
}

const Hunk = struct {
    start: usize,
    end: usize,
    deltas: []const LineDelta,

    fn displayLineNum(self: Hunk) u32 {
        for (self.deltas[self.start..self.end]) |d| {
            if (d.op != .ins) return d.old_lineno;
        }
        return self.deltas[self.start].new_lineno;
    }
};

const HunkIterator = struct {
    deltas: []const LineDelta,
    context: u32,
    i: usize,

    fn init(deltas: []const LineDelta, context: u32) HunkIterator {
        return .{ .deltas = deltas, .context = context, .i = 0 };
    }

    fn next(self: *HunkIterator) ?Hunk {
        while (self.i < self.deltas.len and self.deltas[self.i].op == .eq) self.i += 1;
        if (self.i >= self.deltas.len) return null;

        const start = if (self.i >= self.context) self.i - self.context else 0;
        var hunk_end: usize = self.i;

        while (hunk_end < self.deltas.len) {
            if (self.deltas[hunk_end].op != .eq) {
                hunk_end = @min(hunk_end + @as(usize, @intCast(self.context)) + 1, self.deltas.len);
            } else {
                var lookahead = hunk_end;
                var eq_run: u32 = 0;
                while (lookahead < self.deltas.len and self.deltas[lookahead].op == .eq) {
                    lookahead += 1;
                    eq_run += 1;
                }
                if (eq_run > self.context * 2 or lookahead >= self.deltas.len) {
                    hunk_end = @min(hunk_end + @as(usize, @intCast(self.context)), self.deltas.len);
                    break;
                }
                hunk_end = lookahead;
            }
        }

        const result = Hunk{ .start = start, .end = hunk_end, .deltas = self.deltas };
        self.i = hunk_end;
        return result;
    }
};

pub const DirGroup = struct {
    dir: []const u8,
    files: []*const FileDiff,
};

pub fn groupByDirectory(alloc: std.mem.Allocator, files: []*const FileDiff) ![]DirGroup {
    var map = std.StringHashMap(std.ArrayList(*const FileDiff)).init(alloc);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(alloc);
        map.deinit();
    }

    for (files) |fd| {
        const dir = std.fs.path.dirname(fd.path) orelse ".";
        const gop = try map.getOrPut(dir);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(alloc, fd);
    }

    var groups: std.ArrayList(DirGroup) = .empty;
    var it = map.iterator();
    while (it.next()) |entry| {
        try groups.append(alloc, .{
            .dir = entry.key_ptr.*,
            .files = try entry.value_ptr.toOwnedSlice(alloc),
        });
    }
    return groups.toOwnedSlice(alloc);
}

pub const DiffSummary = struct {
    files_changed: u32,
    lines_added: u32,
    lines_removed: u32,
    words_added: u32,
    words_removed: u32,
};

pub fn summarize(cd: *const CommitDiff) DiffSummary {
    var s = DiffSummary{
        .files_changed = @intCast(cd.files.len),
        .lines_added = 0,
        .lines_removed = 0,
        .words_added = 0,
        .words_removed = 0,
    };
    for (cd.files) |f| {
        s.lines_added += f.lines_added;
        s.lines_removed += f.lines_removed;
        s.words_added += f.words_added;
        s.words_removed += f.words_removed;
    }
    return s;
}

pub fn fileStatus(fd: *const FileDiff) FileStatus {
    var has_ins = false;
    var has_del = false;
    for (fd.line_deltas) |d| switch (d.op) {
        .ins => has_ins = true,
        .del => has_del = true,
        .eq => {},
    };
    if (has_ins and has_del) return .modified;
    if (has_ins) return .added;
    if (has_del) return .deleted;
    return .unchanged;
}

fn splitLines(alloc: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(alloc);

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (it.rest().len == 0 and line.len == 0) break;
        try lines.append(alloc, line);
    }
    return lines.toOwnedSlice(alloc);
}

fn tokenizeWords(alloc: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    errdefer words.deinit(alloc);

    var i: usize = 0;
    while (i < line.len) {
        if (std.ascii.isWhitespace(line[i])) {
            i += 1;
            continue;
        }
        if (std.ascii.isAlphanumeric(line[i]) or line[i] == '_') {
            const start = i;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
            try words.append(alloc, line[start..i]);
        } else {
            try words.append(alloc, line[i .. i + 1]);
            i += 1;
        }
    }
    return words.toOwnedSlice(alloc);
}

fn lineEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn makeLineDelta(op: Op, content: []const u8, old_lineno: u32, new_lineno: u32) LineDelta {
    return .{ .op = op, .content = content, .old_lineno = old_lineno, .new_lineno = new_lineno };
}

fn wordEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn makeWordDelta(op: Op, word: []const u8, _: u32, _: u32) WordDelta {
    return .{ .op = op, .word = word, .lineno = 0 };
}

fn statusString(s: FileStatus) []const u8 {
    return switch (s) {
        .added => "A",
        .deleted => "D",
        .modified => "M",
        .unchanged => "~",
    };
}

fn maxLineWidth(deltas: []const LineDelta, max_width: usize) usize {
    var max: usize = 0;
    for (deltas) |d| {
        if (d.content.len > max) max = d.content.len;
    }
    return if (max < max_width) max else max_width;
}

fn writePadded(writer: anytype, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) {
        for (0..width - text.len) |_| try writer.writeByte(' ');
    }
}

fn padTo(writer: anytype, width: usize, already_written: usize) void {
    if (width > already_written) {
        for (0..width - already_written) |_| writer.writeByte(' ') catch {};
    }
}

fn writeSectionDivider(writer: anytype, width: usize) !void {
    for (0..width) |_| try writer.writeAll("━");
    try writer.writeByte('\n');
}

fn serializeLineDiffs(alloc: std.mem.Allocator, files: []const FileDiff) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeInt(u32, @intCast(files.len), .little);
    for (files) |f| {
        try w.writeInt(u16, @intCast(f.path.len), .little);
        try w.writeAll(f.path);
        try w.writeInt(u32, @intCast(f.line_deltas.len), .little);
        for (f.line_deltas) |d| {
            try w.writeByte(@intFromEnum(d.op));
            try w.writeInt(u32, d.old_lineno, .little);
            try w.writeInt(u32, d.new_lineno, .little);
            try w.writeInt(u16, @intCast(d.content.len), .little);
            try w.writeAll(d.content);
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn serializeWordDiffs(alloc: std.mem.Allocator, files: []const FileDiff) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeInt(u32, @intCast(files.len), .little);
    for (files) |f| {
        try w.writeInt(u16, @intCast(f.path.len), .little);
        try w.writeAll(f.path);
        try w.writeInt(u32, @intCast(f.word_deltas.len), .little);
        for (f.word_deltas) |d| {
            try w.writeByte(@intFromEnum(d.op));
            try w.writeInt(u32, d.lineno, .little);
            try w.writeInt(u16, @intCast(d.word.len), .little);
            try w.writeAll(d.word);
        }
    }
    return buf.toOwnedSlice(alloc);
}

test "splitLines basic" {
    const alloc = std.testing.allocator;
    const lines = try splitLines(alloc, "a\nb\nc");
    defer alloc.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("c", lines[2]);
}

test "splitLines trailing newline does not add phantom line" {
    const alloc = std.testing.allocator;
    const lines = try splitLines(alloc, "a\nb\n");
    defer alloc.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
}

test "diffFile identical sources produces no deltas" {
    const alloc = std.testing.allocator;
    const src = "fn main() void {}\n";
    inline for (.{ Algorithm.myers, .patience, .histogram }) |algo| {
        var fd = try diffFileWith(alloc, "main.zig", src, src, algo);
        defer fd.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 0), fd.lines_added);
        try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
    }
}

test "diffFile single line added — all algos" {
    const alloc = std.testing.allocator;
    const old = "fn a() void {}\n";
    const new = "fn a() void {}\nfn b() void {}\n";
    inline for (.{ Algorithm.myers, .patience, .histogram }) |algo| {
        var fd = try diffFileWith(alloc, "x.zig", old, new, algo);
        defer fd.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
        try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
    }
}

test "diffFile single line removed — all algos" {
    const alloc = std.testing.allocator;
    const old = "fn a() void {}\nfn b() void {}\n";
    const new = "fn a() void {}\n";
    inline for (.{ Algorithm.myers, .patience, .histogram }) |algo| {
        var fd = try diffFileWith(alloc, "x.zig", old, new, algo);
        defer fd.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 0), fd.lines_added);
        try std.testing.expectEqual(@as(u32, 1), fd.lines_removed);
    }
}

test "patience prefers unique anchors over ambiguous matches" {
    const alloc = std.testing.allocator;
    const old =
        \\void func1() {
        \\    x += 1
        \\}
        \\
        \\void func2() {
        \\    y += 2
        \\}
    ;
    const new =
        \\void func1() {
        \\    x += 1
        \\    x += 2
        \\}
        \\
        \\void func2() {
        \\    y += 2
        \\    y += 3
        \\}
    ;
    var fd_patience = try diffFileWith(alloc, "f.c", old, new, .patience);
    defer fd_patience.deinit(alloc);
    var fd_histogram = try diffFileWith(alloc, "f.c", old, new, .histogram);
    defer fd_histogram.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 2), fd_patience.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd_patience.lines_removed);
    try std.testing.expectEqual(@as(u32, 2), fd_histogram.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd_histogram.lines_removed);
}

test "histogram handles repeated lines gracefully" {
    const alloc = std.testing.allocator;
    const old = "}\n}\n}\n";
    const new = "}\n}\n}\n}\n";
    var fd = try diffFileWith(alloc, "b.c", old, new, .histogram);
    defer fd.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
}

test "all algos agree on net line delta" {
    const alloc = std.testing.allocator;
    const old =
        \\pub fn foo(x: u32) u32 {
        \\    return x + 1;
        \\}
        \\
        \\pub fn bar(y: u32) u32 {
        \\    return y * 2;
        \\}
    ;
    const new =
        \\pub fn foo(x: u32) u32 {
        \\    const z = x + 1;
        \\    return z;
        \\}
        \\
        \\pub fn bar(y: u32) u32 {
        \\    return y * 2;
        \\}
        \\
        \\pub fn baz(z: u32) u32 {
        \\    return z - 1;
        \\}
    ;
    var fd_m = try diffFileWith(alloc, "f.zig", old, new, .myers);
    defer fd_m.deinit(alloc);
    var fd_p = try diffFileWith(alloc, "f.zig", old, new, .patience);
    defer fd_p.deinit(alloc);
    var fd_h = try diffFileWith(alloc, "f.zig", old, new, .histogram);
    defer fd_h.deinit(alloc);

    // Net added-removed must equal new.len - old.len for ANY correct edit
    // script, regardless of algorithm — this is an algorithm-independent
    // invariant, not a property specific to one diff strategy
    const net_m: i32 = @as(i32, @intCast(fd_m.lines_added)) - @as(i32, @intCast(fd_m.lines_removed));
    const net_p: i32 = @as(i32, @intCast(fd_p.lines_added)) - @as(i32, @intCast(fd_p.lines_removed));
    const net_h: i32 = @as(i32, @intCast(fd_h.lines_added)) - @as(i32, @intCast(fd_h.lines_removed));
    try std.testing.expectEqual(@as(i32, 5), net_m);
    try std.testing.expectEqual(@as(i32, 5), net_p);
    try std.testing.expectEqual(@as(i32, 5), net_h);
}

test "tokenizeWords splits identifiers and punctuation" {
    const alloc = std.testing.allocator;
    const words = try tokenizeWords(alloc, "fn foo(x: u32)");
    defer alloc.free(words);
    try std.testing.expectEqual(@as(usize, 7), words.len);
    try std.testing.expectEqualStrings("fn", words[0]);
    try std.testing.expectEqualStrings("foo", words[1]);
    try std.testing.expectEqualStrings("(", words[2]);
}

test "summarize aggregates across files" {
    const alloc = std.testing.allocator;
    const old_files = [_]FileSnapshot{
        .{ .path = "a.txt", .content = "hello\nworld\n" },
        .{ .path = "b.txt", .content = "foo\n" },
    };
    const new_files = [_]FileSnapshot{
        .{ .path = "a.txt", .content = "hello\nearth\n" },
        .{ .path = "b.txt", .content = "foo\nbar\n" },
    };

    var cd = try diffCommit(alloc, &old_files, &new_files);
    defer cd.deinit(alloc);

    const s = summarize(&cd);
    try std.testing.expectEqual(@as(u32, 2), s.files_changed);
    try std.testing.expectEqual(@as(u32, 2), s.lines_added);
    try std.testing.expectEqual(@as(u32, 1), s.lines_removed);
}

test "diffIndexRoots reports modified files from Merkle pages" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var objects_dir = try tmp_dir.dir.makeOpenPath(".nodus/objects", .{});
    defer objects_dir.close();
    var store = object_mod.Store{ .dir = objects_dir, .alloc = alloc };

    const old_blob = try store.put(.blob, "old\n");
    const new_blob = try store.put(.blob, "new\n");

    const nodus_dir = try tmp_dir.dir.openDir(".nodus", .{});
    var index = index_mod.Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();

    try index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "src/main.zig"),
        .blob_hash = old_blob,
        .size = 4,
        .mode = 0o100644,
        .mtime = 1,
    });
    try index.save();
    const old_root = index.index_root;

    index.entries.items[0].blob_hash = new_blob;
    index.entries.items[0].mtime = 2;
    try index.save();
    const new_root = index.index_root;

    var page_store = index_mod.PageStore{ .alloc = alloc, .dir = index.dir };
    var cd = try diffIndexRoots(alloc, &store, &page_store, old_root, new_root, .histogram);
    defer cd.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), cd.files.len);
    try std.testing.expectEqualStrings("src/main.zig", cd.files[0].path);
    try std.testing.expectEqual(@as(u32, 1), cd.files[0].lines_added);
    try std.testing.expectEqual(@as(u32, 1), cd.files[0].lines_removed);
}

test "diffSnapshotRoots compares legacy tree root to Merkle index root" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var objects_dir = try tmp_dir.dir.makeOpenPath(".nodus/objects", .{});
    defer objects_dir.close();
    var store = object_mod.Store{ .dir = objects_dir, .alloc = alloc };

    const old_blob = try store.put(.blob, "old\n");
    const new_blob = try store.put(.blob, "new\n");

    const old_entries = [_]index_mod.Entry{
        .{
            .path = @constCast("src/main.zig"),
            .blob_hash = old_blob,
            .size = 4,
            .mode = 0o100644,
            .mtime = 1,
        },
    };
    const legacy_tree_root = try tree_mod.writeFromIndex(alloc, &store, &old_entries);

    const nodus_dir = try tmp_dir.dir.openDir(".nodus", .{});
    var index = index_mod.Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer index.deinit();

    try index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "src/main.zig"),
        .blob_hash = new_blob,
        .size = 4,
        .mode = 0o100644,
        .mtime = 2,
    });
    try index.save();

    var page_store = index_mod.PageStore{ .alloc = alloc, .dir = index.dir };
    var cd = try diffSnapshotRoots(alloc, &store, &page_store, legacy_tree_root, index.index_root, .histogram);
    defer cd.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), cd.files.len);
    try std.testing.expectEqualStrings("src/main.zig", cd.files[0].path);
    try std.testing.expectEqual(@as(u32, 1), cd.files[0].lines_added);
    try std.testing.expectEqual(@as(u32, 1), cd.files[0].lines_removed);
}

test "ChangeFilter parse comma list" {
    const f = try ChangeFilter.parse("added,modified");
    try std.testing.expect(f.show_added);
    try std.testing.expect(f.show_modified);
    try std.testing.expect(!f.show_deleted);
}

test "groupByDirectory groups files" {
    const alloc = std.testing.allocator;
    const files = &[_]FileDiff{
        .{ .path = "src/main.zig", .line_deltas = &.{}, .word_deltas = &.{}, .lines_added = 0, .lines_removed = 0, .words_added = 0, .words_removed = 0 },
        .{ .path = "src/lib.zig", .line_deltas = &.{}, .word_deltas = &.{}, .lines_added = 0, .lines_removed = 0, .words_added = 0, .words_removed = 0 },
        .{ .path = "test/foo.zig", .line_deltas = &.{}, .word_deltas = &.{}, .lines_added = 0, .lines_removed = 0, .words_added = 0, .words_removed = 0 },
    };
    var ptrs = [_]*const FileDiff{ &files[0], &files[1], &files[2] };
    const groups = try groupByDirectory(alloc, &ptrs);
    defer {
        for (groups) |g| alloc.free(g.files);
        alloc.free(groups);
    }
    try std.testing.expectEqual(@as(usize, 2), groups.len);
}
