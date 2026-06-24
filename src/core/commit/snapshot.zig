const std = @import("std");
const builtin = @import("builtin");
const Hash = [32]u8;
//I dont know if this is possible in zig, Looking it up later...
// const Hash = if (builtin.is_test) [32]u8 else @import("../hash.zig").Hash;
const MockReader = @import("testing.zig").MockReader;
pub const SnapshotError = error{
    TooManyParents,
};

pub const SnapshotInfo = struct {
    /// Root tree object describing repository state.
    tree: Hash,

    /// Parent commit hashes.
    ///
    /// Empty slice indicates an initial commit.
    /// Additional parents represent merge ancestry.
    parents: []const Hash,

    pub fn validate(self: SnapshotInfo) SnapshotError!void {
        if (self.parents.len > 255)
            return error.TooManyParents;
    }

    pub fn serialize(self: SnapshotInfo, writer: anytype) !void {
        try self.validate();

        // Write the 32-byte root tree hash
        try writer.writeAll(&self.tree);

        // Write the parent count as a single byte
        try writer.writeByte(@intCast(self.parents.len));

        // Write each 32-byte parent hash consecutively
        for (self.parents) |parent| {
            try writer.writeAll(&parent);
        }
    }
};

pub const Snapshot = struct {
    /// Root tree object describing repository state.
    tree: Hash,

    /// Owned parent commit hashes.
    parents: []Hash,

    pub fn initDupe(alloc: std.mem.Allocator, info: SnapshotInfo) !Snapshot {
        try info.validate();

        const parents = try alloc.dupe(Hash, info.parents);
        errdefer alloc.free(parents);

        return .{
            .tree = info.tree,
            .parents = parents,
        };
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Snapshot {
        // Recover the 32-byte tree hash from the stream
        const tree_bytes = try reader.take(32);
        var tree: Hash = undefined;
        @memcpy(&tree, tree_bytes);

        // Fetch parent size prefix (1 byte)
        const parents_len = try reader.takeInt(u8, .little);

        // Allocate block for array entries
        const parents = try alloc.alloc(Hash, parents_len);
        errdefer alloc.free(parents);

        // Populate parent entries out of the reader stream
        for (parents) |*parent| {
            const parent_bytes = try reader.take(32);
            @memcpy(parent, parent_bytes);
        }

        const info = SnapshotInfo{
            .tree = tree,
            .parents = parents,
        };
        try info.validate();

        return .{
            .tree = tree,
            .parents = parents,
        };
    }

    pub fn deinit(
        self: *Snapshot,
        alloc: std.mem.Allocator,
    ) void {
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
