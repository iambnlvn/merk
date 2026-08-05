//    [4]  magic   = 0x4D_45_52_4B  ("MERK")
//    [1]  version = 2
//    [1]  type    = ObjectType (u8)
//    [1]  codec   = compression.Codec (u8)
//    [1]  flags   = bit 0: has structural hash
//    [4]  payload length (u32, uncompressed)
//    [4]  stored length  (u32, bytes on disk)
//    [n]  stored bytes   (raw or compressed depending on codec)
//    [32] BLAKE3 content hash of (type ++ original payload)
//    [32] BLAKE3 structural hash (optional, present if flags bit 0 is set)

const std = @import("std");
const compression = @import("merk").compression;
const hash_mod = @import("merk").crypto.hash;

pub const Hash = hash_mod.Hash;

pub const ObjectType = enum(u8) {
    blob = 1,
    tree = 2,
    commit = 3,
    ast = 4,
};

pub const MAGIC: u32 = 0x4D_45_52_4B;
pub const VERSION: u8 = 2;

/// Size in bytes of the fixed-width header described above.
pub const header_len = 16;
const hash_len = @sizeOf(Hash);

/// Size in bytes of the structural hash trailer, when present. Exported
/// so `Store` can compute trailer offsets without reaching into this
/// module's internals.
pub const structural_hash_len = hash_len;

const flag_has_structural_hash: u8 = 1 << 0;

pub const ObjectHeader = struct {
    version: u8,
    obj_type: ObjectType,
    codec: compression.Codec,
    payload_len: u32,
    stored_len: u32,
    has_structural_hash: bool,
};

pub const Object = struct {
    obj_type: ObjectType,
    payload: []u8,
    /// Round-tripped exactly as encoded. See the trust-boundary note
    /// above: this is not integrity-checked the way content hashing is.
    structural_hash: ?Hash = null,
};

pub const EncodedObject = struct {
    bytes: []u8,
    hash: Hash,
};

/// Bytes appended after the stored body: the content hash always, plus
/// the structural hash trailer when present. `encodeAlloc` and
/// `decodeFromBuffer` both need this to size/locate the trailer — one
/// place for it, so encode and decode can't quietly drift apart on how
/// big the tail is.
fn trailerLen(has_structural_hash: bool) usize {
    return hash_len + (if (has_structural_hash) @as(usize, structural_hash_len) else 0);
}

pub fn encodeAlloc(
    alloc: std.mem.Allocator,
    obj_type: ObjectType,
    payload: []const u8,
    codec: compression.Codec,
    structural_hash: ?Hash,
) !EncodedObject {
    const type_byte = [1]u8{@intFromEnum(obj_type)};
    const parts: []const []const u8 = &.{ &type_byte, payload };
    const obj_hash = hash_mod.blake3Many(parts);

    const stored = try compressAlloc(alloc, codec, payload);
    defer alloc.free(stored);

    const trailer_len: usize = trailerLen(structural_hash != null);
    const total_len = header_len + stored.len + trailer_len;
    const bytes = try alloc.alloc(u8, total_len);
    errdefer alloc.free(bytes);

    encodeHeaderInto(bytes[0..header_len], .{
        .version = VERSION,
        .obj_type = obj_type,
        .codec = codec,
        .payload_len = @intCast(payload.len),
        .stored_len = @intCast(stored.len),
        .has_structural_hash = structural_hash != null,
    });
    @memcpy(bytes[header_len .. header_len + stored.len], stored);
    @memcpy(bytes[header_len + stored.len ..][0..hash_len], &obj_hash);
    if (structural_hash) |sh| {
        @memcpy(bytes[header_len + stored.len + hash_len ..][0..structural_hash_len], &sh);
    }

    return .{ .bytes = bytes, .hash = obj_hash };
}

