const std = @import("std");
const hash_mod = @import("merk").crypto.hash;
const io = @import("merk").io;
const object = @import("./object/object.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

pub const identity = @import("./commit/identity.zig");
const CommitIdentityInfo = identity.CommitIdentityInfo;
const CommitIdentity = identity.CommitIdentity;
const TimestampedIdentityInfo = identity.TimestampedIdentityInfo;

pub const message = @import("./commit/message.zig");
const Message = message.Message;
const MessageInfo = message.MessageInfo;

pub const metadata = @import("./commit/metadata.zig");
const CommitMetadata = metadata.CommitMetadata;
const CommitMetadataInfo = metadata.CommitMetadataInfo;

pub const snapshot = @import("./commit/snapshot.zig");

pub const parent = @import("./commit/parent.zig");
const ParentInfo = parent.ParentInfo;

pub const COMMIT_MAGIC = 0x4E_4F_44_55;
pub const COMMIT_VERSION: u8 = 1;

pub const ParentKind = parent.ParentKind;

pub const MAX_PARENTS: u8 = parent.MAX_PARENTS;

pub const Intent = metadata.Intent;

pub const TrailerInfo = message.TrailerInfo;

/// Internal, assembled representation of a commit-to-be. Not exported:
/// `CommitBuilder` is the only supported way to produce one, so nothing
/// outside this file needs to know its shape
const CommitInfo = struct {
    /// Root hash of whatever content-addressed structure represents
    /// this commit's full state. See the module doc comment — this
    /// module has no opinion about what that structure is
    snapshot: Hash,
    parents: []const ParentInfo,

    /// Author + optional committer. When committer is null it defaults to
    /// the author (same person, same timestamp) at serialisation time
    identity: CommitIdentityInfo,

    metadata: CommitMetadataInfo = .{},
    message: MessageInfo,

    fn validate(self: @This()) !void {
        try parent.validate(self.parents);
        try self.identity.validate();
        try self.metadata.validate();
        try self.message.validate();
    }
};

/// An owned, deep-copied commit as read back from the object store. Free
/// with `.deinit`
pub const Commit = struct {
    hash: Hash,
    snapshot: Hash,
    parents: []ParentInfo,
    identity: CommitIdentity,
    metadata: CommitMetadata,
    message: Message,

    pub fn deinit(self: *Commit, alloc: std.mem.Allocator) void {
        alloc.free(self.parents);
        self.identity.deinit(alloc);
        self.metadata.deinit(alloc);
        self.message.deinit(alloc);

        self.* = undefined;
    }
};

/// Serializes and stores a commit. Private: only `CommitBuilder` calls
/// this, so every commit written by merk goes through the builder's
/// validation and default-filling, never a hand-assembled `CommitInfo`
fn writeCommit(
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

    try snapshot.serialize(info.snapshot, writer);
    try parent.serializeAll(info.parents, writer);
    try info.identity.serialize(writer);
    try info.metadata.serialize(writer);
    try info.message.serialize(writer);

    return store.put(.commit, buf.written());
}

/// Load and deserialize the commit stored at `commit_hash`. Returns
/// `error.WrongObjectType` if the hash doesn't point at a commit, and
/// `error.CorruptCommit` / `error.UnsupportedCommitVersion` if the stored
/// bytes don't parse as one merk understands
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

    const snapshot_root = try snapshot.deserialize(&reader);

    const parents = try parent.deserializeAllAlloc(alloc, &reader);
    errdefer alloc.free(parents);

    var commit_identity = try CommitIdentity.deserialize(alloc, &reader);
    errdefer commit_identity.deinit(alloc);

    var deserialized_metadata = try CommitMetadataInfo.deserialize(alloc, &reader);
    errdefer deserialized_metadata.deinit(alloc);

    var deserialized_message = try Message.deserialize(alloc, &reader);
    errdefer deserialized_message.deinit(alloc);

    return .{
        .hash = commit_hash,
        .snapshot = snapshot_root,
        .parents = parents,
        .identity = commit_identity,
        .metadata = deserialized_metadata,
        .message = deserialized_message,
    };
}

pub const CommitRequest = struct {
    author_name: []const u8,
    author_email: []const u8,
    author_timestamp_ms: i64,
    committer_name: ?[]const u8 = null,
    committer_email: ?[]const u8 = null,
    committer_timestamp_ms: ?i64 = null,
    intent: Intent,
    title: []const u8,
    body: []const u8 = "",
    labels: []const []const u8 = &.{},
    trailers: []const TrailerInfo = &.{},
};

