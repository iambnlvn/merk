const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Io = std.Io;

const hash_mod = @import("merk").crypto;
const Hash = hash_mod.Hash;

const storage = @import("storage");
const MemoryFs = storage.MemoryFs;
const Vfs = storage.Vfs;

const object = @import("./object/object.zig");
const Store = object.Store;

const ComponentDir = @import("./commit/dir.zig").ComponentDir;

const identity = @import("./commit/identity.zig");
const CommitSignatures = identity.CommitSignatures;
const CommitSignaturesInfo = identity.CommitSignaturesInfo;
const PersonInfo = identity.PersonInfo;
const SignatureInfo = identity.SignatureInfo;
const Timezone = identity.Timezone;

const message = @import("./commit/message.zig");
const Message = message.Message;
const MessageInfo = message.MessageInfo;

const metadata = @import("./commit/metadata.zig");
const CommitMetadata = metadata.CommitMetadata;
const CommitMetadataInfo = metadata.CommitMetadataInfo;

const parent = @import("./commit/parent.zig");
pub const ParentInfo = parent.ParentInfo;

const snapshot = @import("./commit/snapshot.zig");

// Logical (change_id-keyed) dependency edges for stacked changes —
// see `commit/dependency.zig`'s doc comment for why this is a distinct
// concept from `parent`/`ParentInfo`'s physical (hash-keyed) ancestry.
const dependency = @import("./commit/dependency.zig");
const DependencyInfo = dependency.DependencyInfo;

// `commit/signature.zig` is the *cryptographic* signature sidecar
// (algorithm + bytes + key_id) attached to a commit hash after the fact
// — a completely different concept from identity.zig's `SignatureInfo`/
// `Signature` (who authored/committed, and when). Bound under `Crypto*`
// names here so the two don't collide.
const signature = @import("./commit/signature.zig");
const CryptoSignature = signature.Signature;
const CryptoSignatureInfo = signature.SignatureInfo;

pub const COMMIT_MAGIC = 0x4D_45_52_4B;

pub const COMMIT_VERSION: u8 = 1;

pub const ParentKind = parent.ParentKind;

pub const MAX_PARENTS: u8 = parent.MAX_PARENTS;

pub const MAX_DEPENDENCIES: u8 = dependency.MAX_DEPENDENCIES;

pub const Intent = metadata.Intent;

pub const TrailerInfo = message.TrailerInfo;

pub const Encoding = message.Encoding;

pub const ChangeId = metadata.ChangeId;
pub const generateChangeId = metadata.generateChangeId;

pub const SignatureAlgorithm = signature.SignatureAlgorithm;

