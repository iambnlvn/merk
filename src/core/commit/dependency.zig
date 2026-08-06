const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const wire = @import("wire.zig");
const MockReader = @import("testing.zig").MockReader;
const metadata = @import("./metadata.zig");

const ChangeId = metadata.ChangeId;

/// Cap on how many logical dependencies a single commit can declare.
pub const MAX_DEPENDENCIES: u8 = 255;

/// Relational classification for a dependency edge.
pub const DependencyKind = enum(u8) {
    /// Standard dependency: this change requires the target change to be applied first.
    requires = 0,
    /// Mutual exclusion: this change cannot be combined or applied alongside the target change.
    conflicts = 1,
    /// Replacement: this change renders the target change obsolete or superseded.
    obsoletes = 2,
};

/// A logical relationship edge between two evolving changes.
///
/// Unlike `ParentInfo` which records physical ancestry (a fixed commit hash),
/// `DependencyInfo` records relationships between evolving logical changes keyed
/// by `ChangeId`. The same `ChangeId` survives amnesic rewrites (amend, rebase,
/// cherry-pick), ensuring relationships persist across commit transformations.
///
/// - 1 byte: `DependencyKind` enum tag (`u8`)
/// - 16 bytes: Raw `ChangeId` byte array
pub const DependencyInfo = struct {
    change_id: ChangeId,
    kind: DependencyKind = .requires,

    pub fn init(change_id: ChangeId, kind: DependencyKind) DependencyInfo {
        return .{
            .change_id = change_id,
            .kind = kind,
        };
    }

    pub fn eql(self: DependencyInfo, other: DependencyInfo) bool {
        return self.kind == other.kind and std.mem.eql(u8, &self.change_id, &other.change_id);
    }

    pub fn serialize(self: DependencyInfo, writer: anytype) !void {
        try writer.writeByte(@intFromEnum(self.kind));
        try writer.writeAll(&self.change_id);
    }

    pub fn deserialize(reader: anytype) !DependencyInfo {
        const raw_kind = try reader.takeByte();
        const kind = std.meta.intToEnum(DependencyKind, raw_kind) catch return error.CorruptCommit;

        const bytes = try reader.take(16);
        var change_id: ChangeId = undefined;
        @memcpy(&change_id, bytes);

        return .{
            .change_id = change_id,
            .kind = kind,
        };
    }
};

pub const DependencyError = error{
    TooManyDependencies,
    /// The same `change_id` appears twice in one commit's dependency list.
    DuplicateDependency,
    /// A commit cannot declare a dependency relationship on its own `change_id`.
    SelfDependency,
    /// Invalid binary payload encountered during deserialization.
    CorruptCommit,
};

pub fn validate(deps: []const DependencyInfo, self_id: ?ChangeId) DependencyError!void {
    if (deps.len > MAX_DEPENDENCIES) return error.TooManyDependencies;

    for (deps, 0..) |d, i| {
        if (self_id) |self| {
            if (std.mem.eql(u8, &d.change_id, &self)) return error.SelfDependency;
        }

        for (deps[i + 1 ..]) |other| {
            if (std.mem.eql(u8, &d.change_id, &other.change_id)) return error.DuplicateDependency;
        }
    }
}

/// Validates and writes all dependency entries to the binary stream.
pub fn serializeAll(deps: []const DependencyInfo, self_id: ?ChangeId, writer: anytype) !void {
    try validate(deps, self_id);
    try wire.writeList(DependencyInfo, u8, writer, deps);
}

/// Deserializes a list of `DependencyInfo` from the binary stream.
/// Caller frees the returned slice with `alloc.free`. No per-element frees are needed.
pub fn deserializeAllAlloc(alloc: Allocator, reader: anytype) ![]DependencyInfo {
    return wire.readListAlloc(DependencyInfo, u8, alloc, reader);
}

test "validate accepts valid list and handles MAX_DEPENDENCIES boundary" {
    const alloc = testing.allocator;

    const too_many = try alloc.alloc(DependencyInfo, 256);
    defer alloc.free(too_many);
    @memset(too_many, DependencyInfo.init([_]u8{0} ** 16, .requires));
    try testing.expectError(error.TooManyDependencies, validate(too_many, null));

    const max = try alloc.alloc(DependencyInfo, MAX_DEPENDENCIES);
    defer alloc.free(max);
    for (max, 0..) |*d, i| {
        d.* = DependencyInfo.init([_]u8{@intCast(i % 256)} ** 16, .requires);
    }
    try validate(max, null);
}