/// Builder for assembling and writing a commit. This is the only
/// supported way to create a commit in merk — there is no public function
/// that takes a hand-built commit struct.
///
///   - Callers never hand-assemble a nested commit struct.
///   - Required fields (snapshot, author, title, intent) fail loudly at
///     `.write()` time via `error.MissingSnapshot` / `error.MissingAuthor`
///     / `error.MissingTitle` / `error.MissingIntent`, rather than
///     silently serializing an incomplete commit. `MissingSnapshot`
///     fires on the zero hash sentinel (`hash_mod.zero_hash`) — this
///     builder has no way to know whether a *non-zero* hash is actually
///     valid or saved anywhere (that's the tree implementation's job),
///     but the zero hash specifically only ever means "nothing was set."
///   - Sensible defaults: committer mirrors author when not set, and the
///     commit metadata timestamp mirrors the author timestamp when not set.
///     Parents default to `.normal` kind when added via `.parent()`.
///   - The builder owns its own scratch allocations (parents/labels/trailers)
///     so callers never juggle intermediate slices themselves. Call
///     `.deinit()` when done, whether or not `.write()` succeeded.
///
/// Example:
///
///   var b = CommitBuilder.init(alloc, snapshot_root);
///   defer b.deinit();
///   _ = b.author("Ada Lovelace", "ada@lab.net", now_ms);
///   _ = b.intent(.feature);
///   _ = b.title("Add builder API");
///   _ = try b.trailer("closes", "#42");
///   const commit_hash = try b.write(&store);
///
/// A caller with a `CommitRequest` in hand (e.g. from user input) can
/// load it in one call instead of the individual setters above:
///
///   var b = CommitBuilder.init(alloc, snapshot_root);
///   defer b.deinit();
///   _ = try b.applyRequest(request);
///   const commit_hash = try b.write(&store);
///
/// A caller doing a merge or cherry-pick records that directly instead
/// of leaving it to the message:
///
///   _ = try b.parentWithKind(base_hash, .normal);
///   _ = try b.parentWithKind(other_branch_hash, .merge);
pub const CommitBuilder = struct {
    alloc: std.mem.Allocator,
    snapshot_root: Hash,
    parents: std.ArrayListUnmanaged(ParentInfo) = .{},

    author_info: ?TimestampedIdentityInfo = null,
    committer_info: ?TimestampedIdentityInfo = null,

    commit_intent: ?Intent = null,
    metadata_timestamp_ms: ?i64 = null,
    labels: std.ArrayListUnmanaged([]const u8) = .{},

    title_text: ?[]const u8 = null,
    body_text: []const u8 = "",
    trailers: std.ArrayListUnmanaged(TrailerInfo) = .{},

    /// `snapshot_root` is the root hash of whatever content-addressed
    /// structure represents this commit's full state — resolve it from
    /// your tree/index implementation before calling this. See the
    /// module doc comment: this builder never looks past this one hash
    pub fn init(alloc: std.mem.Allocator, snapshot_root: Hash) CommitBuilder {
        return .{ .alloc = alloc, .snapshot_root = snapshot_root };
    }

    pub fn deinit(self: *CommitBuilder) void {
        self.parents.deinit(self.alloc);
        self.labels.deinit(self.alloc);
        self.trailers.deinit(self.alloc);
        self.* = undefined;
    }

    /// Add an ordinary (`.normal`) parent edge
    pub fn parent(self: *CommitBuilder, parent_hash: Hash) !*CommitBuilder {
        return self.parentWithKind(parent_hash, .normal);
    }

    /// Add a parent edge with an explicit `ParentKind` — use for merges,
    /// cherry-picks, rebases, and reverts so that provenance is commit
    /// data instead of something inferred from the message
    pub fn parentWithKind(self: *CommitBuilder, parent_hash: Hash, kind: ParentKind) !*CommitBuilder {
        try self.parents.append(self.alloc, .{ .hash = parent_hash, .kind = kind });
        return self;
    }

    /// Add several `.normal` parents at once
    pub fn parentsFrom(self: *CommitBuilder, hashes: []const Hash) !*CommitBuilder {
        for (hashes) |h| _ = try self.parent(h);
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

    /// Populate a builder from a `CommitRequest` in one call: author,
    /// optional committer, intent, title, body, labels, trailers — every
    /// setter this file knows how to call, called correctly and in the
    /// right order (including the committer/label/trailer defaulting
    /// rules documented on the individual setters above).
    ///
    /// This exists so that callers assembling a commit from an
    /// options-style struct (`Repository.commit`, a CLI command, ...)
    /// don't each re-derive this same sequence themselves — they supply
    /// a `CommitRequest` and, separately, whatever snapshot/parent
    /// resolution is specific to them.
    pub fn applyRequest(self: *CommitBuilder, request: CommitRequest) !*CommitBuilder {
        _ = self.author(request.author_name, request.author_email, request.author_timestamp_ms);
        if (request.committer_name) |name| {
            _ = self.committer(
                name,
                request.committer_email orelse request.author_email,
                request.committer_timestamp_ms orelse request.author_timestamp_ms,
            );
        }
        _ = self.intent(request.intent);
        _ = self.title(request.title);
        _ = self.body(request.body);
        if (request.labels.len > 0) _ = try self.labelsFrom(request.labels);
        for (request.trailers) |t| _ = try self.trailer(t.key, t.value);
        return self;
    }

    /// Assemble the internal commit representation. Slices point into
    /// builder-owned storage, so the result is only valid while `self` is
    /// alive — this is why it's private and only ever consumed inline by
    /// `write` below.
    fn build(self: *const CommitBuilder) !CommitInfo {
        if (std.mem.eql(u8, &self.snapshot_root, &hash_mod.zero_hash)) return error.MissingSnapshot;
        const author_info = self.author_info orelse return error.MissingAuthor;
        const title_text = self.title_text orelse return error.MissingTitle;
        const commit_intent = self.commit_intent orelse return error.MissingIntent;
        const meta_ts = self.metadata_timestamp_ms orelse author_info.timestamp_ms;

        return .{
            .snapshot = self.snapshot_root,
            .parents = self.parents.items,
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
        return writeCommit(self.alloc, store, info);
    }
};

fn testCommit(
    alloc: std.mem.Allocator,
    store: *const Store,
    snapshot_hash: Hash,
    name: []const u8,
    email: []const u8,
    timestamp_ms: i64,
    commit_title: []const u8,
) !Hash {
    var b = CommitBuilder.init(alloc, snapshot_hash);
    defer b.deinit();
    _ = b.author(name, email, timestamp_ms);
    _ = b.intent(.chore);
    _ = b.title(commit_title);
    return b.write(store);
}

test "CommitBuilder.applyRequest populates author, committer default, and trailers" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");

    const snapshot_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, snapshot_hash);
    defer b.deinit();
    _ = try b.applyRequest(.{
        .author_name = "Ada Lovelace",
        .author_email = "ada@nodus.dev",
        .author_timestamp_ms = 1_000,
        .intent = .feature,
        .title = "via applyRequest",
        .labels = &.{"core"},
        .trailers = &.{.{ .key = "closes", .value = "#5" }},
    });

    const commit_hash = try b.write(&store);

    var c = try read(alloc, &store, commit_hash);
    defer c.deinit(alloc);

    try std.testing.expectEqualStrings("Ada Lovelace", c.identity.author.name);
    try std.testing.expect(c.identity.isAuthorCommitter());
    try std.testing.expectEqualStrings("via applyRequest", c.message.title);
    try std.testing.expectEqualStrings("#5", c.message.trailer("closes").?);
    try std.testing.expectEqual(@as(usize, 1), c.metadata.labels.len);
    try std.testing.expectEqualStrings("core", c.metadata.labels[0]);
}