/// Internal, assembled representation of a commit-to-be. Not exported:
/// `CommitBuilder` is the only supported way to produce one, so nothing
/// outside this file needs to know its shape
const CommitInfo = struct {
    /// Root hash of whatever content-addressed structure represents
    /// this commit's full state. See the module doc comment — this
    /// module has no opinion about what that structure is
    snapshot: Hash,
    parents: []const ParentInfo,

    /// Logical "this change needs that change" edges for stacked
    /// commits — keyed by `ChangeId`, not `Hash`. See
    /// `commit/dependency.zig`'s doc comment for why these are kept
    /// separate from `parents`.
    dependencies: []const DependencyInfo = &.{},

    /// Author + committer. Callers who want the committer to mirror the
    /// author go through `CommitSignaturesInfo.soloAuthor`; callers with a
    /// genuinely distinct committer go through `.init` — see
    /// `CommitBuilder.build` below, which picks between the two.
    identity: CommitSignaturesInfo,

    metadata: CommitMetadataInfo = .{},
    message: MessageInfo,

    fn validate(self: @This()) !void {
        try parent.validate(self.parents);
        try dependency.validate(self.dependencies, self.metadata.change_id);
        for (self.dependencies) |d| {
            if (std.mem.eql(u8, &d.change_id, &self.metadata.change_id))
                return error.SelfDependency;
        }
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
    dependencies: []DependencyInfo,
    identity: CommitSignatures,
    metadata: CommitMetadata,
    message: Message,

    /// True for a commit with no parents — the start of a history, not
    /// necessarily the very first commit ever made (e.g. a grafted or
    /// re-rooted history can have more than one root)
    pub fn isRoot(self: Commit) bool {
        return self.parents.len == 0;
    }

    /// True for a commit with more than one parent. Doesn't distinguish
    /// *why* — check individual `parents[i].kind` for that (a commit can
    /// have two parents without either being tagged `.merge`, and a
    /// single non-`.normal` parent, e.g. `.cherry_pick`, isn't a merge)
    pub fn isMerge(self: Commit) bool {
        return self.parents.len > 1;
    }

    /// True when `self` and `other` are different snapshots of the same
    /// evolving logical change (same `change_id`) — e.g. before and
    /// after a rebase or `commit --amend` — even though their hashes
    /// (and possibly everything else) differ. See `ChangeId`'s doc
    /// comment in `commit/metadata.zig`.
    pub fn isSameChange(self: Commit, other: Commit) bool {
        return std.mem.eql(u8, &self.metadata.change_id, &other.metadata.change_id);
    }

    /// True when this commit declares a (logical) dependency on
    /// `change_id`. Only checks this commit's own `dependencies` list —
    /// resolving `change_id` to whatever commit it currently points at,
    /// or walking a whole stack, is a `Repository`-level concern (see
    /// `commit/dependency.zig`'s doc comment).
    pub fn dependsOnChange(self: Commit, change_id: ChangeId) bool {
        for (self.dependencies) |d| {
            if (std.mem.eql(u8, &d.change_id, &change_id)) return true;
        }
        return false;
    }

    /// Just the hashes, dropping `ParentKind` — for callers doing plain
    /// graph traversal (e.g. a log walker) that don't care why an edge
    /// exists, only that it does. Caller frees with `alloc.free`
    pub fn parentHashesAlloc(self: Commit, alloc: Allocator) ![]Hash {
        const hashes = try alloc.alloc(Hash, self.parents.len);
        for (self.parents, 0..) |p, i| hashes[i] = p.hash;
        return hashes;
    }

    pub fn deinit(self: *Commit, alloc: Allocator) void {
        alloc.free(self.parents);
        alloc.free(self.dependencies);
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
    alloc: Allocator,
    store: *const Store,
    info: CommitInfo,
) !Hash {
    try info.validate();

    var buf = Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const writer = &buf.writer;

    try writer.writeInt(u32, COMMIT_MAGIC, .little);
    try writer.writeByte(COMMIT_VERSION);

    try snapshot.serialize(info.snapshot, writer);
    try parent.serializeAll(info.parents, writer);
    try dependency.serializeAll(info.dependencies, info.metadata.change_id, writer);
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
    alloc: Allocator,
    store: *const Store,
    commit_hash: Hash,
) !Commit {
    const obj = try store.get(commit_hash);
    defer alloc.free(obj.payload);

    if (obj.obj_type != .commit) return error.WrongObjectType;

    var reader = Io.Reader.fixed(obj.payload);

    const magic = try reader.takeInt(u32, .little);
    if (magic != COMMIT_MAGIC) return error.CorruptCommit;

    const version = try reader.takeByte();
    if (version != COMMIT_VERSION) return error.UnsupportedCommitVersion;

    const snapshot_root = try snapshot.deserialize(&reader);

    const parents = try parent.deserializeAllAlloc(alloc, &reader);
    errdefer alloc.free(parents);

    const dependencies = try dependency.deserializeAllAlloc(alloc, &reader);
    errdefer alloc.free(dependencies);

    var commit_identity = try CommitSignatures.deserialize(alloc, &reader);
    errdefer commit_identity.deinit(alloc);

    var deserialized_metadata = try CommitMetadataInfo.deserialize(alloc, &reader);
    errdefer deserialized_metadata.deinit(alloc);

    var deserialized_message = try Message.deserialize(alloc, &reader);
    errdefer deserialized_message.deinit(alloc);

    return .{
        .hash = commit_hash,
        .snapshot = snapshot_root,
        .parents = parents,
        .dependencies = dependencies,
        .identity = commit_identity,
        .metadata = deserialized_metadata,
        .message = deserialized_message,
    };
}

/// Signatures live *outside* the content-addressed commit object, on
/// purpose: a signature signs the commit's hash, so embedding it inside
/// the bytes that hash is computed over is a chicken-and-egg problem
/// (either the signature isn't over the final hash, or the hash isn't
/// stable). Storing it as a sidecar keyed by the commit hash it signs
/// means:
///   - `Commit.hash` never changes because a commit got signed,
///     re-signed, or countersigned by a second key,
///   - an unsigned commit costs nothing (no sidecar file at all),
///
/// merk does not verify signatures — this is storage and retrieval
/// only. Verifying `sig.bytes` against `sig.key_id` for a given
/// `commit_hash` is the caller's job (a CLI command, CI policy, ...).
pub const CommitSignatureStore = struct {
    alloc: Allocator,
    fs: Vfs,
    /// Where signature sidecar files live, relative to `fs`'s root.
    /// Typically ".merk/history/signatures".
    dir: ComponentDir,

    pub fn init(alloc: Allocator, fs: Vfs, signatures_dir: []const u8) CommitSignatureStore {
        return .{ .alloc = alloc, .fs = fs, .dir = ComponentDir.init(signatures_dir) };
    }

    /// Attach (or replace) the signature for `commit_hash`. Doesn't
    /// check that `commit_hash` actually exists in the object store
    pub fn attach(self: CommitSignatureStore, commit_hash: Hash, sig: CryptoSignatureInfo) !void {
        try sig.validate();

        var buf = Io.Writer.Allocating.init(self.alloc);
        defer buf.deinit();
        try sig.serialize(&buf.writer);

        const path = try self.sigPath(commit_hash);
        defer self.alloc.free(path);
        try self.fs.writeFile(self.alloc, path, buf.written());
    }

    /// The signature attached to `commit_hash`, or `null` if it isn't
    /// signed. Caller frees with `.deinit(alloc)`.
    pub fn get(self: CommitSignatureStore, commit_hash: Hash) !?CryptoSignature {
        const path = try self.sigPath(commit_hash);
        defer self.alloc.free(path);

        const bytes = (try self.fs.readFile(self.alloc, path)) orelse return null;
        defer self.alloc.free(bytes);

        var reader = Io.Reader.fixed(bytes);
        return try CryptoSignature.deserialize(self.alloc, &reader);
    }

    /// Remove a signature, if present. Not an error if `commit_hash`
    /// was never signed
    pub fn remove(self: CommitSignatureStore, commit_hash: Hash) !void {
        const path = try self.sigPath(commit_hash);
        defer self.alloc.free(path);
        self.fs.deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Sharded by the commit hash itself. Unlike `PathHistory` (which
    /// hashes an arbitrary path first), `commit_hash` is already a
    /// uniformly distributed content hash, so no extra hashing step is
    /// needed to get good directory fan-out. Delegates to
    /// `ComponentDir.shardedPath` rather than formatting the
    /// "<dir>/xx/yy/<hex>" path by hand — the same sharding logic
    /// `object.Store.objectPath` uses, so both stay in sync through one
    /// shared implementation instead of two copies drifting apart.
    fn sigPath(self: CommitSignatureStore, commit_hash: Hash) ![]u8 {
        var hex_buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{commit_hash}) catch unreachable;
        return self.dir.shardedPath(self.alloc, hex);
    }
};

/// Everything needed to populate a builder for an ordinary commit,
/// independent of where the snapshot and parents come from. Callers
/// that resolve those themselves (e.g. `Repository`, reading HEAD and
/// resolving the current snapshot root) still supply them separately —
/// this only covers the identity/metadata/message fields, which is
/// exactly what tends to get re-derived by every caller that builds
/// commits from user input
pub const CommitRequest = struct {
    author_name: []const u8,
    author_email: []const u8,
    author_timestamp_ms: i64,
    /// Minutes east of UTC the author's timestamp was recorded in.
    /// Defaults to 0 (UTC)
    author_tz_offset_minutes: i16 = 0,

    committer_name: ?[]const u8 = null,
    committer_email: ?[]const u8 = null,
    committer_timestamp_ms: ?i64 = null,
    /// Defaults to `author_tz_offset_minutes` when a committer is
    /// supplied but its own offset isn't, mirrors the existing
    /// name/email/timestamp defaulting
    committer_tz_offset_minutes: ?i16 = null,

    intent: Intent,
    title: []const u8,
    body: []const u8 = "",
    /// Character encoding of `title`/`body`. Defaults to UTF-8.
    encoding: Encoding = .utf8,
    labels: []const []const u8 = &.{},
    trailers: []const TrailerInfo = &.{},

    /// `change_id`s of the commits this stacked change depends on. See
    /// `CommitBuilder.dependsOn`'s doc comment.
    dependencies: []const ChangeId = &.{},

    /// Carry forward the `change_id` of the commit being amended,
    /// rebased, or cherry-picked from. Leave `null` for a genuinely new
    /// logical change — `CommitBuilder.build` will generate a fresh one.
    change_id: ?ChangeId = null,
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
///     `change_id` defaults to a fresh random id when not set via
///     `.changeId()` — see `ChangeId`'s doc comment for when to instead
///     carry one forward.
///   - The builder owns its own scratch allocations (parents/labels/trailers)
///     so callers never juggle intermediate slices themselves. Call
///     `.deinit()` when done, whether or not `.write()` succeeded.
///   - Setters mutate the builder in place and return `void` (or `!void`
///     when they can fail) rather than `*CommitBuilder` — there is no
///     chaining API to opt into or out of, only a sequence of statements.
///
/// Example:
///
///   var b = CommitBuilder.init(alloc, snapshot_root);
///   defer b.deinit();
///   b.author("Ada Lovelace", "ada@lab.net", now_ms);
///   b.intent(.feature);
///   b.title("Add builder API");
///   try b.trailer("closes", "#42");
///   const commit_hash = try b.write(&store);
///
/// A caller with a `CommitRequest` in hand (e.g. from user input) can
/// build directly from it instead of the individual setters above:
///
///   var b = try CommitBuilder.fromRequest(alloc, snapshot_root, request);
///   defer b.deinit();
///   const commit_hash = try b.write(&store);
pub const CommitBuilder = struct {
    alloc: Allocator,
    snapshot_root: Hash,
    parents: std.ArrayListUnmanaged(ParentInfo) = .{},
    dependencies: std.ArrayListUnmanaged(DependencyInfo) = .{},

    author_info: ?SignatureInfo = null,
    committer_info: ?SignatureInfo = null,

    commit_intent: ?Intent = null,
    metadata_timestamp_ms: ?i64 = null,
    change_id_override: ?ChangeId = null,
    labels: std.ArrayListUnmanaged([]const u8) = .{},

    title_text: ?[]const u8 = null,
    body_text: []const u8 = "",
    msg_encoding: Encoding = .utf8,
    trailers: std.ArrayListUnmanaged(TrailerInfo) = .{},

    /// `snapshot_root` is the root hash of whatever content-addressed
    /// structure represents this commit's full state — resolve it from
    /// your tree/index implementation before calling this. See the
    /// module doc comment: this builder never looks past this one hash.
    pub fn init(alloc: Allocator, snapshot_root: Hash) CommitBuilder {
        return .{ .alloc = alloc, .snapshot_root = snapshot_root };
    }

    /// Shortcut for `init` immediately followed by `applyRequest` — the
    /// common shape for any caller that already has a full
    /// `CommitRequest` in hand (a CLI command, `Repository.commit`, ...)
    /// and just needs a resolved snapshot root to go with it. Parents
    /// still get added separately via `.parent()` / `.parentWithKind()`,
    /// since `CommitRequest` deliberately doesn't carry them (see its
    /// doc comment).
    pub fn fromRequest(
        alloc: Allocator,
        snapshot_root: Hash,
        request: CommitRequest,
    ) !CommitBuilder {
        var b = CommitBuilder.init(alloc, snapshot_root);
        errdefer b.deinit();
        try b.applyRequest(request);
        return b;
    }

    pub fn deinit(self: *CommitBuilder) void {
        self.parents.deinit(self.alloc);
        self.dependencies.deinit(self.alloc);
        self.labels.deinit(self.alloc);
        self.trailers.deinit(self.alloc);
        self.* = undefined;
    }

    /// Add an ordinary (`.normal`) parent edge.
    pub fn parent(self: *CommitBuilder, parent_hash: Hash) !void {
        try self.parentWithKind(parent_hash, .normal);
    }

    /// Add a parent edge with an explicit `ParentKind` — use for merges,
    /// cherry-picks, rebases, and reverts so that provenance is commit
    /// data instead of something inferred from the message.
    pub fn parentWithKind(self: *CommitBuilder, parent_hash: Hash, kind: ParentKind) !void {
        try self.parents.append(self.alloc, .{ .hash = parent_hash, .kind = kind });
    }

    /// Add several `.normal` parents at once.
    pub fn parentsFrom(self: *CommitBuilder, hashes: []const Hash) !void {
        for (hashes) |h| try self.parent(h);
    }

    /// Add several parents at once with the same explicit `ParentKind`
    /// — e.g. a single commit that transplants several branch tips.
    pub fn parentsWithKind(self: *CommitBuilder, hashes: []const Hash, kind: ParentKind) !void {
        for (hashes) |h| try self.parentWithKind(h, kind);
    }

    /// Declare a logical dependency on `change_id` — this commit is
    /// part of a stack that requires whatever commit currently
    /// represents that logical change. Unlike `.parent()`, this does
    /// *not* need that change's current `Hash`: `change_id` stays valid
    /// across amends/rebases of the depended-upon commit. See
    /// `commit/dependency.zig`'s doc comment for the full rationale,
    /// and note that resolving `change_id` to a commit, and detecting
    /// dependency cycles across a whole stack, both happen outside this
    /// builder (it only sees one commit's own dependency list).
    pub fn dependsOn(self: *CommitBuilder, change_id: ChangeId) !void {
        try self.dependencies.append(self.alloc, .{ .change_id = change_id });
    }

    /// Add several dependencies at once.
    pub fn dependsOnMany(self: *CommitBuilder, change_ids: []const ChangeId) !void {
        for (change_ids) |cid| try self.dependsOn(cid);
    }

    /// Author identity with an implicit UTC (`+00:00`) timestamp. Use
    /// `.authorWithTz` to record a non-UTC local offset.
    ///
    /// Infallible: a zero offset always resolves to `Timezone.utc` and
    /// can never fail the range check `.authorWithTz` performs, so this
    /// convenience wrapper never needs `try`.
    pub fn author(self: *CommitBuilder, name: []const u8, email: []const u8, timestamp_ms: i64) void {
        self.authorWithTz(name, email, timestamp_ms, 0) catch unreachable;
    }

    /// Author identity plus the UTC offset (minutes) `timestamp_ms` was
    /// recorded in — e.g. `-300` for someone committing from US Eastern.
    /// Fails with `error.InvalidTimezoneOffset` if `tz_offset_minutes`
    /// falls outside the civil range `Timezone` accepts (see
    /// `identity.Timezone.min_offset_minutes` / `.max_offset_minutes`).
    pub fn authorWithTz(
        self: *CommitBuilder,
        name: []const u8,
        email: []const u8,
        timestamp_ms: i64,
        tz_offset_minutes: i16,
    ) !void {
        self.author_info = .{
            .person = PersonInfo.init(name, email),
            .timestamp = .{ .value = timestamp_ms },
            .timezone = try Timezone.init(tz_offset_minutes),
        };
    }

    /// Optional. When not called, the committer defaults to the author
    /// (same person, same timestamp, same tz offset) — matching the
    /// existing serialize-time behavior documented on the commit's
    /// identity. Implicit UTC timestamp; use `.committerWithTz` for a
    /// non-UTC local offset.
    ///
    /// Infallible for the same reason `.author` is — see its doc comment.
    pub fn committer(self: *CommitBuilder, name: []const u8, email: []const u8, timestamp_ms: i64) void {
        self.committerWithTz(name, email, timestamp_ms, 0) catch unreachable;
    }

    /// Committer identity plus the UTC offset (minutes) `timestamp_ms`
    /// was recorded in — e.g. for a CI bot or a cherry-pick applied
    /// somewhere other than where the change was authored. Fails the
    /// same way `.authorWithTz` does for an out-of-range offset.
    pub fn committerWithTz(
        self: *CommitBuilder,
        name: []const u8,
        email: []const u8,
        timestamp_ms: i64,
        tz_offset_minutes: i16,
    ) !void {
        self.committer_info = .{
            .person = PersonInfo.init(name, email),
            .timestamp = .{ .value = timestamp_ms },
            .timezone = try Timezone.init(tz_offset_minutes),
        };
    }

    pub fn intent(self: *CommitBuilder, value: Intent) void {
        self.commit_intent = value;
    }

    /// Optional. Defaults to the author's timestamp when not set.
    pub fn timestamp(self: *CommitBuilder, timestamp_ms: i64) void {
        self.metadata_timestamp_ms = timestamp_ms;
    }

    /// Carry forward a persistent `change_id`, e.g. when amending,
    /// rebasing, or cherry-picking a commit that should still be
    /// recognized as the same logical change. Omit this call for a
    /// brand-new change — `build()` generates a fresh random one.
    /// See `ChangeId`'s doc comment in `commit/metadata.zig`.
    pub fn changeId(self: *CommitBuilder, id: ChangeId) void {
        self.change_id_override = id;
    }

    pub fn label(self: *CommitBuilder, value: []const u8) !void {
        try self.labels.append(self.alloc, value);
    }

    pub fn labelsFrom(self: *CommitBuilder, values: []const []const u8) !void {
        try self.labels.appendSlice(self.alloc, values);
    }

    pub fn title(self: *CommitBuilder, value: []const u8) void {
        self.title_text = value;
    }

    pub fn body(self: *CommitBuilder, value: []const u8) void {
        self.body_text = value;
    }

    /// Optional. Defaults to UTF-8.
    pub fn encoding(self: *CommitBuilder, value: Encoding) void {
        self.msg_encoding = value;
    }

    pub fn trailer(self: *CommitBuilder, key: []const u8, value: []const u8) !void {
        try self.trailers.append(self.alloc, .{ .key = key, .value = value });
    }

    /// Populate a builder from a `CommitRequest` in one call: author,
    /// optional committer, intent, title, body, encoding, change_id,
    /// labels, trailers, dependencies — every setter this file knows how
    /// to call, called correctly and in the right order (including the
    /// committer/label/trailer defaulting rules documented on the
    /// individual setters above).
    ///
    /// This exists so that callers assembling a commit from an
    /// options-style struct (`Repository.commit`, a CLI command, ...)
    /// don't each re-derive this same sequence themselves — they supply
    /// a `CommitRequest` and, separately, whatever snapshot/parent
    /// resolution is specific to them. Prefer `CommitBuilder.fromRequest`
    /// when the snapshot root is already resolved at construction time.
    pub fn applyRequest(self: *CommitBuilder, request: CommitRequest) !void {
        try self.authorWithTz(
            request.author_name,
            request.author_email,
            request.author_timestamp_ms,
            request.author_tz_offset_minutes,
        );
        if (request.committer_name) |name| {
            try self.committerWithTz(
                name,
                request.committer_email orelse request.author_email,
                request.committer_timestamp_ms orelse request.author_timestamp_ms,
                request.committer_tz_offset_minutes orelse request.author_tz_offset_minutes,
            );
        }
        self.intent(request.intent);
        self.title(request.title);
        self.body(request.body);
        self.encoding(request.encoding);
        if (request.change_id) |cid| self.changeId(cid);
        if (request.labels.len > 0) try self.labelsFrom(request.labels);
        for (request.trailers) |t| try self.trailer(t.key, t.value);
        if (request.dependencies.len > 0) try self.dependsOnMany(request.dependencies);
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
        const meta_ts = self.metadata_timestamp_ms orelse author_info.timestamp.resolve();
        const change_id = self.change_id_override orelse metadata.generateChangeId();

        return .{
            .snapshot = self.snapshot_root,
            .parents = self.parents.items,
            .dependencies = self.dependencies.items,
            .identity = if (self.committer_info) |committer_info|
                CommitSignaturesInfo.init(author_info, committer_info)
            else
                CommitSignaturesInfo.soloAuthor(author_info),
            .metadata = .{
                .change_id = change_id,
                .timestamp_ms = meta_ts,
                .intent = commit_intent,
                .labels = self.labels.items,
            },
            .message = .{
                .title = title_text,
                .body = self.body_text,
                .encoding = self.msg_encoding,
                .trailers = self.trailers.items,
            },
        };
    }

    /// Assemble and persist the commit. Note: a `change_id` is generated
    /// fresh (randomly) on every call unless `.changeId()` was used, so
    /// two otherwise-identical builders will *not* produce the same hash
    /// unless they're both given the same explicit `change_id` — this is
    /// intentional (each is a genuinely new logical change unless told
    /// otherwise).
    pub fn write(self: *const CommitBuilder, store: *const Store) !Hash {
        const info = try self.build();
        return writeCommit(self.alloc, store, info);
    }
};
