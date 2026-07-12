const std = @import("std");
const hash_mod = @import("../hash.zig");

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

/// Parse a page's raw bytes into an in-memory `Page`, dispatching on the
/// page-kind tag in the first byte
pub fn parsePage(alloc: std.mem.Allocator, bytes: *const [PAGE_SIZE]u8) DiffError!Page {
    return switch (bytes[0]) {
        LEAF_PAGE => parseLeafPage(alloc, bytes),
        INTERNAL_PAGE => parseInternalPage(alloc, bytes),
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

        // Enforce sorted order invariant
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
