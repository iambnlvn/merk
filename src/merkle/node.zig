const std = @import("std");
const hash_mod = @import("merk").hash;

pub const Hash = hash_mod.Hash;

pub const MAGIC: u32 = 0x4E_4F_44_55;
pub const VERSION: u8 = 1;

/// Fixed page size for all index pages. Must be large enough to hold at
/// least one entry plus headers.
pub const PAGE_SIZE: usize = 4096;

pub const LEAF_PAGE: u8 = 0x01;
pub const INTERNAL_PAGE: u8 = 0x02;

/// Derived key used for B-tree ordering and content-defined chunking.
pub const PathKey = u64;

// Header sizes are shared between whatever builds pages (btree.zig) and the
// parser below, since both must agree on where the entry/child stream
// starts within a page.
pub const LEAF_HEADER_LEN: usize = 8;
pub const INTERNAL_HEADER_LEN: usize = 8;

// Fixed portion of a serialized leaf entry: key(8) + path_len(2) + hash(32)
// + size(8) + mode(8) + mtime(16). The variable portion is the path bytes.
const LEAF_ENTRY_FIXED_LEN: usize = 8 + 2 + 32 + 8 + 8 + 16;

/// Serialized size of an internal child reference: separator(8) + hash(32).
pub const CHILD_REF_LEN: usize = 8 + 32;

pub const DiffError = error{
    OutOfMemory,
    NotFound,
    HashMismatch,
    CorruptIndexPage,
    CorruptIndex,
    UnsupportedPageVersion,
    EndOfStream,
    ReadFailed,
} || std.fs.File.OpenError || std.fs.File.ReadError;

/// Serialized form of an entry as stored in a leaf page.
/// The `path` slice is owned and must be freed when the containing `Page`
/// is deinitialized.
pub const LeafEntry = struct {
    key: PathKey,
    path: []u8,
    blob_hash: Hash,
    size: u64,
    mode: u64,
    mtime: i128,
};

/// Reference to a child page from an internal node.
pub const ChildRef = struct {
    /// The minimum key contained in the child subtree.
    separator: PathKey,
    /// Content hash of the child page.
    page_hash: Hash,
};

/// In-memory representation of a parsed page
/// Memory is managed by the allocator passed to `parsePage` and must be
/// freed with `Page.deinit`
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

pub fn hashEq(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
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

/// Test whether a key represents a content-defined chunk boundary.
pub fn isChunkBoundary(key: u64, mask: u64) bool {
    return (key & mask) == 0;
}

/// Wire size of a leaf entry given its path length.
pub fn leafEntryWireSize(path_len: usize) usize {
    return LEAF_ENTRY_FIXED_LEN + path_len;
}

/// Byte layout of the shared 8-byte page header:
///   [0]     page kind tag (LEAF_PAGE / INTERNAL_PAGE)
///   [1]     format version
///   [2..4]  entry/child count, u16 LE
///   [4..8]  magic, u32 LE
/// Both LEAF_HEADER_LEN and INTERNAL_HEADER_LEN equal this and must keep
/// doing so — the two are kept as separate named constants only so leaf vs.
/// internal call sites stay self-documenting, not because the layout differs.
///
/// Write a page header in place. Callers (btree.zig) fill the entry/child
/// stream starting at the appropriate `*_HEADER_LEN` offset afterward.
pub fn writePageHeader(page: *[PAGE_SIZE]u8, kind: u8, count: u16) void {
    page[0] = kind;
    page[1] = VERSION;
    std.mem.writeInt(u16, page[2..4], count, .little);
    std.mem.writeInt(u32, page[4..8], MAGIC, .little);
}

const PageHeader = struct { kind: u8, count: u16 };

/// Validate magic + version and read back the kind tag and count.
/// This is what makes MAGIC/VERSION load-bearing: without it, a page from
/// a future/incompatible format would silently dispatch on the tag byte
/// instead of failing loudly.
fn readPageHeader(bytes: *const [PAGE_SIZE]u8) DiffError!PageHeader {
    const magic = std.mem.readInt(u32, bytes[4..8], .little);
    if (magic != MAGIC) return error.CorruptIndexPage;
    if (bytes[1] != VERSION) return error.UnsupportedPageVersion;
    return .{ .kind = bytes[0], .count = std.mem.readInt(u16, bytes[2..4], .little) };
}

/// Parse a page's raw bytes into an in-memory `Page`, dispatching on the
/// page-kind tag in the first byte
pub fn parsePage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8) DiffError!Page {
    const header = try readPageHeader(bytes);
    return switch (header.kind) {
        LEAF_PAGE => parseLeafPage(alloc, bytes, header.count),
        INTERNAL_PAGE => parseInternalPage(alloc, bytes, header.count),
        else => error.CorruptIndexPage,
    };
}

