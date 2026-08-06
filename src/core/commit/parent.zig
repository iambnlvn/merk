const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const crypto = @import("crypto");
const wire = @import("wire.zig");
const testing_io = @import("testing.zig");

const Hash = crypto.Hash;

pub const ParentError = error{TooManyParents};
pub const MAX_PARENTS: u8 = 255;

/// Why this parent edge exists. `.normal` is the ordinary
/// single-parent case and is the default — most commits never need to
/// think about this at all.
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

    pub fn serialize(self: ParentInfo, writer: *Io.Writer) !void {
        try writer.writeAll(&self.hash);
        try writer.writeByte(@intFromEnum(self.kind));
    }

    pub fn deserialize(reader: *Io.Reader) !ParentInfo {
        var hash: Hash = undefined;
        try reader.readSliceAll(&hash);

        const raw_kind = try reader.takeByte();
        const kind = std.meta.intToEnum(ParentKind, raw_kind) catch return error.CorruptCommit;

        return .{ .hash = hash, .kind = kind };
    }
};

pub fn validate(parents: []const ParentInfo) ParentError!void {
    if (parents.len > MAX_PARENTS) return error.TooManyParents;
}

pub fn serializeAll(parents: []const ParentInfo, writer: *Io.Writer) !void {
    try validate(parents);
    try wire.writeList(ParentInfo, u8, writer, parents);
}

/// Deserialize into a freshly allocated, owned slice. Caller frees with
/// `alloc.free`. `ParentInfo` is a fixed-size record with no owned
/// sub-allocations, so `wire.readListAlloc` (rather than the
/// allocator-aware `readOwningListAlloc`) is the right fit.
pub fn deserializeAllAlloc(alloc: Allocator, reader: *Io.Reader) ![]ParentInfo {
    return wire.readListAlloc(ParentInfo, u8, alloc, reader);
}

test "ParentInfo defaults to .normal when not specified" {
    const hash: Hash = [_]u8{0x01} ** 32;
    const info = ParentInfo{ .hash = hash };
    try testing.expectEqual(ParentKind.normal, info.kind);
}

test "ParentInfo serialize/deserialize round-trip preserves kind" {
    const hash: Hash = [_]u8{0xAB} ** 32;
    const info = ParentInfo{ .hash = hash, .kind = .merge };

    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();
    try info.serialize(sink.writer());

    // 32 bytes hash + 1 byte kind
    try testing.expectEqual(@as(usize, 33), sink.bytes().len);

    var reader = testing_io.fixedReader(sink.bytes());
    const decoded = try ParentInfo.deserialize(&reader);

    try testing.expectEqualSlices(u8, &hash, &decoded.hash);
    try testing.expectEqual(ParentKind.merge, decoded.kind);
}

test "deserialize rejects an out-of-range kind byte" {
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    try sink.writer().writeAll(&([_]u8{0xFF} ** 32));
    try sink.writer().writeByte(99); // not a valid ParentKind

    var reader = testing_io.fixedReader(sink.bytes());
    try testing.expectError(error.CorruptCommit, ParentInfo.deserialize(&reader));
}

test "validate rejects more than MAX_PARENTS, accepts exactly MAX_PARENTS" {
    const alloc = testing.allocator;

    const too_many = try alloc.alloc(ParentInfo, 256);
    defer alloc.free(too_many);
    @memset(too_many, ParentInfo{ .hash = [_]u8{0} ** 32 });
    try testing.expectError(error.TooManyParents, validate(too_many));

    const max = try alloc.alloc(ParentInfo, MAX_PARENTS);
    defer alloc.free(max);
    @memset(max, ParentInfo{ .hash = [_]u8{0} ** 32 });
    try validate(max);
}

test "serializeAll/deserializeAllAlloc round-trip with mixed kinds, in order" {
    const alloc = testing.allocator;
    const parents = [_]ParentInfo{
        .{ .hash = [_]u8{1} ** 32, .kind = .normal },
        .{ .hash = [_]u8{2} ** 32, .kind = .merge },
        .{ .hash = [_]u8{3} ** 32, .kind = .cherry_pick },
    };

    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();
    try serializeAll(&parents, sink.writer());

    var reader = testing_io.fixedReader(sink.bytes());
    const decoded = try deserializeAllAlloc(alloc, &reader);
    defer alloc.free(decoded);

    try testing.expectEqual(@as(usize, 3), decoded.len);
    try testing.expectEqual(ParentKind.normal, decoded[0].kind);
    try testing.expectEqual(ParentKind.merge, decoded[1].kind);
    try testing.expectEqual(ParentKind.cherry_pick, decoded[2].kind);
    try testing.expectEqualSlices(u8, &parents[1].hash, &decoded[1].hash);
}

test "serializeAll rejects TooManyParents before writing anything" {
    const alloc = testing.allocator;
    const too_many = try alloc.alloc(ParentInfo, 256);
    defer alloc.free(too_many);
    @memset(too_many, ParentInfo{ .hash = [_]u8{0} ** 32 });

    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();
    try testing.expectError(error.TooManyParents, serializeAll(too_many, sink.writer()));
}
