const std = @import("std");
const hash_mod = @import("../crypto/crypto.zig").hash;
const node = @import("node.zig");
const entry_mod = @import("entry.zig");
const page_store_mod = @import("page_store.zig");

const Hash = hash_mod.Hash;
const Entry = entry_mod.Entry;
const LeafEntry = node.LeafEntry;
const ChildRef = node.ChildRef;
const PageStore = page_store_mod.PageStore;
const PAGE_SIZE = node.PAGE_SIZE;

/// Content-defined chunking threshold for leaf pages.
/// When the low bits of an entry's key are all zero, the page is cut here
const LEAF_BOUNDARY_MASK: u64 = 0x1F;

/// Content-defined chunking threshold for internal pages.
const INTERNAL_BOUNDARY_MASK: u64 = 0xF;

fn toLeafEntry(e: Entry) LeafEntry {
    return .{
        .key = entry_mod.pathKey(e.path),
        .path = e.path,
        .blob_hash = e.blob_hash,
        .size = e.size,
        .mode = e.mode,
        .mtime = e.mtime,
    };
}

/// Serialize `entries` into a content-defined Merkle B-tree and return the
/// hash of its root page.
pub fn build(alloc: std.mem.Allocator, store: *const PageStore, entries: []const Entry) !Hash {
    if (entries.len == 0) return hash_mod.zero_hash;

    var level: std.ArrayList(ChildRef) = .empty;
    defer level.deinit(alloc);

    // Sort a local copy by B-tree key for page construction.
    const sorted_entries = try alloc.alloc(Entry, entries.len);
    defer alloc.free(sorted_entries);
    @memcpy(sorted_entries, entries);
    std.mem.sort(Entry, sorted_entries, {}, entry_mod.btreeLessThan);

    // Build leaf pages
    var offset: usize = 0;
    while (offset < sorted_entries.len) {
        var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;

        var writer = std.Io.Writer.fixed(page[node.LEAF_HEADER_LEN..]);
        const first_key = entry_mod.pathKey(sorted_entries[offset].path);
        var count: u16 = 0;

        while (offset < sorted_entries.len) {
            const e = sorted_entries[offset];
            const needed = node.leafEntryWireSize(e.path.len);
            if (needed > PAGE_SIZE - node.LEAF_HEADER_LEN) return error.IndexEntryTooLarge;

            // Hard page-size boundary: if we can't fit this entry and we've
            // already written at least one entry, start a new page
            if (writer.end + needed > page.len - node.LEAF_HEADER_LEN and count > 0) break;

            try node.writeLeafEntry(&writer, toLeafEntry(e));
            count += 1;
            offset += 1;

            // Content-defined boundary:  cut here based on key
            if (node.isChunkBoundary(entry_mod.pathKey(e.path), LEAF_BOUNDARY_MASK)) break;
        }

        node.writePageHeader(&page, node.LEAF_PAGE, count);
        const page_hash = try store.put(&page);
        try level.append(alloc, .{
            .separator = first_key,
            .page_hash = page_hash,
        });
    }

    // Build internal levels until only the root remains
    while (level.items.len > 1) {
        var next: std.ArrayList(ChildRef) = .empty;
        errdefer next.deinit(alloc);

        var child_offset: usize = 0;
        while (child_offset < level.items.len) {
            var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;

            var writer = std.Io.Writer.fixed(page[node.INTERNAL_HEADER_LEN..]);
            const first_separator = level.items[child_offset].separator;
            var child_count: u16 = 0;

            while (child_offset < level.items.len) {
                // Hard boundary check
                if (writer.end + node.CHILD_REF_LEN > page.len - node.INTERNAL_HEADER_LEN and child_count > 0) break;

                const child = level.items[child_offset];
                try writer.writeInt(u64, child.separator, .little);
                try writer.writeAll(&child.page_hash);
                child_count += 1;
                child_offset += 1;

                // Content-defined boundary based on child page hash
                if (node.isChunkBoundary(node.foldHashPrefix(child.page_hash), INTERNAL_BOUNDARY_MASK)) break;
            }

            node.writePageHeader(&page, node.INTERNAL_PAGE, child_count);
            const page_hash = try store.put(&page);
            try next.append(alloc, .{
                .separator = first_separator,
                .page_hash = page_hash,
            });
        }

        level.deinit(alloc);
        level = next;
    }

    return level.items[0].page_hash;
}