test "validate rejects duplicate change_id regardless of kind" {
    const cid: ChangeId = [_]u8{0x11} ** 16;
    const deps = [_]DependencyInfo{
        .init(cid, .requires),
        .init(cid, .conflicts),
    };
    try testing.expectError(error.DuplicateDependency, validate(&deps, null));
}

test "validate rejects self dependency" {
    const self_id: ChangeId = [_]u8{0xAA} ** 16;
    const other_id: ChangeId = [_]u8{0xBB} ** 16;

    const deps = [_]DependencyInfo{
        .init(other_id, .requires),
        .init(self_id, .obsoletes),
    };

    try testing.expectError(error.SelfDependency, validate(&deps, self_id));
    try validate(&deps, null);
}

test "DependencyInfo serialize/deserialize preserves kind and change_id" {
    const alloc = testing.allocator;
    const cid: ChangeId = [_]u8{0x5A} ** 16;
    const info = DependencyInfo.init(cid, .conflicts);

    var buf: ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    // kind (1 byte) + change_id (16 bytes) = 17 bytes
    try testing.expectEqual(@as(usize, 17), buf.items.len);
    try testing.expectEqual(@as(u8, @intFromEnum(DependencyKind.conflicts)), buf.items[0]);

    var mock_reader = MockReader{ .buffer = buf.items };
    const decoded = try DependencyInfo.deserialize(&mock_reader);
    try testing.expect(info.eql(decoded));
}

test "DependencyInfo deserialize rejects invalid kind enum tag" {
    const corrupt_data = "\xFF" ** 17; // 0xFF is an invalid DependencyKind enum tag
    var mock_reader = MockReader{ .buffer = corrupt_data };

    try testing.expectError(error.CorruptCommit, DependencyInfo.deserialize(&mock_reader));
}

test "serializeAll/deserializeAllAlloc round-trip multiple dependency kinds" {
    const alloc = testing.allocator;

    const deps = [_]DependencyInfo{
        .init([_]u8{0xAA} ** 16, .requires),
        .init([_]u8{0xBB} ** 16, .conflicts),
        .init([_]u8{0xCC} ** 16, .obsoletes),
    };

    var buf: ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serializeAll(&deps, null, buf.writer(alloc));

    // count(1 byte) + 3 * (kind(1 byte) + change_id(16 bytes)) = 1 + 3 * 17 = 52
    try testing.expectEqual(@as(usize, 1 + 3 * 17), buf.items.len);
    try testing.expectEqual(@as(u8, 3), buf.items[0]);

    var mock_reader = MockReader{ .buffer = buf.items };
    const back = try deserializeAllAlloc(alloc, &mock_reader);
    defer alloc.free(back);

    try testing.expectEqual(@as(usize, 3), back.len);
    for (deps, back) |expected, actual| {
        try testing.expect(expected.eql(actual));
    }
}

test "serializeAll/deserializeAllAlloc round-trip zero dependencies" {
    const alloc = testing.allocator;

    var buf: ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serializeAll(&.{}, null, buf.writer(alloc));

    try testing.expectEqual(@as(usize, 1), buf.items.len);
    try testing.expectEqual(@as(u8, 0), buf.items[0]);

    var mock_reader = MockReader{ .buffer = buf.items };
    const back = try deserializeAllAlloc(alloc, &mock_reader);
    defer alloc.free(back);

    try testing.expectEqual(@as(usize, 0), back.len);
}

test "serializeAll rejects a duplicate before writing anything" {
    const alloc = testing.allocator;
    const cid: ChangeId = [_]u8{0x42} ** 16;
    const deps = [_]DependencyInfo{
        .init(cid, .requires),
        .init(cid, .requires),
    };

    var buf: ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try testing.expectError(error.DuplicateDependency, serializeAll(&deps, null, buf.writer(alloc)));
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "DependencyInfo.eql checks both kind and change_id" {
    const cid: ChangeId = [_]u8{0x07} ** 16;
    const a = DependencyInfo.init(cid, .requires);
    const b = DependencyInfo.init(cid, .requires);
    const c = DependencyInfo.init(cid, .conflicts);

    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}