test "commit write and read round-trip" {
    const alloc = std.testing.allocator;

    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");

    const snapshot_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, snapshot_hash);
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

    try std.testing.expectEqualSlices(u8, &snapshot_hash, &c.snapshot);
    try std.testing.expectEqual(@as(usize, 0), c.parents.len);

    try std.testing.expectEqualStrings("Bruce Wayne", c.identity.author.name);
    try std.testing.expectEqualStrings("bruce@wayne.corp", c.identity.author.email);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), c.identity.author.timestamp_ms);

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

    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");
    const snapshot_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, snapshot_hash);
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

    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");
    const snapshot_hash = try store.put(.tree, &[_]u8{0} ** 4);

    const make_commit = struct {
        fn f(s: *const Store, a: std.mem.Allocator, sh: Hash) !Hash {
            var b = CommitBuilder.init(a, sh);
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

    const h1 = try make_commit(&store, alloc, snapshot_hash);
    const h2 = try make_commit(&store, alloc, snapshot_hash);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "wrong object type returns error" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");
    const blob_hash = try store.put(.blob, "not a commit");
    try std.testing.expectError(error.WrongObjectType, read(alloc, &store, blob_hash));
}

test "commit with a normal parent" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");
    const snapshot_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var root_b = CommitBuilder.init(alloc, snapshot_hash);
    defer root_b.deinit();
    _ = root_b.author("Alan Turing", "alan@nodus.dev", 1_000);
    _ = root_b.intent(.feature);
    _ = root_b.title("root");
    const parent_hash = try root_b.write(&store);

    var child_b = CommitBuilder.init(alloc, snapshot_hash);
    defer child_b.deinit();
    _ = try child_b.parent(parent_hash);
    _ = child_b.author("Alan Turing", "alan@nodus.dev", 2_000);
    _ = child_b.intent(.feature);
    _ = child_b.title("second");
    _ = try child_b.trailer("cherry-picked", "abc1234");
    const child_hash = try child_b.write(&store);

    var c = try read(alloc, &store, child_hash);
    defer c.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), c.parents.len);
    try std.testing.expectEqualSlices(u8, &parent_hash, &c.parents[0].hash);
    try std.testing.expectEqual(ParentKind.normal, c.parents[0].kind);
    try std.testing.expectEqualStrings("second", c.message.title);
    try std.testing.expectEqualStrings(
        "abc1234",
        c.message.trailer("cherry-picked").?,
    );
}