fn parseLeafPage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8, count: u16) DiffError!Page {
    // A leaf page is never built with zero entries (btree.build bails out
    // before writing an empty tree at all) — a count of 0 here means a
    // corrupt or hand-crafted page, not a legitimate empty leaf.
    if (count == 0) return error.CorruptIndexPage;

    var reader = std.Io.Reader.fixed(bytes[LEAF_HEADER_LEN..]);
    var entries: std.ArrayList(LeafEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| alloc.free(entry.path);
        entries.deinit(alloc);
    }

    var last_key: ?PathKey = null;
    var last_path: []const u8 = &.{};
    for (0..count) |_| {
        const key = try reader.takeInt(u64, .little);
        const path_len = try reader.takeInt(u16, .little);
        if (path_len == 0) return error.CorruptIndexPage;

        const path = try alloc.alloc(u8, path_len);
        errdefer alloc.free(path);
        @memcpy(path, try reader.take(path_len));

        var blob_hash: Hash = undefined;
        @memcpy(&blob_hash, try reader.take(blob_hash.len));

        // Enforce sorted order invariant: key must be non-decreasing, and
        // ties (two different paths folding to the same key) must still be
        // in path order — btree.build always produces this via
        // entry_mod.btreeLessThan, so a violation here means corruption,
        // not a legitimate hash collision.
        if (last_key) |prev| {
            if (key < prev) return error.CorruptIndexPage;
            if (key == prev and !std.mem.lessThan(u8, last_path, path)) return error.CorruptIndexPage;
        }
        last_key = key;
        last_path = path;

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

fn parseInternalPage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8, count: u16) DiffError!Page {
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

/// Write a single leaf entry's wire bytes. Field order defines the format.
pub fn writeLeafEntry(writer: *std.Io.Writer, entry: LeafEntry) !void {
    try writer.writeInt(u64, entry.key, .little);
    try writer.writeInt(u16, @intCast(entry.path.len), .little);
    try writer.writeAll(entry.path);
    try writer.writeAll(&entry.blob_hash);
    try writer.writeInt(u64, entry.size, .little);
    try writer.writeInt(u64, entry.mode, .little);
    try writer.writeInt(i128, entry.mtime, .little);
}

fn testLeaf(key: PathKey, path: []const u8) LeafEntry {
    return .{ .key = key, .path = @constCast(path), .blob_hash = hash_mod.ZERO_HASH, .size = 1, .mode = 0o644, .mtime = 0 };
}

fn buildTestLeafPage(page: *[PAGE_SIZE]u8, entries: []const LeafEntry) !void {
    writePageHeader(page, LEAF_PAGE, @intCast(entries.len));
    var writer = std.Io.Writer.fixed(page[LEAF_HEADER_LEN..]);
    for (entries) |e| try writeLeafEntry(&writer, e);
}

test "leaf page round-trips through writePageHeader/writeLeafEntry/parsePage" {
    var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
    try buildTestLeafPage(&page, &.{ testLeaf(1, "a"), testLeaf(2, "b") });

    const alloc = std.testing.allocator;
    var parsed = try parsePage(alloc, &page);
    defer parsed.deinit(alloc);

    try std.testing.expect(parsed == .leaf);
    try std.testing.expectEqual(@as(usize, 2), parsed.leaf.items.len);
    try std.testing.expectEqualStrings("a", parsed.leaf.items[0].path);
    try std.testing.expectEqualStrings("b", parsed.leaf.items[1].path);
}

test "parsePage rejects a bad magic" {
    var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
    try buildTestLeafPage(&page, &.{testLeaf(1, "a")});
    std.mem.writeInt(u32, page[4..8], MAGIC +% 1, .little);

    try std.testing.expectError(error.CorruptIndexPage, parsePage(std.testing.allocator, &page));
}

test "parsePage rejects an unsupported version" {
    var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
    try buildTestLeafPage(&page, &.{testLeaf(1, "a")});
    page[1] = VERSION +% 1;

    try std.testing.expectError(error.UnsupportedPageVersion, parsePage(std.testing.allocator, &page));
}

test "parsePage rejects a leaf page claiming zero entries" {
    var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
    writePageHeader(&page, LEAF_PAGE, 0);

    try std.testing.expectError(error.CorruptIndexPage, parsePage(std.testing.allocator, &page));
}

test "parsePage rejects an internal page claiming zero children" {
    var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
    writePageHeader(&page, INTERNAL_PAGE, 0);

    try std.testing.expectError(error.CorruptIndexPage, parsePage(std.testing.allocator, &page));
}

test "parsePage rejects same-key leaf entries stored out of path order" {
    var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
    // Same key (1) but "b" before "a" — btreeLessThan would never produce
    // this ordering, so a parser that accepts it can't be trusted to
    // reject other corruption either.
    try buildTestLeafPage(&page, &.{ testLeaf(1, "b"), testLeaf(1, "a") });

    try std.testing.expectError(error.CorruptIndexPage, parsePage(std.testing.allocator, &page));
}

test "parsePage accepts same-key leaf entries that are correctly ordered" {
    var page: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
    try buildTestLeafPage(&page, &.{ testLeaf(1, "a"), testLeaf(1, "b") });

    const alloc = std.testing.allocator;
    var parsed = try parsePage(alloc, &page);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), parsed.leaf.items.len);
}

test "isChunkBoundary matches masked low bits" {
    try std.testing.expect(isChunkBoundary(0b10000, 0b01111));
    try std.testing.expect(!isChunkBoundary(0b10001, 0b01111));
}

test "leafEntryWireSize accounts for the variable-length path" {
    try std.testing.expectEqual(leafEntryWireSize(0), leafEntryWireSize(5) - 5);
}
