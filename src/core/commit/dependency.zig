const std = @import("std");
const wire = @import("wire.zig");
const MockReader = @import("testing.zig").MockReader;

const metadata = @import("./metadata.zig");
const ChangeId = metadata.ChangeId;

/// Cap on how many logical dependencies a single commit can declare.
pub const MAX_DEPENDENCIES: u8 = 255;

/// A logical "this change needs that change" edge, for stacked commits.
///
/// This is deliberately *not* `ParentInfo`. `ParentInfo` records physical
/// ancestry — a `Hash`, fixed the moment this commit is written. A
/// dependency records a relationship between two evolving *logical*
/// changes, so it's keyed by `ChangeId` instead: the same `ChangeId`
/// survives every amend, rebase, or cherry-pick of the depended-upon
/// commit, so declaring `.dependsOn(change_id)` once never needs to be
/// rewritten just because that other commit's hash moved.
///
pub const DependencyInfo = struct {
    change_id: ChangeId,

    pub fn init(change_id: ChangeId) DependencyInfo {
        return .{ .change_id = change_id };
    }

    pub fn eql(self: DependencyInfo, other: DependencyInfo) bool {
        return std.mem.eql(u8, &self.change_id, &other.change_id);
    }
};

pub const DependencyError = error{
    TooManyDependencies,
    /// The same `change_id` appears twice in one commit's dependency
    /// list. Not inherently dangerous, but always a mistake — declaring
    /// a dependency twice can't mean anything a single declaration
    /// doesn't already mean.
    DuplicateDependency,
};

/// Validate a full dependency list: bounds-check the count and reject
/// duplicate entries. Does *not* check for a self-dependency (a commit
/// depending on its own `change_id`) — that check needs the owning
/// commit's `metadata.change_id`, which this function doesn't have
/// access to; see `CommitInfo.validate` in `commit.zig`, which checks
/// it once both pieces are in hand.
pub fn validate(deps: []const DependencyInfo) DependencyError!void {
    if (deps.len > MAX_DEPENDENCIES) return error.TooManyDependencies;

    for (deps, 0..) |d, i| {
        for (deps[i + 1 ..]) |other| {
            if (d.eql(other)) return error.DuplicateDependency;
        }
    }
}

pub fn serializeAll(deps: []const DependencyInfo, writer: anytype) !void {
    try validate(deps);

    try wire.writeCount(u8, writer, deps.len);
    for (deps) |d| {
        try writer.writeAll(&d.change_id);
    }
}

/// Caller frees the result with `alloc.free`. No per-element frees are
/// needed — `DependencyInfo` is a fixed-size value with no owned
/// sub-allocations, unlike e.g. `Person` or a `[][]u8` label list.
pub fn deserializeAllAlloc(alloc: std.mem.Allocator, reader: anytype) ![]DependencyInfo {
    const len = try wire.readCount(u8, reader);

    const deps = try alloc.alloc(DependencyInfo, len);
    errdefer alloc.free(deps);

    for (deps) |*d| {
        const bytes = try reader.take(16);
        var change_id: ChangeId = undefined;
        @memcpy(&change_id, bytes);
        d.* = .{ .change_id = change_id };
    }

    return deps;
}

test "validate rejects more than MAX_DEPENDENCIES, accepts exactly MAX_DEPENDENCIES" {
    const alloc = std.testing.allocator;

    // Same length check fires regardless of content, so a repeated
    // change_id is fine here — unlike the "accepts exactly the cap"
    // case below, which needs distinct ids or the duplicate check
    // would fire first.
    const too_many = try alloc.alloc(DependencyInfo, 256);
    defer alloc.free(too_many);
    @memset(too_many, DependencyInfo{ .change_id = [_]u8{0} ** 16 });
    try std.testing.expectError(error.TooManyDependencies, validate(too_many));

    const max = try alloc.alloc(DependencyInfo, MAX_DEPENDENCIES);
    defer alloc.free(max);
    for (max, 0..) |*d, i| d.* = DependencyInfo{ .change_id = [_]u8{@intCast(i % 256)} ** 16 };
    try validate(max);
}

test "validate rejects a duplicate change_id" {
    const cid: ChangeId = [_]u8{0x11} ** 16;
    const deps = [_]DependencyInfo{ .init(cid), .init(cid) };
    try std.testing.expectError(error.DuplicateDependency, validate(&deps));
}

test "serializeAll/deserializeAllAlloc round-trip several dependencies" {
    const alloc = std.testing.allocator;

    const deps = [_]DependencyInfo{
        .init([_]u8{0xAA} ** 16),
        .init([_]u8{0xBB} ** 16),
        .init([_]u8{0xCC} ** 16),
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serializeAll(&deps, buf.writer(alloc));

    // count(1) + 3 * change_id(16)
    try std.testing.expectEqual(@as(usize, 1 + 3 * 16), buf.items.len);
    try std.testing.expectEqual(@as(u8, 3), buf.items[0]);

    var mock_reader = MockReader{ .buffer = buf.items };
    const back = try deserializeAllAlloc(alloc, &mock_reader);
    defer alloc.free(back);

    try std.testing.expectEqual(@as(usize, 3), back.len);
    for (deps, back) |expected, actual| {
        try std.testing.expect(expected.eql(actual));
    }
}

test "serializeAll/deserializeAllAlloc round-trip zero dependencies" {
    const alloc = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serializeAll(&.{}, buf.writer(alloc));

    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    try std.testing.expectEqual(@as(u8, 0), buf.items[0]);

    var mock_reader = MockReader{ .buffer = buf.items };
    const back = try deserializeAllAlloc(alloc, &mock_reader);
    defer alloc.free(back);

    try std.testing.expectEqual(@as(usize, 0), back.len);
}

test "serializeAll rejects a duplicate before writing anything" {
    const alloc = std.testing.allocator;
    const cid: ChangeId = [_]u8{0x42} ** 16;
    const deps = [_]DependencyInfo{ .init(cid), .init(cid) };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.testing.expectError(error.DuplicateDependency, serializeAll(&deps, buf.writer(alloc)));
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "DependencyInfo.eql compares change_id only" {
    const cid: ChangeId = [_]u8{0x7} ** 16;
    const a = DependencyInfo.init(cid);
    const b = DependencyInfo.init(cid);
    const c = DependencyInfo.init([_]u8{0x8} ** 16);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}
