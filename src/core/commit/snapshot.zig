const std = @import("std");
const wire = @import("wire.zig");
const MockReader = @import("testing.zig").MockReader;
const Hash = [32]u8;

pub const SnapshotError = error{TooManyParents};
pub const MAX_PARENTS: u8 = 255;

pub const SnapshotInfo = struct {
    tree: Hash,
    parents: []const Hash,

    pub fn validate(self: SnapshotInfo) SnapshotError!void {
        if (self.parents.len > MAX_PARENTS) return error.TooManyParents;
    }

    pub fn serialize(self: SnapshotInfo, writer: anytype) !void {
        try self.validate();
        try writer.writeAll(&self.tree);
        try wire.writeCount(u8, writer, self.parents.len);
        for (self.parents) |parent| try writer.writeAll(&parent);
    }
};

pub const Snapshot = struct {
    tree: Hash,
    parents: []Hash,

    pub fn initDupe(alloc: std.mem.Allocator, info: SnapshotInfo) !Snapshot {
        try info.validate();
        const parents = try alloc.dupe(Hash, info.parents);
        return .{ .tree = info.tree, .parents = parents };
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Snapshot {
        const tree_bytes = try reader.take(32);
        var tree: Hash = undefined;
        @memcpy(&tree, tree_bytes);

        const parents_len = try wire.readCount(u8, reader);
        const parents = try alloc.alloc(Hash, parents_len);
        errdefer alloc.free(parents);
        for (parents) |*parent| @memcpy(parent, try reader.take(32));

        try (SnapshotInfo{ .tree = tree, .parents = parents }).validate();
        return .{ .tree = tree, .parents = parents };
    }

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.parents);
        self.* = undefined;
    }
};

test "SnapshotInfo validation bounds" {
    const dummy_hash: Hash = [_]u8{0} ** 32;

    // Zero parent array layout (Initial standard commit root)
    const initial_commit = SnapshotInfo{
        .tree = dummy_hash,
        .parents = &.{},
    };
    try initial_commit.validate();

    // Multiple ancestry elements layout (Merge commit scenario)
    const dual_parents = [_]Hash{ dummy_hash, dummy_hash };
    const merge_commit = SnapshotInfo{
        .tree = dummy_hash,
        .parents = &dual_parents,
    };
    try merge_commit.validate();

    // Error-trigger boundary state validation (> 255 parents restriction)
    const massive_parents = try std.testing.allocator.alloc(Hash, 256);
    defer std.testing.allocator.free(massive_parents);
    @memset(massive_parents, dummy_hash);

    const invalid_commit = SnapshotInfo{
        .tree = dummy_hash,
        .parents = massive_parents,
    };
    try std.testing.expectError(error.TooManyParents, invalid_commit.validate());
}

test "SnapshotInfo serialization layout integrity" {
    const tree_hash: Hash = [_]u8{1} ** 32;
    const parent_hash: Hash = [_]u8{2} ** 32;
    const parents = [_]Hash{parent_hash};

    const info = SnapshotInfo{
        .tree = tree_hash,
        .parents = &parents,
    };
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try info.serialize(buf.writer(alloc));

    // Expected verification footprint layout sizes:
    // [32 Bytes: Tree Hash] + [1 Byte: Parent Count Length] + [32 Bytes: Single Parent Hash] = 65 Bytes
    try std.testing.expectEqual(@as(usize, 32 + 1 + 32), buf.items.len);
    try std.testing.expectEqualSlices(u8, &tree_hash, buf.items[0..32]);
    try std.testing.expectEqual(@as(u8, 1), buf.items[32]);
    try std.testing.expectEqualSlices(u8, &parent_hash, buf.items[33..65]);
}

test "Snapshot lifecycle and duplication deep-copies" {
    const allocator = std.testing.allocator;
    const tree_hash: Hash = [_]u8{3} ** 32;
    const p1: Hash = [_]u8{4} ** 32;
    const p2: Hash = [_]u8{5} ** 32;
    const parents = [_]Hash{ p1, p2 };

    const info = SnapshotInfo{
        .tree = tree_hash,
        .parents = &parents,
    };

    var snapshot = try Snapshot.initDupe(allocator, info);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &tree_hash, &snapshot.tree);
    try std.testing.expectEqual(@as(usize, 2), snapshot.parents.len);
    try std.testing.expectEqualSlices(u8, &p1, &snapshot.parents[0]);
    try std.testing.expectEqualSlices(u8, &p2, &snapshot.parents[1]);
}

