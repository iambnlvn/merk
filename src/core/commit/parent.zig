const std = @import("std");
const wire = @import("wire.zig");

const Hash = [32]u8;

pub const ParentError = error{TooManyParents};
pub const MAX_PARENTS: u8 = 255;

/// Why this parent edge exists. `.normal` is the ordinary
/// single-parent case and is the default — most commits never need to
/// think about this at all
pub const ParentKind = enum(u8) {
    normal = 0,
    merge = 1,
    cherry_pick = 2,
    rebase = 3,
    revert = 4,
};

pub const ParentInfo = struct {
    hash: Hash,
    kind: ParentKind = .normal,

    pub fn serialize(self: ParentInfo, writer: anytype) !void {
        try writer.writeAll(&self.hash);
        try writer.writeByte(@intFromEnum(self.kind));
    }

    pub fn deserialize(reader: anytype) !ParentInfo {
        const hash_bytes = try reader.take(32);
        var hash: Hash = undefined;
        @memcpy(&hash, hash_bytes);

        const kind = std.meta.intToEnum(ParentKind, try reader.takeByte()) catch return error.CorruptCommit;

        return .{ .hash = hash, .kind = kind };
    }
};

pub fn validate(parents: []const ParentInfo) ParentError!void {
    if (parents.len > MAX_PARENTS) return error.TooManyParents;
}

pub fn serializeAll(parents: []const ParentInfo, writer: anytype) !void {
    try validate(parents);
    try wire.writeCount(u8, writer, parents.len);
    for (parents) |p| try p.serialize(writer);
}

/// Deserialize into a freshly allocated, owned slice. Caller frees with
/// `alloc.free`.
pub fn deserializeAllAlloc(alloc: std.mem.Allocator, reader: anytype) ![]ParentInfo {
    const len = try wire.readCount(u8, reader);
    const parents = try alloc.alloc(ParentInfo, len);
    errdefer alloc.free(parents);

    for (parents) |*p| p.* = try ParentInfo.deserialize(reader);

    return parents;
}

test "ParentInfo defaults to .normal when not specified" {
    const hash: Hash = [_]u8{0x01} ** 32;
    const info = ParentInfo{ .hash = hash };
    try std.testing.expectEqual(ParentKind.normal, info.kind);
}

test "ParentInfo serialize/deserialize round-trip preserves kind" {
    const hash: Hash = [_]u8{0xAB} ** 32;
    const info = ParentInfo{ .hash = hash, .kind = .merge };

    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    // 32 bytes hash + 1 byte kind
    try std.testing.expectEqual(@as(usize, 33), buf.items.len);

    const MockReader = @import("testing.zig").MockReader;
    var mock_reader = MockReader{ .buffer = buf.items };
    const decoded = try ParentInfo.deserialize(&mock_reader);

    try std.testing.expectEqualSlices(u8, &hash, &decoded.hash);
    try std.testing.expectEqual(ParentKind.merge, decoded.kind);
}

test "deserialize rejects an out-of-range kind byte" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, &([_]u8{0xFF} ** 32));
    try buf.append(alloc, 99); // not a valid ParentKind

    const MockReader = @import("testing.zig").MockReader;
    var mock_reader = MockReader{ .buffer = buf.items };
    try std.testing.expectError(error.CorruptCommit, ParentInfo.deserialize(&mock_reader));
}

test "validate rejects more than MAX_PARENTS, accepts exactly MAX_PARENTS" {
    const alloc = std.testing.allocator;

    const too_many = try alloc.alloc(ParentInfo, 256);
    defer alloc.free(too_many);
    @memset(too_many, ParentInfo{ .hash = [_]u8{0} ** 32 });
    try std.testing.expectError(error.TooManyParents, validate(too_many));

    const max = try alloc.alloc(ParentInfo, MAX_PARENTS);
    defer alloc.free(max);
    @memset(max, ParentInfo{ .hash = [_]u8{0} ** 32 });
    try validate(max);
}

test "serializeAll/deserializeAllAlloc round-trip with mixed kinds, in order" {
    const alloc = std.testing.allocator;
    const parents = [_]ParentInfo{
        .{ .hash = [_]u8{1} ** 32, .kind = .normal },
        .{ .hash = [_]u8{2} ** 32, .kind = .merge },
        .{ .hash = [_]u8{3} ** 32, .kind = .cherry_pick },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serializeAll(&parents, buf.writer(alloc));

    const MockReader = @import("testing.zig").MockReader;
    var mock_reader = MockReader{ .buffer = buf.items };
    const decoded = try deserializeAllAlloc(alloc, &mock_reader);
    defer alloc.free(decoded);

    try std.testing.expectEqual(@as(usize, 3), decoded.len);
    try std.testing.expectEqual(ParentKind.normal, decoded[0].kind);
    try std.testing.expectEqual(ParentKind.merge, decoded[1].kind);
    try std.testing.expectEqual(ParentKind.cherry_pick, decoded[2].kind);
    try std.testing.expectEqualSlices(u8, &parents[1].hash, &decoded[1].hash);
}

test "serializeAll rejects TooManyParents before writing anything" {
    const alloc = std.testing.allocator;
    const too_many = try alloc.alloc(ParentInfo, 256);
    defer alloc.free(too_many);
    @memset(too_many, ParentInfo{ .hash = [_]u8{0} ** 32 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.testing.expectError(error.TooManyParents, serializeAll(too_many, buf.writer(alloc)));
}
