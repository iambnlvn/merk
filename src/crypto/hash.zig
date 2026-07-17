const std = @import("std");

/// 256-bit BLAKE3 digest
pub const Hash = [32]u8;

/// All-zero sentinel used as "no hash" / null parent
pub const zero_hash: Hash = [_]u8{0} ** 32;

pub const HEX_LEN = 64;
pub const SHORT_HEX_LEN = 8;
pub const MIN_PREFIX_LEN = 8;

pub const HexError = error{
    InvalidHexLength,
    InvalidCharacter,
};

/// Hash an arbitrary byte slice in one call (no domain separation —
/// use blake3Domain for anything that goes into the Merkle structures)
pub fn blake3(data: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(data, &out, .{});
    return out;
}

/// Hash multiple slices as if they were concatenated (no domain separation)
pub fn blake3Many(parts: []const []const u8) Hash {
    var h = std.crypto.hash.Blake3.init(.{});
    for (parts) |p| h.update(p);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

/// Domain-separated hashing so a leaf's bytes can never collide with an
/// internal node's bytes, a page's bytes, etc. Pick one fixed context
/// string per "kind" of thing you hash, and version it if the encoding
/// changes (e.g. "merk.leaf.v1", "merk.internal.v1", "merk.commit.v1").
pub fn blake3Domain(context: []const u8, parts: []const []const u8) Hash {
    var h = std.crypto.hash.Blake3.initKdf(context, .{});
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

    /// Streaming variant of blake3Domain — start a domain-separated hash
    /// context to update() incrementally.
    pub fn initDomain(context: []const u8) Hasher {
        return .{ .inner = std.crypto.hash.Blake3.initKdf(context, .{}) };
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

pub fn eql(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn isZero(h: Hash) bool {
    return eql(h, zero_hash);
}

/// Zero-alloc hex encode — prefer this unless you need an owned slice
pub fn toHexBuf(h: Hash) [HEX_LEN]u8 {
    return std.fmt.bytesToHex(h, .lower);
}

/// Encode a Hash into a 64-char lowercase hex string.
/// Caller owns the returned slice (allocated with `alloc`)
pub fn toHex(alloc: std.mem.Allocator, h: Hash) ![]u8 {
    const buf = toHexBuf(h);
    return alloc.dupe(u8, &buf);
}

/// Decode a 64-char hex string into a Hash
pub fn fromHex(s: []const u8) HexError!Hash {
    if (s.len != HEX_LEN) return error.InvalidHexLength;

    var out: Hash = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.InvalidCharacter;

    return out;
}

/// Validate a hex string is well-formed as a prefix (8-64 chars, all hex).
/// Call this once, then use matchesPrefix for the actual comparison.
pub fn parseHexPrefix(s: []const u8) HexError!void {
    if (s.len < MIN_PREFIX_LEN or s.len > HEX_LEN) return error.InvalidHexLength;

    for (s) |c| {
        const is_digit = c >= '0' and c <= '9';
        const is_lower_hex = c >= 'a' and c <= 'f';
        const is_upper_hex = c >= 'A' and c <= 'F';
        if (!(is_digit or is_lower_hex or is_upper_hex)) return error.InvalidCharacter;
    }
}

/// Does `h` start with the given hex prefix (case-insensitive)?
/// Caller should validate the prefix once with parseHexPrefix first.
pub fn matchesPrefix(h: Hash, prefix: []const u8) bool {
    const buf = toHexBuf(h);
    if (prefix.len > buf.len) return false;
    return std.ascii.eqlIgnoreCase(buf[0..prefix.len], prefix);
}

/// First 8 hex chars, for display / directory sharding
pub fn shortHex(h: Hash) [SHORT_HEX_LEN]u8 {
    return std.fmt.bytesToHex(h[0..4].*, .lower);
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

test "blake3Domain differs across contexts on same bytes" {
    const parts: []const []const u8 = &.{ "same", "bytes" };
    const leaf = blake3Domain("merk.leaf.v1", parts);
    const internal = blake3Domain("merk.internal.v1", parts);
    try std.testing.expect(!eql(leaf, internal));
}

test "blake3Domain deterministic per context" {
    const parts: []const []const u8 = &.{ "same", "bytes" };
    const h1 = blake3Domain("merk.leaf.v1", parts);
    const h2 = blake3Domain("merk.leaf.v1", parts);
    try std.testing.expect(eql(h1, h2));
}

test "blake3Domain differs from undomained blake3Many on same bytes" {
    const parts: []const []const u8 = &.{ "same", "bytes" };
    const plain = blake3Many(parts);
    const domained = blake3Domain("merk.leaf.v1", parts);
    try std.testing.expect(!eql(plain, domained));
}

test "hex round-trip" {
    const h = blake3("round trip test");
    const alloc = std.testing.allocator;
    const hex = try toHex(alloc, h);
    defer alloc.free(hex);
    const decoded = try fromHex(hex);
    try std.testing.expectEqualSlices(u8, &h, &decoded);
}

test "toHexBuf matches toHex" {
    const h = blake3("buf vs alloc");
    const buf = toHexBuf(h);
    const alloc = std.testing.allocator;
    const heap = try toHex(alloc, h);
    defer alloc.free(heap);
    try std.testing.expectEqualSlices(u8, &buf, heap);
}

test "fromHex rejects wrong length" {
    try std.testing.expectError(error.InvalidHexLength, fromHex("abcd"));
    try std.testing.expectError(error.InvalidHexLength, fromHex("a" ** 63));
    try std.testing.expectError(error.InvalidHexLength, fromHex("a" ** 65));
}

test "fromHex rejects invalid characters" {
    var bad: [64]u8 = [_]u8{'a'} ** 64;
    bad[10] = 'z';
    try std.testing.expectError(error.InvalidCharacter, fromHex(&bad));
}

test "parseHexPrefix accepts valid prefixes" {
    try parseHexPrefix("deadbeef");
    try parseHexPrefix("DEADBEEF");
    try parseHexPrefix("a" ** 64);
}

test "parseHexPrefix rejects short prefix" {
    try std.testing.expectError(error.InvalidHexLength, parseHexPrefix("a" ** 7));
}

test "parseHexPrefix rejects too-long prefix" {
    try std.testing.expectError(error.InvalidHexLength, parseHexPrefix("a" ** 65));
}

test "parseHexPrefix rejects bad characters" {
    try std.testing.expectError(error.InvalidCharacter, parseHexPrefix("deadbeez"));
    try std.testing.expectError(error.InvalidCharacter, parseHexPrefix("zzzzzzzz"));
}

test "matchesPrefix true positive and negative" {
    const h = blake3("prefix match test");
    const buf = toHexBuf(h);
    try std.testing.expect(matchesPrefix(h, buf[0..8]));
    try std.testing.expect(!matchesPrefix(h, "ffffffff"));
}

test "matchesPrefix is case-insensitive" {
    const h = blake3("case insensitive");
    const buf = toHexBuf(h);
    var upper: [8]u8 = undefined;
    for (buf[0..8], 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    try std.testing.expect(matchesPrefix(h, &upper));
}

test "isZero" {
    try std.testing.expect(isZero(zero_hash));
    try std.testing.expect(!isZero(blake3("not zero")));
}
