//! The commit's pointer to "what the working state looked like": a
//! single opaque content hash.
//!
//! This module deliberately knows nothing about what produced that
//! hash — a Merkle B-tree root today, potentially a different
//! content-addressed structure tomorrow. `commit.zig` never looks past
//! this one 32-byte value, so swapping out whatever computes it never
//! touches commit semantics. There is no wrapper struct here on
//! purpose: a snapshot IS just a hash, and giving it its own type would
//! only add indirection between `Commit.snapshot` and the bytes it
//! actually is.

const std = @import("std");
const Hash = [32]u8;

pub fn serialize(root: Hash, writer: anytype) !void {
    try writer.writeAll(&root);
}

pub fn deserialize(reader: anytype) !Hash {
    const bytes = try reader.take(32);
    var root: Hash = undefined;
    @memcpy(&root, bytes);
    return root;
}

test "serialize writes exactly 32 bytes, unmodified" {
    const root: Hash = [_]u8{0x42} ** 32;

    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serialize(root, buf.writer(alloc));

    try std.testing.expectEqual(@as(usize, 32), buf.items.len);
    try std.testing.expectEqualSlices(u8, &root, buf.items);
}

test "serialize/deserialize round-trip" {
    const root: Hash = [_]u8{0x7E} ** 32;

    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serialize(root, buf.writer(alloc));

    const MockReader = @import("testing.zig").MockReader;
    var mock_reader = MockReader{ .buffer = buf.items };
    const decoded = try deserialize(&mock_reader);

    try std.testing.expectEqualSlices(u8, &root, &decoded);
}

test "deserialize rejects truncated input" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, &([_]u8{0} ** 16)); // half a hash

    const MockReader = @import("testing.zig").MockReader;
    var mock_reader = MockReader{ .buffer = buf.items };
    try std.testing.expectError(error.EndOfStream, deserialize(&mock_reader));
}
