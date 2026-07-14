const std = @import("std");
const hash_mod = @import("../hash.zig");
const format = @import("format.zig");
const entry_mod = @import("entry.zig");
const page_store_mod = @import("page_store.zig");

const Hash = hash_mod.Hash;
const Entry = entry_mod.Entry;
const LeafEntry = format.LeafEntry;
const ChildRef = format.ChildRef;
const PageStore = page_store_mod.PageStore;
const PAGE_SIZE = format.PAGE_SIZE;

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
    if (entries.len == 0) return hash_mod.ZERO_HASH;

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
        page[0] = format.LEAF_PAGE;

        var writer = std.Io.Writer.fixed(page[format.LEAF_HEADER_LEN..]);
        const first_key = entry_mod.pathKey(sorted_entries[offset].path);
        var count: u16 = 0;

        while (offset < sorted_entries.len) {
            const e = sorted_entries[offset];
            const needed = format.leafEntryWireSize(e.path.len);
            if (needed > PAGE_SIZE - format.LEAF_HEADER_LEN) return error.IndexEntryTooLarge;

            // Hard page-size boundary: if we can't fit this entry and we've
            // already written at least one entry, start a new page
            if (writer.end + needed > page.len - format.LEAF_HEADER_LEN and count > 0) break;

            try format.writeLeafEntry(&writer, toLeafEntry(e));
            count += 1;
            offset += 1;

            // Content-defined boundary:  cut here based on key
            if (format.isChunkBoundary(entry_mod.pathKey(e.path), LEAF_BOUNDARY_MASK)) break;
        }

        std.mem.writeInt(u16, page[2..4], count, .little);
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
            page[0] = format.INTERNAL_PAGE;

            var writer = std.Io.Writer.fixed(page[format.INTERNAL_HEADER_LEN..]);
            const first_separator = level.items[child_offset].separator;
            var child_count: u16 = 0;

            while (child_offset < level.items.len) {
                // Hard boundary check
                if (writer.end + format.CHILD_REF_LEN > page.len - format.INTERNAL_HEADER_LEN and child_count > 0) break;

                const child = level.items[child_offset];
                try writer.writeInt(u64, child.separator, .little);
                try writer.writeAll(&child.page_hash);
                child_count += 1;
                child_offset += 1;

                // Content-defined boundary based on child page hash
                if (format.isChunkBoundary(format.foldHashPrefix(child.page_hash), INTERNAL_BOUNDARY_MASK)) break;
            }

            std.mem.writeInt(u16, page[2..4], child_count, .little);
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
