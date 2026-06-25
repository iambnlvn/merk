const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const tree = @import("tree.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

const identity = @import("./commit/identity.zig");
const CommitIdentityInfo = identity.CommitIdentityInfo;
const CommitIdentity = identity.CommitIdentity;
const TimestampedIdentityInfo = identity.TimestampedIdentityInfo;

const message = @import("./commit/message.zig");
const Message = message.Message;
const MessageInfo = message.MessageInfo;

const snapshot = @import("./commit/snapshot.zig");
const Snapshot = snapshot.Snapshot;
const SnapshotInfo = snapshot.SnapshotInfo;

pub const commitMetadata = @import("./commit/metadata.zig");
const CommitMetadata = commitMetadata.CommitMetadata;
const CommitMetadataInfo = commitMetadata.CommitMetadataInfo;

const refs = @import("./refs.zig");

pub const COMMIT_MAGIC = 0x4E_4F_44_55;
pub const COMMIT_VERSION: u8 = 1;
pub const MAX_PARENTS: u8 = 255;

pub const CommitInfo = struct {
    snapshot: SnapshotInfo,

    /// Author + optional committer.  When committer is null it defaults to
    /// the author (same person, same timestamp) at serialisation time.
    identity: CommitIdentityInfo,

    metadata: CommitMetadataInfo = .{},
    message: MessageInfo,

    pub fn validate(self: @This()) !void {
        try self.snapshot.validate();
        try self.identity.validate();
        try self.metadata.validate();
        try self.message.validate();
    }
};

pub const Commit = struct {
    hash: Hash,
    snapshot: Snapshot,
    identity: CommitIdentity,
    metadata: CommitMetadata,
    message: Message,

    pub fn deinit(self: *Commit, alloc: std.mem.Allocator) void {
        self.snapshot.deinit(alloc);
        self.identity.deinit(alloc);
        self.metadata.deinit(alloc);
        self.message.deinit(alloc);

        self.* = undefined;
    }
};

pub fn write(
    alloc: std.mem.Allocator,
    store: *const Store,
    info: CommitInfo,
) !Hash {
    try info.validate();

    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const writer = &buf.writer;

    try writer.writeInt(u32, COMMIT_MAGIC, .little);
    try writer.writeByte(COMMIT_VERSION);

    try info.snapshot.serialize(writer);
    try info.identity.serialize(writer);
    try info.metadata.serialize(writer);
    try info.message.serialize(writer);

    return store.put(.commit, buf.written());
}

/// High-level helper: build the root tree from the index, then write the
/// commit.  Returns the commit hash.
pub fn buildAndWrite(
    alloc: std.mem.Allocator,
    store: *const Store,
    index: *const index_mod.Index,
    info: CommitInfo,
) !Hash {
    const tree_hash = try tree.writeFromIndex(alloc, store, index.entries.items);

    var commit_info = info;
    commit_info.snapshot.tree = tree_hash;

    return write(alloc, store, commit_info);
}

pub fn read(
    alloc: std.mem.Allocator,
    store: *const Store,
    commit_hash: Hash,
) !Commit {
    const obj = try store.get(commit_hash);
    defer alloc.free(obj.payload);

    if (obj.obj_type != .commit) return error.WrongObjectType;

    var reader = std.Io.Reader.fixed(obj.payload);

    const magic = try reader.takeInt(u32, .little);
    if (magic != COMMIT_MAGIC) return error.CorruptCommit;

    const version = try reader.takeByte();
    if (version != COMMIT_VERSION) return error.UnsupportedCommitVersion;

    var deserialized_snapshot = try Snapshot.deserialize(alloc, &reader);
    errdefer deserialized_snapshot.deinit(alloc);

    var commit_identity = try CommitIdentity.deserialize(alloc, &reader);
    errdefer commit_identity.deinit(alloc);

    var metadata = try CommitMetadataInfo.deserialize(alloc, &reader);
    errdefer metadata.deinit(alloc);

    var deserialized_message = try Message.deserialize(alloc, &reader);
    errdefer deserialized_message.deinit(alloc);

    return .{
        .hash = commit_hash,
        .snapshot = deserialized_snapshot,
        .identity = commit_identity,
        .metadata = metadata,
        .message = deserialized_message,
    };
}

test "commit write and read round-trip" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    const commit_hash = try write(alloc, &store, .{
        .snapshot = .{
            .tree = tree_hash,
            .parents = &.{},
        },
        .identity = .{
            .author = .{
                .name = "Bruce Wayne",
                .email = "bruce@wayne.corp",
                .timestamp_ms = 1_700_000_000_000,
            },
        },
        .metadata = .{
            .timestamp_ms = 1_700_000_000_000,
            .intent = .feature,
            .labels = &.{ "core", "storage" },
        },
        .message = .{
            .title = "Initial commit",
            .body = "Create the initial repository structure.",
            .trailers = &.{
                .{ .key = "reviewed-by", .value = "alfred@wayne.corp" },
                .{ .key = "closes", .value = "#1" },
            },
        },
    });

    var c = try read(alloc, &store, commit_hash);
    defer c.deinit(alloc);

    try std.testing.expectEqualSlices(u8, &tree_hash, &c.snapshot.tree);
    try std.testing.expectEqual(@as(usize, 0), c.snapshot.parents.len);

    try std.testing.expectEqualStrings("Bruce Wayne", c.identity.author.name);
    try std.testing.expectEqualStrings("bruce@wayne.corp", c.identity.author.email);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), c.identity.author.timestamp_ms);

    // committer mirrors author when not supplied
    try std.testing.expectEqualStrings("Bruce Wayne", c.identity.committer.name);
    try std.testing.expect(c.identity.isAuthorCommitter());

    try std.testing.expectEqualStrings("Initial commit", c.message.title);
    try std.testing.expectEqualStrings(
        "Create the initial repository structure.",
        c.message.body,
    );

    try std.testing.expectEqual(@as(usize, 2), c.message.trailers.len);
    try std.testing.expectEqualStrings("reviewed-by", c.message.trailers[0].key);
    try std.testing.expectEqualStrings("alfred@wayne.corp", c.message.trailers[0].value);

    // Lookup helper
    try std.testing.expectEqualStrings("#1", c.message.trailer("closes").?);
    try std.testing.expectEqual(@as(?[]const u8, null), c.message.trailer("missing"));
}

