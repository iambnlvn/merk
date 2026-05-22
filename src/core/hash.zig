//  BLAKE3 is used for all content-addressed identifiers
//  This module provides:
//    - Hash type  (32-byte array)
//    - blake3()   shortcut for hashing byte slices
//    - Hasher     streaming context (update / final)
//    - hex / parse helpers

const std = @import("std");

/// 256-bit BLAKE3 digest
pub const Hash = [32]u8;

/// All-zero sentinel used as "no hash" / null parent
pub const ZERO_HASH: Hash = [_]u8{0} ** 32;

/// Hash an arbitrary byte slice in one call
pub fn blake3(data: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(data, &out, .{});
    return out;
}

/// Hash multiple slices as if they were concatenated
pub fn blake3Many(parts: []const []const u8) Hash {
    var h = std.crypto.hash.Blake3.init(.{});
    for (parts) |p| h.update(p);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

pub const Hasher = struct {
    inner: std.crypto.hash.Blake3,

    pub fn init() Hasher {
        return .{ .inner = std.crypto.hash.Blake3.init(.{}) };
    }

    pub fn update(self: *Hasher, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn final(self: *Hasher) Hash {
        var out: Hash = undefined;
        self.inner.final(&out);
        return out;
    }
};

/// Encode a Hash into a 64-char lowercase hex string.
/// Caller owns the returned slice (allocated with `alloc`)
pub fn toHex(alloc: std.mem.Allocator, h: Hash) ![]u8 {
    const hex = try alloc.alloc(u8, 64);
    errdefer alloc.free(hex);
    const hex_array = std.fmt.bytesToHex(h, .lower);
    @memcpy(hex, &hex_array);

    return hex;
}

/// Decode a 64-char hex string into a Hash
pub fn fromHex(s: []const u8) !Hash {
    if (s.len != 64) return error.InvalidHexLength;

    var out: Hash = undefined;
    _ = try std.fmt.hexToBytes(&out, s);

    return out;
}

/// First 8 hex chars — useful for display / directory sharding
pub fn shortHex(h: Hash) [8]u8 {
    var buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{}", .{
        std.fmt.fmtSliceHexLower(h[0..4]),
    }) catch unreachable;
    return buf;
}

test "blake3 deterministic" {
    const h1 = blake3("hello world");
    const h2 = blake3("hello world");
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "blake3 different inputs differ" {
    const h1 = blake3("hello");
    const h2 = blake3("world");
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "blake3Many equals concatenation" {
    const combined = blake3("helloworld");
    const parts: []const []const u8 = &.{ "hello", "world" };
    const streamed = blake3Many(parts);
    try std.testing.expectEqualSlices(u8, &combined, &streamed);
}

test "hex round-trip" {
    const h = blake3("round trip test");
    const alloc = std.testing.allocator;
    const hex = try toHex(alloc, h);
    defer alloc.free(hex);
    const decoded = try fromHex(hex);
    try std.testing.expectEqualSlices(u8, &h, &decoded);
}