test "commit records why a parent edge exists: merge and cherry-pick" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");
    const snapshot_hash = try store.put(.tree, &[_]u8{0} ** 4);

    const base_hash = try testCommit(alloc, &store, snapshot_hash, "Dev A", "a@nodus.dev", 1, "base");
    const branch_hash = try testCommit(alloc, &store, snapshot_hash, "Dev B", "b@nodus.dev", 2, "branch");

    var merge_b = CommitBuilder.init(alloc, snapshot_hash);
    defer merge_b.deinit();
    _ = try merge_b.parentWithKind(base_hash, .normal);
    _ = try merge_b.parentWithKind(branch_hash, .merge);
    _ = merge_b.author("Dev C", "c@nodus.dev", 3);
    _ = merge_b.intent(.chore);
    _ = merge_b.title("merge branch");
    const merge_hash = try merge_b.write(&store);

    var mc = try read(alloc, &store, merge_hash);
    defer mc.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), mc.parents.len);
    try std.testing.expectEqual(ParentKind.normal, mc.parents[0].kind);
    try std.testing.expectEqual(ParentKind.merge, mc.parents[1].kind);
    try std.testing.expectEqualSlices(u8, &branch_hash, &mc.parents[1].hash);
}
test "CommitBuilder rejects a commit with an unset (zero) snapshot" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");

    var b = CommitBuilder.init(alloc, hash_mod.zero_hash);
    defer b.deinit();
    _ = b.author("No Snapshot", "nosnap@nodus.dev", 1);
    _ = b.intent(.chore);
    _ = b.title("no snapshot");

    try std.testing.expectError(error.MissingSnapshot, b.write(&store));
}

test "CommitBuilder rejects a commit with no author" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");

    const snapshot_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, snapshot_hash);
    defer b.deinit();
    _ = b.intent(.chore);
    _ = b.title("no author");

    try std.testing.expectError(error.MissingAuthor, b.write(&store));
}

test "CommitBuilder rejects a commit with no title" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");

    const snapshot_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, snapshot_hash);
    defer b.deinit();
    _ = b.author("No Title", "notitle@nodus.dev", 1);
    _ = b.intent(.chore);

    try std.testing.expectError(error.MissingTitle, b.write(&store));
}

test "CommitBuilder rejects a commit with no intent" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = Store.init(alloc, tfs.fs(), "objects");

    const snapshot_hash = try store.put(.tree, &[_]u8{0} ** 4);

    var b = CommitBuilder.init(alloc, snapshot_hash);
    defer b.deinit();
    _ = b.author("No Intent", "nointent@nodus.dev", 1);
    _ = b.title("no intent");

    try std.testing.expectError(error.MissingIntent, b.write(&store));
}