test "commit with explicit committer" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    const commit_hash = try write(alloc, &store, .{
        .snapshot = .{ .tree = tree_hash, .parents = &.{} },
        .identity = .{
            .author = .{
                .name = "Ada Lovelace",
                .email = "ada@lab.net",
                .timestamp_ms = 1_000,
            },
            .committer = .{
                .name = "Nodus Bot",
                .email = "bot@nodus.dev",
                .timestamp_ms = 2_000,
            },
        },
        .metadata = .{ .timestamp_ms = 1, .intent = .chore, .labels = &.{} },
        .message = .{ .title = "cherry-pick: port auth fix", .body = "" },
    });

    var c = try read(alloc, &store, commit_hash);
    defer c.deinit(alloc);

    try std.testing.expectEqualStrings("Ada Lovelace", c.identity.author.name);
    try std.testing.expectEqualStrings("Nodus Bot", c.identity.committer.name);
    try std.testing.expectEqual(@as(i64, 1_000), c.identity.author.timestamp_ms);
    try std.testing.expectEqual(@as(i64, 2_000), c.identity.committer.timestamp_ms);
    try std.testing.expect(!c.identity.isAuthorCommitter());
}

test "commit is deterministic for same inputs" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    const make_commit = struct {
        fn f(s: *const Store, a: std.mem.Allocator, th: Hash) !Hash {
            return write(a, s, .{
                .snapshot = .{ .tree = th, .parents = &.{} },
                .identity = .{
                    .author = .{
                        .name = "Test User",
                        .email = "test@nodus.dev",
                        .timestamp_ms = 42,
                    },
                },
                .metadata = .{
                    .timestamp_ms = 42,
                    .intent = .feature,
                    .labels = &.{ "core", "storage" },
                },
                .message = .{
                    .title = "msg",
                    .body = "deterministic commit",
                    .trailers = &.{.{ .key = "closes", .value = "#7" }},
                },
            });
        }
    }.f;

    const h1 = try make_commit(&store, alloc, tree_hash);
    const h2 = try make_commit(&store, alloc, tree_hash);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "wrong object type returns error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const blob_hash = try store.put(.blob, "not a commit");
    try std.testing.expectError(error.WrongObjectType, read(alloc, &store, blob_hash));
}

test "commit with parents" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    const parent_hash = try write(alloc, &store, .{
        .snapshot = .{ .tree = tree_hash, .parents = &.{} },
        .identity = .{ .author = .{ .name = "Alan Turing", .email = "alan@nodus.dev", .timestamp_ms = 1_000 } },
        .metadata = .{ .timestamp_ms = 1_000, .intent = .feature, .labels = &.{} },
        .message = .{ .title = "root", .body = "" },
    });

    const child_hash = try write(alloc, &store, .{
        .snapshot = .{ .tree = tree_hash, .parents = &.{parent_hash} },
        .identity = .{ .author = .{ .name = "Alan Turing", .email = "alan@nodus.dev", .timestamp_ms = 2_000 } },
        .metadata = .{ .timestamp_ms = 2_000, .intent = .feature, .labels = &.{} },
        .message = .{
            .title = "second",
            .body = "",
            .trailers = &.{.{ .key = "cherry-picked", .value = "abc1234" }},
        },
    });

    var c = try read(alloc, &store, child_hash);
    defer c.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), c.snapshot.parents.len);
    try std.testing.expectEqualSlices(u8, &parent_hash, &c.snapshot.parents[0]);
    try std.testing.expectEqualStrings("second", c.message.title);
    try std.testing.expectEqualStrings(
        "abc1234",
        c.message.trailer("cherry-picked").?,
    );
}

test "resolveHead returns null when HEAD missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try refs.resolveHead(alloc, tmp.dir);
    try std.testing.expectEqual(@as(?Hash, null), result);
}

test "writeHeadRef and updateRef and resolveHead round-trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);
    const commit_hash = try write(alloc, &store, .{
        .snapshot = .{ .tree = tree_hash, .parents = &.{} },
        .identity = .{ .author = .{ .name = "dev", .email = "dev@nodus.local", .timestamp_ms = 1 } },
        .metadata = .{ .timestamp_ms = 1, .intent = .chore, .labels = &.{} },
        .message = .{ .title = "init", .body = "" },
    });

    try refs.writeHeadRef(tmp.dir, "main");
    try refs.updateRef(alloc, tmp.dir, "main", commit_hash);

    const resolved = try refs.resolveHead(alloc, tmp.dir);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, &commit_hash, &resolved.?);

    const branch = try refs.headBranch(alloc, tmp.dir);
    defer if (branch) |b| alloc.free(b);
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("main", branch.?);
}