/// Fully decode an object: header, decompressed body, verified content
/// hash. Fails closed on every structural anomaly — bad magic, wrong
/// version, out-of-range enum bytes, a length that doesn't match the
/// header's claims, or a content hash mismatch all return an error
/// rather than a partially-trustworthy `Object`
pub fn decodeFromBuffer(alloc: std.mem.Allocator, bytes: []const u8) !Object {
    if (bytes.len < header_len) return error.CorruptObject;
    const header = try decodeHeaderFromBuffer(bytes[0..header_len]);

    const trailer_len: usize = trailerLen(header.has_structural_hash);
    const expected_len = header_len + @as(usize, header.stored_len) + trailer_len;
    if (bytes.len != expected_len) return error.CorruptObject;

    const stored = bytes[header_len .. header_len + header.stored_len];
    const content_trailer = bytes[header_len + header.stored_len ..][0..hash_len];

    const payload = try compression.decodeAlloc(alloc, header.codec, stored, header.payload_len);
    errdefer alloc.free(payload);

    const type_byte = [1]u8{@intFromEnum(header.obj_type)};
    const parts: []const []const u8 = &.{ &type_byte, payload };
    const computed = hash_mod.blake3Many(parts);
    if (!std.mem.eql(u8, &computed, content_trailer)) return error.HashMismatch;

    var structural_hash: ?Hash = null;
    if (header.has_structural_hash) {
        const sh_bytes = bytes[header_len + header.stored_len + hash_len ..][0..structural_hash_len];
        var sh: Hash = undefined;
        @memcpy(&sh, sh_bytes);
        structural_hash = sh;
    }

    return .{ .obj_type = header.obj_type, .payload = payload, .structural_hash = structural_hash };
}

/// Decode just the fixed header, without touching the body. This is the
/// primitive `Store.getHeader` and `Store.getStructuralHash` build on to
/// answer cheap questions ("does this object have a structural hash?")
/// without paying for a decompress.
///
/// `bytes` is untrusted — it comes straight off disk and may be
/// truncated, bit-rotted, or hostile. Validation applied, in order:
///
///   - magic mismatch      -> `error.CorruptObject`
///   - version mismatch    -> `error.UnsupportedVersion` (distinct from
///                             CorruptObject: "I don't know how to read
///                             this version" vs. "this is garbage")
///   - `type`/`codec` byte with no matching enum tag -> `error.CorruptObject`.
pub fn decodeHeaderFromBuffer(bytes: []const u8) !ObjectHeader {
    if (bytes.len < header_len) return error.CorruptObject;

    const magic = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic != MAGIC) return error.CorruptObject;

    const version = bytes[4];
    if (version != VERSION) return error.UnsupportedVersion;

    const obj_type = std.meta.intToEnum(ObjectType, bytes[5]) catch return error.CorruptObject;
    const codec = std.meta.intToEnum(compression.Codec, bytes[6]) catch return error.CorruptObject;

    const flags = bytes[7];
    const payload_len = std.mem.readInt(u32, bytes[8..12], .little);
    const stored_len = std.mem.readInt(u32, bytes[12..16], .little);

    return .{
        .version = version,
        .obj_type = obj_type,
        .codec = codec,
        .payload_len = payload_len,
        .stored_len = stored_len,
        .has_structural_hash = (flags & flag_has_structural_hash) != 0,
    };
}

fn encodeHeaderInto(buf: *[header_len]u8, header: ObjectHeader) void {
    std.mem.writeInt(u32, buf[0..4], MAGIC, .little);
    buf[4] = header.version;
    buf[5] = @intFromEnum(header.obj_type);
    buf[6] = @intFromEnum(header.codec);
    buf[7] = if (header.has_structural_hash) flag_has_structural_hash else 0;
    std.mem.writeInt(u32, buf[8..12], header.payload_len, .little);
    std.mem.writeInt(u32, buf[12..16], header.stored_len, .little);
}

/// Byte offset of the structural hash trailer within an encoded object's
/// bytes. Only valid when `header.has_structural_hash` is true — callers
/// (e.g. Store.getStructuralHash) should check that first.
pub fn structuralHashOffset(header: ObjectHeader) usize {
    return header_len + @as(usize, header.stored_len) + hash_len;
}

// TODO(chunking): content-defined chunking — splitting large payloads
// into chunks referenced by a manifest object instead of one monolithic
// blob — would plug in here via a real chunk callback passed to
// `compression.encodeBody`. `noOpChunk` is a placeholder satisfying that
// callback's signature until chunking exists; it performs no chunking.
fn noOpChunk(_: []const u8) void {}

fn compressAlloc(alloc: std.mem.Allocator, codec: compression.Codec, payload: []const u8) ![]u8 {
    if (codec == .none) return try alloc.dupe(u8, payload);

    var reader = std.Io.Reader.fixed(payload);
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try compression.encodeBody(&aw.writer, &reader, payload.len, codec, noOpChunk);
    return try aw.toOwnedSlice();
}

test "encodeAlloc/decodeFromBuffer round-trip for every object type" {
    const alloc = std.testing.allocator;
    const payload = "content-addressed storage";

    inline for (.{ ObjectType.blob, ObjectType.tree, ObjectType.commit, ObjectType.ast }) |t| {
        const encoded = try encodeAlloc(alloc, t, payload, .none, null);
        defer alloc.free(encoded.bytes);

        const obj = try decodeFromBuffer(alloc, encoded.bytes);
        defer alloc.free(obj.payload);

        try std.testing.expectEqual(t, obj.obj_type);
        try std.testing.expectEqualStrings(payload, obj.payload);
        try std.testing.expect(obj.structural_hash == null);
    }
}