test "Snapshot deserialization from mock input buffer stream" {
    const allocator = std.testing.allocator;

    const tree_hash: Hash = [_]u8{6} ** 32;
    const parent_hash: Hash = [_]u8{7} ** 32;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.appendSlice(allocator, &tree_hash);
    try payload.append(allocator, 1);
    try payload.appendSlice(allocator, &parent_hash);

    var mock_reader = MockReader{ .buffer = payload.items };

    var snapshot = try Snapshot.deserialize(allocator, &mock_reader);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &tree_hash, &snapshot.tree);
    try std.testing.expectEqual(@as(usize, 1), snapshot.parents.len);
    try std.testing.expectEqualSlices(u8, &parent_hash, &snapshot.parents[0]);
}

test "SnapshotInfo validation exactly at max bound" {
    const dummy_hash: Hash = [_]u8{0} ** 32;

    // Boundary edge: exactly 255 parents should succeed
    const max_parents = try std.testing.allocator.alloc(Hash, MAX_PARENTS);
    defer std.testing.allocator.free(max_parents);
    @memset(max_parents, dummy_hash);

    const boundary_info = SnapshotInfo{
        .tree = dummy_hash,
        .parents = max_parents,
    };
    try boundary_info.validate();
}

test "SnapshotInfo serialization failure on invalid size" {
    const dummy_hash: Hash = [_]u8{0} ** 32;
    const alloc = std.testing.allocator;

    const broken_parents = try alloc.alloc(Hash, 256);
    defer alloc.free(broken_parents);
    @memset(broken_parents, dummy_hash);

    const invalid_info = SnapshotInfo{
        .tree = dummy_hash,
        .parents = broken_parents,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // Ensure serialization blocks execution and forwards the precise validation error
    try std.testing.expectError(error.TooManyParents, invalid_info.serialize(buf.writer(alloc)));
}

test "Snapshot deserialization error on unexpected EOF/Truncation" {
    const allocator = std.testing.allocator;
    const tree_hash: Hash = [_]u8{0xAA} ** 32;

    var truncated_payload: std.ArrayList(u8) = .empty;
    defer truncated_payload.deinit(allocator);

    var mock_reader = MockReader{ .buffer = truncated_payload.items };
    try std.testing.expectError(error.EndOfStream, Snapshot.deserialize(allocator, &mock_reader));

    try truncated_payload.appendSlice(allocator, tree_hash[0..16]);
    mock_reader = MockReader{ .buffer = truncated_payload.items };
    try std.testing.expectError(error.EndOfStream, Snapshot.deserialize(allocator, &mock_reader));

    truncated_payload.clearRetainingCapacity();
    try truncated_payload.appendSlice(allocator, &tree_hash);
    try truncated_payload.append(allocator, 2); // Claims 2 parents follow, but we supply none
    mock_reader = MockReader{ .buffer = truncated_payload.items };
    try std.testing.expectError(error.EndOfStream, Snapshot.deserialize(allocator, &mock_reader));
}

test "Snapshot deserialization validation of upstream constraints" {
    const allocator = std.testing.allocator;
    const dummy_hash: Hash = [_]u8{0} ** 32;

    var invalid_wire_payload: std.ArrayList(u8) = .empty;
    defer invalid_wire_payload.deinit(allocator);

    try invalid_wire_payload.appendSlice(allocator, &dummy_hash);

    try invalid_wire_payload.append(allocator, 255);
    for (0..255) |_| {
        try invalid_wire_payload.appendSlice(allocator, &dummy_hash);
    }

    var mock_reader = MockReader{ .buffer = invalid_wire_payload.items };
    var snapshot = try Snapshot.deserialize(allocator, &mock_reader);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 255), snapshot.parents.len);
}

test "Snapshot initialization errors do not leak memory" {
    const dummy_hash: Hash = [_]u8{0} ** 32;
    const alloc = std.testing.allocator;

    const invalid_parents = try alloc.alloc(Hash, 256);
    defer alloc.free(invalid_parents);
    @memset(invalid_parents, dummy_hash);

    const bad_info = SnapshotInfo{
        .tree = dummy_hash,
        .parents = invalid_parents,
    };

    // initDupe should bail early with TooManyParents error before allocating internal slice copies
    try std.testing.expectError(error.TooManyParents, Snapshot.initDupe(alloc, bad_info));
}
