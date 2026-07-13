const std = @import("std");
const hash_mod = @import("../hash.zig");
const format = @import("format.zig");
const entry_mod = @import("entry.zig");
const page_store_mod = @import("page_store.zig");

const Hash = hash_mod.Hash;
const LeafEntry = format.LeafEntry;
const ChildRef = format.ChildRef;
const PageStore = page_store_mod.PageStore;
const DiffError = format.DiffError;
const EntryChange = entry_mod.EntryChange;
const hashEq = format.hashEq;

/// Diff two index-root hashes directly, without loading a full `Index`.
/// Useful for comparing commit index states.
/// Caller owns the returned slice; free with `entry_mod.freeChanges`.
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

/// Recursively diff two subtrees
/// NOTE: identical page hashes short-circuit without disk access
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
/// into the mismatched middle region
fn diffInternal(
    alloc: std.mem.Allocator,
    store: *const PageStore,
    old_children: []const ChildRef,
    new_children: []const ChildRef,
    changes: *std.ArrayList(EntryChange),
) DiffError!void {
    // Find matching prefix
    //NOTE:these subtrees are identical and can be skipped
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

    // Find matching suffix
    while (old_hi > old_lo and new_hi > new_lo and
        old_children[old_hi - 1].separator == new_children[new_hi - 1].separator and
        hashEq(old_children[old_hi - 1].page_hash, new_children[new_hi - 1].page_hash))
    {
        old_hi -= 1;
        new_hi -= 1;
    }

    var oi = old_lo;
    var nj = new_lo;
    while (oi < old_hi and nj < new_hi and old_children[oi].separator == new_children[nj].separator) {
        try diffNodes(alloc, store, old_children[oi].page_hash, new_children[nj].page_hash, changes);
        oi += 1;
        nj += 1;
    }

    // Any remaining misaligned region is flattened to leaf entries and diffed directly
    if (oi < old_hi or nj < new_hi) {
        const old_flat = try flattenChildren(alloc, store, old_children[oi..old_hi]);
        defer freeFlat(alloc, old_flat);
        const new_flat = try flattenChildren(alloc, store, new_children[nj..new_hi]);
        defer freeFlat(alloc, new_flat);
        try diffLeafLists(alloc, old_flat, new_flat, changes);
    }
}

/// Three-way merge of two sorted leaf entry lists
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

/// Collect all entries under a subtree into a flat change list
fn collectSubtree(
    alloc: std.mem.Allocator,
    store: *const PageStore,
    page_hash: Hash,
    kind: entry_mod.ChangeKind,
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

/// Flatten a slice of child references into a sorted leaf entry array
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

/// Recursively append all leaf entries under a page hash to `out`
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