test "same payload under different object types hashes differently" {
    const alloc = std.testing.allocator;
    const payload = "same bytes, different meaning";

    const as_blob = try encodeAlloc(alloc, .blob, payload, .none, null);
    defer alloc.free(as_blob.bytes);
    const as_tree = try encodeAlloc(alloc, .tree, payload, .none, null);
    defer alloc.free(as_tree.bytes);

    try std.testing.expect(!std.mem.eql(u8, &as_blob.hash, &as_tree.hash));
}

test "empty payload round-trips" {
    const alloc = std.testing.allocator;

    const encoded = try encodeAlloc(alloc, .blob, "", .none, null);
    defer alloc.free(encoded.bytes);

    const obj = try decodeFromBuffer(alloc, encoded.bytes);
    defer alloc.free(obj.payload);

    try std.testing.expectEqual(@as(usize, 0), obj.payload.len);
}

test "large payload round-trips" {
    const alloc = std.testing.allocator;
    const payload = "node graph semantic history " ** 512;

    const encoded = try encodeAlloc(alloc, .commit, payload, .none, null);
    defer alloc.free(encoded.bytes);

    const obj = try decodeFromBuffer(alloc, encoded.bytes);
    defer alloc.free(obj.payload);

    try std.testing.expectEqualStrings(payload, obj.payload);
}

test "codec none stores the payload verbatim" {
    const alloc = std.testing.allocator;
    const payload = "raw passthrough";

    const encoded = try encodeAlloc(alloc, .blob, payload, .none, null);
    defer alloc.free(encoded.bytes);

    const stored = encoded.bytes[header_len .. encoded.bytes.len - hash_len];
    try std.testing.expectEqualStrings(payload, stored);
}

test "decodeHeaderFromBuffer rejects wrong magic" {
    var bytes: [header_len]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 0xDEAD_BEEF, .little);
    @memset(bytes[4..], 0);

    try std.testing.expectError(error.CorruptObject, decodeHeaderFromBuffer(&bytes));
}

test "decodeHeaderFromBuffer rejects unsupported version" {
    var bytes: [header_len]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], MAGIC, .little);
    bytes[4] = 1; // legacy v1
    @memset(bytes[5..], 0);

    try std.testing.expectError(error.UnsupportedVersion, decodeHeaderFromBuffer(&bytes));
}

test "decodeHeaderFromBuffer rejects a truncated buffer" {
    var bytes: [header_len - 3]u8 = undefined;
    @memset(&bytes, 0);
    try std.testing.expectError(error.CorruptObject, decodeHeaderFromBuffer(&bytes));
}

test "decodeHeaderFromBuffer rejects an out-of-range object type byte" {
    var bytes: [header_len]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], MAGIC, .little);
    bytes[4] = VERSION;
    bytes[5] = 0xFF; // no ObjectType tag is 255
    bytes[6] = 0;
    @memset(bytes[7..], 0);

    try std.testing.expectError(error.CorruptObject, decodeHeaderFromBuffer(&bytes));
}

test "decodeHeaderFromBuffer rejects an out-of-range codec byte" {
    var bytes: [header_len]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], MAGIC, .little);
    bytes[4] = VERSION;
    bytes[5] = @intFromEnum(ObjectType.blob);
    bytes[6] = 0xFF; // no Codec tag is 255
    @memset(bytes[7..], 0);

    try std.testing.expectError(error.CorruptObject, decodeHeaderFromBuffer(&bytes));
}

test "decodeHeaderFromBuffer ignores unrecognized flag bits (forward compatibility)" {
    var bytes: [header_len]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], MAGIC, .little);
    bytes[4] = VERSION;
    bytes[5] = @intFromEnum(ObjectType.blob);
    bytes[6] = @intFromEnum(compression.Codec.none);
    bytes[7] = 0b1000_0001; // known bit 0 set + an unrecognized high bit
    std.mem.writeInt(u32, bytes[8..12], 0, .little);
    std.mem.writeInt(u32, bytes[12..16], 0, .little);

    // Must not error: an unrecognized flag bit is ignored, not treated
    // as corruption, so an object written by a hypothetical future
    // version (that only sets metadata flags, no new trailer bytes)
    // still decodes cleanly under this version.
    const header = try decodeHeaderFromBuffer(&bytes);
    try std.testing.expect(header.has_structural_hash);
}

