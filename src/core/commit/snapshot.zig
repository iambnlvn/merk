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
const testing = std.testing;
const Io = std.Io;

const crypto = @import("crypto");
const testing_io = @import("testing.zig");

const Hash = crypto.Hash;

pub fn serialize(root: Hash, writer: *Io.Writer) !void {
    try writer.writeAll(&root);
}

pub fn deserialize(reader: *Io.Reader) !Hash {
    var root: Hash = undefined;
    try reader.readSliceAll(&root);
    return root;
}

test "serialize writes exactly 32 bytes, unmodified" {
    const root: Hash = [_]u8{0x42} ** 32;

    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();
    try serialize(root, sink.writer());

    try testing.expectEqual(@as(usize, 32), sink.bytes().len);
    try testing.expectEqualSlices(u8, &root, sink.bytes());
}

test "serialize/deserialize round-trip" {
    const root: Hash = [_]u8{0x7E} ** 32;

    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();
    try serialize(root, sink.writer());

    var reader = testing_io.fixedReader(sink.bytes());
    const decoded = try deserialize(&reader);

    try testing.expectEqualSlices(u8, &root, &decoded);
}

test "deserialize rejects truncated input" {
    const half_hash = [_]u8{0} ** 16;

    var reader = testing_io.fixedReader(&half_hash);
    try testing.expectError(error.EndOfStream, deserialize(&reader));
}