/// Recursively collect every entry reachable from `page_hash` into `out`,
/// in on-disk (key-sorted) order. Paths are freshly duplicated;
/// NOTE:  the caller owns them via whatever owns `out`.
pub fn collect(alloc: std.mem.Allocator, store: *const PageStore, page_hash: Hash, out: *std.ArrayList(Entry)) !void {
    var page = try store.get(page_hash);
    defer page.deinit(alloc);

    switch (page) {
        .leaf => |entries| {
            for (entries.items) |leaf_entry| {
                try out.append(alloc, .{
                    .path = try alloc.dupe(u8, leaf_entry.path),
                    .blob_hash = leaf_entry.blob_hash,
                    .size = leaf_entry.size,
                    .mode = leaf_entry.mode,
                    .mtime = leaf_entry.mtime,
                });
            }
        },
        .internal => |children| {
            for (children.items) |child| {
                try collect(alloc, store, child.page_hash, out);
            }
        },
    }
}

fn testEntry(alloc: std.mem.Allocator, path: []const u8, seed: u8) !Entry {
    return .{
        .path = try alloc.dupe(u8, path),
        .blob_hash = [_]u8{seed} ** 32,
        .size = seed,
        .mode = 0o644,
        .mtime = 0,
    };
}

fn freeTestEntries(alloc: std.mem.Allocator, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |*e| e.deinit(alloc);
    entries.deinit(alloc);
}

test "build of an empty entry list returns zero_hash without touching the store" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = PageStore{ .alloc = alloc, .dir = tmp.dir };

    const root = try build(alloc, &store, &.{});
    try std.testing.expectEqualSlices(u8, &hash_mod.zero_hash, &root);
}

test "build+collect round-trips a small entry set that fits one leaf page" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = PageStore{ .alloc = alloc, .dir = tmp.dir };

    var entries: std.ArrayList(Entry) = .empty;
    defer freeTestEntries(alloc, &entries);
    try entries.append(alloc, try testEntry(alloc, "b.txt", 2));
    try entries.append(alloc, try testEntry(alloc, "a.txt", 1));
    try entries.append(alloc, try testEntry(alloc, "c.txt", 3));

    const root = try build(alloc, &store, entries.items);
    try std.testing.expect(!std.mem.eql(u8, &root, &hash_mod.zero_hash));

    var collected: std.ArrayList(Entry) = .empty;
    defer freeTestEntries(alloc, &collected);
    try collect(alloc, &store, root, &collected);

    try std.testing.expectEqual(@as(usize, 3), collected.items.len);
    for (&[_][]const u8{ "a.txt", "b.txt", "c.txt" }) |want| {
        var found = false;
        for (collected.items) |e| {
            if (std.mem.eql(u8, e.path, want)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "build+collect round-trips a large entry set spanning multiple pages and levels" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = PageStore{ .alloc = alloc, .dir = tmp.dir };

    const n = 600;
    var entries: std.ArrayList(Entry) = .empty;
    defer freeTestEntries(alloc, &entries);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "dir/file-{d:0>4}.txt", .{i});
        try entries.append(alloc, try testEntry(alloc, name, @truncate(i)));
    }

    const root = try build(alloc, &store, entries.items);

    var collected: std.ArrayList(Entry) = .empty;
    defer freeTestEntries(alloc, &collected);
    try collect(alloc, &store, root, &collected);

    try std.testing.expectEqual(@as(usize, n), collected.items.len);

    // Every original entry must reappear with matching content — not just
    // matching count. Also confirms collect() traverses internal levels
    // correctly, since 600 short entries can't fit in a single 4KiB page.
    for (entries.items) |orig| {
        var found: ?Entry = null;
        for (collected.items) |c| {
            if (std.mem.eql(u8, c.path, orig.path)) found = c;
        }
        const c = found orelse return error.MissingEntry;
        try std.testing.expectEqualSlices(u8, &orig.blob_hash, &c.blob_hash);
        try std.testing.expectEqual(orig.size, c.size);
    }
}

test "build is deterministic — same entries in a different order produce the same root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = PageStore{ .alloc = alloc, .dir = tmp.dir };

    var forward: std.ArrayList(Entry) = .empty;
    defer freeTestEntries(alloc, &forward);
    var reversed: std.ArrayList(Entry) = .empty;
    defer freeTestEntries(alloc, &reversed);

    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (names) |name| try forward.append(alloc, try testEntry(alloc, name, 7));
    var idx = names.len;
    while (idx > 0) {
        idx -= 1;
        try reversed.append(alloc, try testEntry(alloc, names[idx], 7));
    }

    const root_a = try build(alloc, &store, forward.items);
    const root_b = try build(alloc, &store, reversed.items);
    try std.testing.expectEqualSlices(u8, &root_a, &root_b);
}