test "decodeFromBuffer rejects a tampered trailer hash" {
    const alloc = std.testing.allocator;
    const encoded = try encodeAlloc(alloc, .blob, "tamper me", .none, null);
    defer alloc.free(encoded.bytes);

    encoded.bytes[encoded.bytes.len - 1] ^= 0xFF;

    try std.testing.expectError(error.HashMismatch, decodeFromBuffer(alloc, encoded.bytes));
}

test "decodeFromBuffer rejects a buffer shorter than the header claims" {
    const alloc = std.testing.allocator;
    const encoded = try encodeAlloc(alloc, .blob, "size mismatch", .none, null);
    defer alloc.free(encoded.bytes);

    const truncated = encoded.bytes[0 .. encoded.bytes.len - 4];
    try std.testing.expectError(error.CorruptObject, decodeFromBuffer(alloc, truncated));
}

test "decodeFromBuffer rejects an oversized buffer with trailing garbage" {
    const alloc = std.testing.allocator;
    const encoded = try encodeAlloc(alloc, .blob, "trailing garbage", .none, null);
    defer alloc.free(encoded.bytes);

    const padded = try alloc.alloc(u8, encoded.bytes.len + 8);
    defer alloc.free(padded);
    @memcpy(padded[0..encoded.bytes.len], encoded.bytes);
    @memset(padded[encoded.bytes.len..], 0xAA);

    try std.testing.expectError(error.CorruptObject, decodeFromBuffer(alloc, padded));
}

test "encodeAlloc/decodeFromBuffer round-trips a structural hash for ast objects" {
    const alloc = std.testing.allocator;
    const payload = "fn foo() void {}";
    const sh: Hash = [_]u8{0xAB} ** 32;

    const encoded = try encodeAlloc(alloc, .ast, payload, .none, sh);
    defer alloc.free(encoded.bytes);

    const obj = try decodeFromBuffer(alloc, encoded.bytes);
    defer alloc.free(obj.payload);

    try std.testing.expectEqualSlices(u8, &sh, &obj.structural_hash.?);
}

test "structural hash trailer does not affect the content hash" {
    const alloc = std.testing.allocator;
    const payload = "fn foo() void { return; }";

    const without_sh = try encodeAlloc(alloc, .ast, payload, .none, null);
    defer alloc.free(without_sh.bytes);

    const sh: Hash = [_]u8{0x42} ** 32;
    const with_sh = try encodeAlloc(alloc, .ast, payload, .none, sh);
    defer alloc.free(with_sh.bytes);

    try std.testing.expectEqualSlices(u8, &without_sh.hash, &with_sh.hash);
}

test "decodeHeaderFromBuffer reports has_structural_hash from the flags byte" {
    const alloc = std.testing.allocator;
    const sh: Hash = [_]u8{0x99} ** 32;

    const with_sh = try encodeAlloc(alloc, .ast, "x", .none, sh);
    defer alloc.free(with_sh.bytes);
    const header_with = try decodeHeaderFromBuffer(with_sh.bytes[0..header_len]);
    try std.testing.expect(header_with.has_structural_hash);

    const without_sh = try encodeAlloc(alloc, .ast, "x", .none, null);
    defer alloc.free(without_sh.bytes);
    const header_without = try decodeHeaderFromBuffer(without_sh.bytes[0..header_len]);
    try std.testing.expect(!header_without.has_structural_hash);
}

test "old-style objects with a zero flags byte decode with no structural hash" {
    const alloc = std.testing.allocator;
    const encoded = try encodeAlloc(alloc, .blob, "legacy object", .none, null);
    defer alloc.free(encoded.bytes);

    try std.testing.expectEqual(@as(u8, 0), encoded.bytes[7]);

    const obj = try decodeFromBuffer(alloc, encoded.bytes);
    defer alloc.free(obj.payload);
    try std.testing.expect(obj.structural_hash == null);
}

test "structuralHashOffset points at the correct trailer position" {
    const alloc = std.testing.allocator;
    const payload = "offset check";
    const sh: Hash = [_]u8{0x7E} ** 32;

    const encoded = try encodeAlloc(alloc, .ast, payload, .none, sh);
    defer alloc.free(encoded.bytes);

    const header = try decodeHeaderFromBuffer(encoded.bytes[0..header_len]);
    const offset = structuralHashOffset(header);

    try std.testing.expectEqual(encoded.bytes.len, offset + structural_hash_len);
    try std.testing.expectEqualSlices(u8, &sh, encoded.bytes[offset..][0..structural_hash_len]);
}
