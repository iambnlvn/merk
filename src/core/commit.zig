const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

pub const identity = @import("./commit/identity.zig");
const CommitIdentityInfo = identity.CommitIdentityInfo;
const CommitIdentity = identity.CommitIdentity;
const TimestampedIdentityInfo = identity.TimestampedIdentityInfo;

pub const message = @import("./commit/message.zig");
const Message = message.Message;
const MessageInfo = message.MessageInfo;

const TrailerInfo = message.TrailerInfo;

const snapshot = @import("./commit/snapshot.zig");
const Snapshot = snapshot.Snapshot;
const SnapshotInfo = snapshot.SnapshotInfo;

pub const commitMetadata = @import("./commit/metadata.zig");
const CommitMetadata = commitMetadata.CommitMetadata;
const CommitMetadataInfo = commitMetadata.CommitMetadataInfo;
const Intent = commitMetadata.Intent;

const refs = @import("./refs.zig");

pub const COMMIT_MAGIC = 0x4E_4F_44_55;
pub const COMMIT_VERSION: u8 = 1;
pub const MAX_PARENTS: u8 = 255;

/// Internal, assembled representation of a commit-to-be. Not exported:
/// `CommitBuilder` is the only supported way to produce one, so nothing
/// outside this file needs to know its shape.
const CommitInfo = struct {
    snapshot: SnapshotInfo,

    /// Author + optional committer.  When committer is null it defaults to
    /// the author (same person, same timestamp) at serialisation time.
    identity: CommitIdentityInfo,

    metadata: CommitMetadataInfo = .{},
    message: MessageInfo,

    fn validate(self: @This()) !void {
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

/// Serializes and stores a commit. Private: only `CommitBuilder` calls this,
/// so every commit written by nodus goes through the builder's validation
/// and default-filling, never a hand-assembled `CommitInfo`.
fn serializeCommit(
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

/// Serializes and stores a commit whose snapshot tree is a saved `Index`
/// root. Private: reached only via `CommitBuilder.writeFromIndex`.
fn serializeFromIndex(
    alloc: std.mem.Allocator,
    store: *const Store,
    index: *const index_mod.Index,
    info: CommitInfo,
) !Hash {
    if (std.mem.eql(u8, &index.index_root, &hash_mod.ZERO_HASH) and index.entries.items.len != 0) {
        return error.UnsavedIndexRoot;
    }

    var commit_info = info;
    commit_info.snapshot.tree = index.index_root;

    return serializeCommit(alloc, store, commit_info);
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

/// Builder for assembling and writing a commit. This is the only
/// supported way to create a commit in nodus — there is no public function
/// that takes a hand-built commit struct.
///
///   - Callers never hand-assemble a nested commit struct.
///   - Required fields (author, title, intent) fail loudly at `.write()` /
///     `.writeFromIndex()` time via `error.MissingAuthor` /
///     `error.MissingTitle` / `error.MissingIntent`, rather than silently
///     serializing an incomplete commit.
///   - Sensible defaults: committer mirrors author when not set, and the
///     commit metadata timestamp mirrors the author timestamp when not set.
///   - The builder owns its own scratch allocations (parents/labels/trailers)
///     so callers never juggle intermediate slices themselves. Call
///     `.deinit()` when done, whether or not `.write()` succeeded.
///
/// Example:
///
///   var b = CommitBuilder.init(alloc, tree_hash);
///   defer b.deinit();
///   _ = b.author("Ada Lovelace", "ada@lab.net", now_ms);
///   _ = b.intent(.feature);
///   _ = b.title("Add builder API");
///   _ = try b.trailer("closes", "#42");
///   const commit_hash = try b.write(&store);
pub const CommitBuilder = struct {
    alloc: std.mem.Allocator,
    tree: Hash,
    parents: std.ArrayListUnmanaged(Hash) = .{},

    author_info: ?TimestampedIdentityInfo = null,
    committer_info: ?TimestampedIdentityInfo = null,

    commit_intent: ?Intent = null,
    metadata_timestamp_ms: ?i64 = null,
    labels: std.ArrayListUnmanaged([]const u8) = .{},

    title_text: ?[]const u8 = null,
    body_text: []const u8 = "",
    trailers: std.ArrayListUnmanaged(TrailerInfo) = .{},

    pub fn init(alloc: std.mem.Allocator, tree: Hash) CommitBuilder {
        return .{ .alloc = alloc, .tree = tree };
    }

    pub fn deinit(self: *CommitBuilder) void {
        self.parents.deinit(self.alloc);
        self.labels.deinit(self.alloc);
        self.trailers.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn parent(self: *CommitBuilder, parent_hash: Hash) !*CommitBuilder {
        try self.parents.append(self.alloc, parent_hash);
        return self;
    }

    pub fn parentsFrom(self: *CommitBuilder, hashes: []const Hash) !*CommitBuilder {
        try self.parents.appendSlice(self.alloc, hashes);
        return self;
    }

    pub fn author(self: *CommitBuilder, name: []const u8, email: []const u8, timestamp_ms: i64) *CommitBuilder {
        self.author_info = .{ .name = name, .email = email, .timestamp_ms = timestamp_ms };
        return self;
    }

    /// Optional. When not called, the committer defaults to the author
    /// (same person, same timestamp) — matching the existing serialize-time
    /// behavior documented on the commit's identity.
    pub fn committer(self: *CommitBuilder, name: []const u8, email: []const u8, timestamp_ms: i64) *CommitBuilder {
        self.committer_info = .{
            .name = name,
            .email = email,
            .timestamp_ms = timestamp_ms,
        };
        return self;
    }

    pub fn intent(self: *CommitBuilder, value: Intent) *CommitBuilder {
        self.commit_intent = value;
        return self;
    }

    /// Optional. Defaults to the author's timestamp when not set.
    pub fn timestamp(self: *CommitBuilder, timestamp_ms: i64) *CommitBuilder {
        self.metadata_timestamp_ms = timestamp_ms;
        return self;
    }

    pub fn label(self: *CommitBuilder, value: []const u8) !*CommitBuilder {
        try self.labels.append(self.alloc, value);
        return self;
    }

    pub fn labelsFrom(self: *CommitBuilder, values: []const []const u8) !*CommitBuilder {
        try self.labels.appendSlice(self.alloc, values);
        return self;
    }

    pub fn title(self: *CommitBuilder, value: []const u8) *CommitBuilder {
        self.title_text = value;
        return self;
    }

    pub fn body(self: *CommitBuilder, value: []const u8) *CommitBuilder {
        self.body_text = value;
        return self;
    }

    pub fn trailer(self: *CommitBuilder, key: []const u8, value: []const u8) !*CommitBuilder {
        try self.trailers.append(self.alloc, .{ .key = key, .value = value });
        return self;
    }

    /// Assemble the internal commit representation. Slices point into
    /// builder-owned storage, so the result is only valid while `self` is
    /// alive — this is why it's private and only ever consumed inline by
    /// `write`/`writeFromIndex` below.
    fn build(self: *const CommitBuilder) !CommitInfo {
        const author_info = self.author_info orelse return error.MissingAuthor;
        const title_text = self.title_text orelse return error.MissingTitle;
        const commit_intent = self.commit_intent orelse return error.MissingIntent;
        const meta_ts = self.metadata_timestamp_ms orelse author_info.timestamp_ms;

        return .{
            .snapshot = .{
                .tree = self.tree,
                .parents = self.parents.items,
            },
            .identity = .{
                .author = author_info,
                .committer = self.committer_info,
            },
            .metadata = .{
                .timestamp_ms = meta_ts,
                .intent = commit_intent,
                .labels = self.labels.items,
            },
            .message = .{
                .title = title_text,
                .body = self.body_text,
                .trailers = self.trailers.items,
            },
        };
    }

    /// Assemble and persist the commit.
    pub fn write(self: *const CommitBuilder, store: *const Store) !Hash {
        const info = try self.build();
        return serializeCommit(self.alloc, store, info);
    }

    /// Assemble and persist the commit with its snapshot tree taken from a
    /// saved `Index` root. Whatever tree hash the builder was constructed
    /// with is overwritten by `index.index_root`.
    pub fn writeFromIndex(self: *const CommitBuilder, store: *const Store, index: *const index_mod.Index) !Hash {
        const info = try self.build();
        return serializeFromIndex(self.alloc, store, index, info);
    }
};

fn testCommit(
    alloc: std.mem.Allocator,
    store: *const Store,
    tree_hash: Hash,
    name: []const u8,
    email: []const u8,
    timestamp_ms: i64,
    commit_title: []const u8,
) !Hash {
    var b = CommitBuilder.init(alloc, tree_hash);
    defer b.deinit();
    _ = b.author(name, email, timestamp_ms);
    _ = b.intent(.chore);
    _ = b.title(commit_title);
    return b.write(store);
}

test "commit write and read round-trip" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, tree_hash);
    defer b.deinit();
    _ = b.author("Bruce Wayne", "bruce@wayne.corp", 1_700_000_000_000);
    _ = b.intent(.feature);
    _ = try b.label("core");
    _ = try b.label("storage");
    _ = b.title("Initial commit");
    _ = b.body("Create the initial repository structure.");
    _ = try b.trailer("reviewed-by", "alfred@wayne.corp");
    _ = try b.trailer("closes", "#1");

    const commit_hash = try b.write(&store);

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

    var b = CommitBuilder.init(alloc, tree_hash);
    defer b.deinit();
    _ = b.author("Ada Lovelace", "ada@lab.net", 1_000);
    _ = b.committer("Nodus Bot", "bot@nodus.dev", 2_000);
    _ = b.intent(.chore);
    _ = b.timestamp(1);
    _ = b.title("cherry-pick: port auth fix");

    const commit_hash = try b.write(&store);

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
            var b = CommitBuilder.init(a, th);
            defer b.deinit();
            _ = b.author("Test User", "test@nodus.dev", 42);
            _ = b.intent(.feature);
            _ = try b.label("core");
            _ = try b.label("storage");
            _ = b.title("msg");
            _ = b.body("deterministic commit");
            _ = try b.trailer("closes", "#7");
            return b.write(s);
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

    var root_b = CommitBuilder.init(alloc, tree_hash);
    defer root_b.deinit();
    _ = root_b.author("Alan Turing", "alan@nodus.dev", 1_000);
    _ = root_b.intent(.feature);
    _ = root_b.title("root");
    const parent_hash = try root_b.write(&store);

    var child_b = CommitBuilder.init(alloc, tree_hash);
    defer child_b.deinit();
    _ = try child_b.parent(parent_hash);
    _ = child_b.author("Alan Turing", "alan@nodus.dev", 2_000);
    _ = child_b.intent(.feature);
    _ = child_b.title("second");
    _ = try child_b.trailer("cherry-picked", "abc1234");
    const child_hash = try child_b.write(&store);

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

test "CommitBuilder rejects a commit with no author" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, tree_hash);
    defer b.deinit();
    _ = b.intent(.chore);
    _ = b.title("no author");

    try std.testing.expectError(error.MissingAuthor, b.write(&store));
}

test "CommitBuilder rejects a commit with no title" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, tree_hash);
    defer b.deinit();
    _ = b.author("No Title", "notitle@nodus.dev", 1);
    _ = b.intent(.chore);

    try std.testing.expectError(error.MissingTitle, b.write(&store));
}

test "CommitBuilder rejects a commit with no intent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, tree_hash);
    defer b.deinit();
    _ = b.author("No Intent", "nointent@nodus.dev", 1);
    _ = b.title("no intent");

    try std.testing.expectError(error.MissingIntent, b.write(&store));
}

test "resolveHead returns null when HEAD missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ref_store = refs.RefStore.init(std.testing.allocator, tmp.dir);
    const result = try ref_store.resolveHead();
    try std.testing.expectEqual(@as(?Hash, null), result);
}

test "writeHeadRef and updateBranch and resolveHead round-trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);
    const commit_hash = try testCommit(alloc, &store, tree_hash, "dev", "dev@nodus.local", 1, "init");

    const ref_store = refs.RefStore.init(alloc, tmp.dir);
    const main = try refs.BranchName.parse("main");

    try ref_store.writeHeadRef(main);
    try ref_store.updateBranch(main, commit_hash);

    const resolved = try ref_store.resolveHead();
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, &commit_hash, &resolved.?);

    const branch = try ref_store.headBranch();
    defer if (branch) |b| alloc.free(b);
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("main", branch.?);
}
