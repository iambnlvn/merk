const std = @import("std");
const wire = @import("wire.zig");
const MockReader = @import("testing.zig").MockReader;

/// The wire tag for an `Intent`. Kept as its own enum (rather than
/// deriving straight from `Intent`'s payload-carrying union) so the
/// on-disk numbering is pinned explicitly instead of following whatever
/// order `Intent`'s variants happen to be declared in — the two are
/// kept in sync by `Intent.tag` and the mapping in `Intent.deserialize`
/// below, and this is the
/// only place that needs editing to reserve a new fixed tag.
pub const IntentTag = enum(u8) {
    feature = 0,
    fix = 1,
    refactor = 2,
    docs = 3,
    @"test" = 4,
    performance = 5,
    security = 6,
    build = 7,
    ci = 8,
    release = 9,
    chore = 10,
    /// A caller-supplied name, carried as a length-prefixed string
    /// immediately after this tag byte. See `Intent.custom`.
    custom = 11,
};

/// Validation failures for a `.custom` intent's name.
pub const IntentError = error{
    EmptyCustomIntent,
    CustomIntentTooLong,
    CustomIntentContainsIllegalCharacters,
};

const illegal_custom_intent_chars = [_]u8{ '\n', '\r', '\t', '\x00' };

/// High-level semantic classification for a commit.
///
/// Most commits fit one of the built-in kinds below, which is why they
/// stay first-class enum-shaped variants (no allocation, trivially
/// copyable, cheap to switch on). But projects with their own release
/// taxonomy — a `hotfix` category, a `vendor` label for third-party
/// imports, whatever a team's changelog generator expects — aren't
/// forced to force-fit one of these, or to fork this type: `.custom`
/// carries an arbitrary caller-supplied name across the wire instead.
///
/// `.custom` names are validated (non-empty, bounded length, no control
/// characters) exactly like `.custom("chore")` would be an odd thing to
/// write, but nothing here stops it — merk doesn't attempt to detect or
/// reject a custom name that happens to collide with a built-in one.
pub const Intent = union(enum) {
    feature,
    fix,
    refactor,
    docs,
    @"test",
    performance,
    security,
    build,
    ci,
    release,
    chore,
    /// An arbitrary, project-defined intent name. Not deduplicated or
    /// interned against the built-in kinds above — see the type's doc
    /// comment.
    custom: []const u8,

    /// Construct a `.custom` intent. Doesn't validate eagerly — like
    /// the rest of merk's `*Info` construction, that happens once, at
    /// `.validate()`/`.serialize()` time.
    pub fn initCustom(custom_name: []const u8) Intent {
        return .{ .custom = custom_name };
    }

    /// This intent's identifier text: the variant name itself for a
    /// built-in kind (`"feature"`, `"chore"`, ...), or the caller's
    /// string for `.custom`. Useful for display, filtering, or release
    /// automation that wants a single string regardless of which kind
    /// of intent this is, without a switch at every call site.
    pub fn name(self: Intent) []const u8 {
        return switch (self) {
            .custom => |n| n,
            else => @tagName(self),
        };
    }

    /// Same intent — same built-in kind, or the same `.custom` name.
    pub fn eql(self: Intent, other: Intent) bool {
        return switch (self) {
            .custom => |a| switch (other) {
                .custom => |b| std.mem.eql(u8, a, b),
                else => false,
            },
            else => switch (other) {
                .custom => false,
                else => std.meta.activeTag(self) == std.meta.activeTag(other),
            },
        };
    }

    /// Trimmed custom name, computed once so `validate` and `serialize`
    /// don't each re-derive it. Not meaningful for non-`.custom` kinds.
    fn trimmedCustom(self: Intent) []const u8 {
        return std.mem.trim(u8, self.custom, " \t\r\n");
    }

    pub fn validate(self: Intent) IntentError!void {
        if (self != .custom) return;

        const trimmed = self.trimmedCustom();
        if (trimmed.len == 0) return error.EmptyCustomIntent;
        if (trimmed.len > std.math.maxInt(u16)) return error.CustomIntentTooLong;
        if (std.mem.indexOfAny(u8, trimmed, &illegal_custom_intent_chars) != null)
            return error.CustomIntentContainsIllegalCharacters;
    }

    fn tag(self: Intent) IntentTag {
        return switch (self) {
            .feature => .feature,
            .fix => .fix,
            .refactor => .refactor,
            .docs => .docs,
            .@"test" => .@"test",
            .performance => .performance,
            .security => .security,
            .build => .build,
            .ci => .ci,
            .release => .release,
            .chore => .chore,
            .custom => .custom,
        };
    }

    pub fn serialize(self: Intent, writer: anytype) !void {
        try self.validate();

        try writer.writeByte(@intFromEnum(self.tag()));
        if (self == .custom) {
            try wire.writeBytes(u16, writer, self.trimmedCustom());
        }
    }

    /// Caller frees the result with `.deinit(alloc)` — a no-op for
    /// every built-in kind, and the only variant that actually owns
    /// anything is `.custom`.
    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Intent {
        const raw_tag = try reader.takeByte();
        const t = std.meta.intToEnum(IntentTag, raw_tag) catch return error.CorruptCommit;

        if (t == .custom) {
            return .{ .custom = try wire.readBytesAlloc(u16, alloc, reader) };
        }

        return switch (t) {
            .feature => .feature,
            .fix => .fix,
            .refactor => .refactor,
            .docs => .docs,
            .@"test" => .@"test",
            .performance => .performance,
            .security => .security,
            .build => .build,
            .ci => .ci,
            .release => .release,
            .chore => .chore,
            .custom => unreachable,
        };
    }

    /// Free the `.custom` name, if this is one. A no-op for every
    /// built-in kind — safe to call unconditionally.
    pub fn deinit(self: *Intent, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .custom => |n| alloc.free(n),
            else => {},
        }
    }
};

/// A persistent identifier for one *logical* change, as distinct from
/// the commit hash that identifies one particular *version* of it.
///
/// Git only has commit hashes, so a commit rewritten by `rebase`,
/// `commit --amend`, or a cherry-pick becomes a brand-new, unrelated
/// object — there is no durable way to say "this is still the same
/// change, just moved". `change_id` fixes that, it's generated once,
/// when a change is first created, and every
/// caller that rewrites that change (amend, rebase, cherry-pick) is
/// expected to copy the *same* `change_id` forward via
/// `CommitBuilder.changeId`, even though `Commit.hash` changes every
/// time. Two commits with the same `change_id` are different snapshots
/// of the same evolving change; two commits with different `change_id`s
/// are unrelated, even if one happens to be a parent of the other.
///
/// 16 random bytes (not content-derived) — deliberately UUID-shaped
/// rather than reusing the 32-byte content `Hash` type, so a `change_id`
/// can never be mistaken for — or accidentally compared against — an
/// object hash.
pub const ChangeId = [16]u8;

/// A fresh, random change_id for a brand-new logical change. Callers
/// continuing an existing change (amend/rebase/cherry-pick) should
/// instead carry the original commit's `change_id` forward — see the
/// doc comment on `ChangeId`.
pub fn generateChangeId() ChangeId {
    var id: ChangeId = undefined;
    std.crypto.random.bytes(&id);
    return id;
}

pub const CommitMetadataInfo = struct {
    /// Persistent identifier for the logical change this commit
    /// belongs to. See `ChangeId`'s doc comment. Defaults to all-zero,
    /// which is only a sensible value for tests that don't care about
    /// change tracking — real commits should always get one from
    /// `generateChangeId()` or a carried-forward prior value; see
    /// `CommitBuilder.build`, which fills this in automatically when
    /// not explicitly set via `.changeId()`.
    change_id: ChangeId = [_]u8{0} ** 16,

    /// Unix timestamp in milliseconds.
    ///
    /// 0 = use current wall-clock time.
    timestamp_ms: i64 = 0,

    /// High-level semantic classification. See `Intent`'s doc comment —
    /// `.custom` names are validated the same way names/labels
    /// elsewhere in merk are (non-empty, bounded, no control chars).
    intent: Intent = .chore,

    /// Optional labels used for grouping,
    /// filtering, and release automation.
    labels: []const []const u8 = &.{},

    pub fn validate(
        self: CommitMetadataInfo,
    ) !void {
        try self.intent.validate();

        if (self.labels.len > std.math.maxInt(u16))
            return error.TooManyLabels;

        for (self.labels) |label| {
            if (label.len > std.math.maxInt(u16))
                return error.LabelTooLong;
        }
    }
    pub fn serialize(
        self: CommitMetadataInfo,
        writer: anytype,
    ) !void {
        try self.validate();

        try writer.writeAll(&self.change_id);

        const ts = wire.resolveTimestampMs(self.timestamp_ms);
        try writer.writeInt(i64, ts, .little);
        try self.intent.serialize(writer);
        try wire.writeStringArray(u16, u16, writer, self.labels);
    }

    pub fn deserialize(
        alloc: std.mem.Allocator,
        reader: anytype,
    ) !CommitMetadata {
        const change_id_bytes = try reader.take(16);
        var change_id: ChangeId = undefined;
        @memcpy(&change_id, change_id_bytes);

        const timestamp_ms = try reader.takeInt(i64, .little);

        var commit_intent = try Intent.deserialize(alloc, reader);
        errdefer commit_intent.deinit(alloc);

        const labels = try wire.readStringArrayAlloc(u16, u16, alloc, reader);

        return .{
            .change_id = change_id,
            .timestamp_ms = timestamp_ms,
            .intent = commit_intent,
            .labels = labels,
        };
    }
};

pub const CommitMetadata = struct {
    /// Persistent identifier for the logical change this commit
    /// belongs to (see `ChangeId`). Fixed-size, no allocation.
    change_id: ChangeId,

    /// Creation timestamp.
    timestamp_ms: i64,

    /// Semantic classification. Owned only in the `.custom` case — see
    /// `Intent.deinit`, which this struct's `deinit` calls unconditionally.
    intent: Intent,

    /// Owned labels.
    labels: [][]u8,

    pub fn deinit(
        self: *CommitMetadata,
        alloc: std.mem.Allocator,
    ) void {
        self.intent.deinit(alloc);

        for (self.labels) |label| {
            alloc.free(label);
        }

        alloc.free(self.labels);

        self.* = undefined;
    }
};

test "CommitMetadataInfo validation - label boundaries" {
    const allocator = std.testing.allocator;

    // Label too long error boundary check (> 65535 bytes)
    const huge_label = try allocator.alloc(u8, 65536);
    defer allocator.free(huge_label);
    @memset(huge_label, 'a');

    const labels_too_long = [_][]const u8{huge_label};
    const info_bad_label = CommitMetadataInfo{
        .labels = &labels_too_long,
    };
    try std.testing.expectError(error.LabelTooLong, info_bad_label.validate());

    // Too many labels error boundary check (> 65535 elements)
    const huge_label_array = try allocator.alloc([]const u8, 65536);
    defer allocator.free(huge_label_array);
    @memset(huge_label_array, &[_]u8{});

    const info_too_many_labels = CommitMetadataInfo{
        .labels = huge_label_array,
    };
    try std.testing.expectError(error.TooManyLabels, info_too_many_labels.validate());
}

test "generateChangeId produces distinct 16-byte ids" {
    const a = generateChangeId();
    const b = generateChangeId();
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "CommitMetadataInfo serialization layout" {
    const allocator = std.testing.allocator;

    const labels = [_][]const u8{ "feat", "v2" };
    const change_id: ChangeId = [_]u8{0xAB} ** 16;
    const info = CommitMetadataInfo{
        .change_id = change_id,
        .timestamp_ms = 1782259200000,
        .intent = .feature,
        .labels = &labels,
    };

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    // Call serialize as defined in CommitMetadata namespace using 0.15 allocator-aware writer
    try CommitMetadataInfo.serialize(info, payload.writer(allocator));

    // change_id (16 bytes) is written first.
    try std.testing.expectEqualSlices(u8, &change_id, payload.items[0..16]);

    // [8 Bytes: Timestamp i64 LE]       -> \x00\x30\xed\xf6\x9e\x01\x00\x00
    // [1 Byte: Intent tag u8 (.feature = 0)] -> \x00
    // [2 Bytes: Label Count u16 LE (2)] -> \x02\x00
    // [2 Bytes: Label[0] Len u16 LE (4)] -> \x04\x00
    // [4 Bytes: Label[0] String Content] -> "feat"
    // [2 Bytes: Label[1] Len u16 LE (2)] -> \x02\x00
    // [2 Bytes: Label[1] String Content] -> "v2"
    const expected_rest = "\x00\x30\xed\xf6\x9e\x01\x00\x00\x00\x02\x00\x04\x00feat\x02\x00v2";
    try std.testing.expectEqualSlices(u8, expected_rest, payload.items[16..]);
}

test "CommitMetadata deserialization - successful lifecycle" {
    const allocator = std.testing.allocator;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    const target_change_id: ChangeId = [_]u8{0xCD} ** 16;
    const target_ts: i64 = 987654321;
    const target_intent: Intent = .fix;
    const label_text = "critical-bug";

    // Build binary input manually using the payload writer
    try payload.writer(allocator).writeAll(&target_change_id);
    try payload.writer(allocator).writeInt(i64, target_ts, .little);
    try payload.writer(allocator).writeByte(@intFromEnum(IntentTag.fix));
    try payload.writer(allocator).writeInt(u16, 1, .little); // 1 label
    try payload.writer(allocator).writeInt(u16, @intCast(label_text.len), .little);
    try payload.writer(allocator).writeAll(label_text);

    var mock_reader = MockReader{ .buffer = payload.items };

    var metadata = try CommitMetadataInfo.deserialize(allocator, &mock_reader);
    defer metadata.deinit(allocator);

    // Validate memory allocations and property reconstruction
    try std.testing.expectEqualSlices(u8, &target_change_id, &metadata.change_id);
    try std.testing.expectEqual(target_ts, metadata.timestamp_ms);
    try std.testing.expect(target_intent.eql(metadata.intent));
    try std.testing.expectEqual(@as(usize, 1), metadata.labels.len);
    try std.testing.expectEqualStrings(label_text, metadata.labels[0]);
}

test "CommitMetadata deserialization - corrupt enum safety check" {
    const allocator = std.testing.allocator;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.writer(allocator).writeAll(&([_]u8{0} ** 16)); // change_id
    try payload.writer(allocator).writeInt(i64, 12345, .little);
    try payload.writer(allocator).writeByte(99); // 99 is completely out-of-bounds for IntentTag
    try payload.writer(allocator).writeInt(u16, 0, .little);

    var mock_reader = MockReader{ .buffer = payload.items };

    // Should break gracefully inside catch block and return error.CorruptCommit
    try std.testing.expectError(error.CorruptCommit, CommitMetadataInfo.deserialize(allocator, &mock_reader));
}

test "Intent.custom round-trips through serialize/deserialize" {
    const allocator = std.testing.allocator;

    const info = CommitMetadataInfo{
        .intent = Intent.initCustom("hotfix"),
    };

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try info.serialize(payload.writer(allocator));

    // tag(1) + name_len(2) + name(6)
    try std.testing.expectEqual(@as(usize, 16 + 8 + 1 + 2 + 6 + 2), payload.items.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(IntentTag.custom)), payload.items[24]);

    var mock_reader = MockReader{ .buffer = payload.items };
    var metadata = try CommitMetadataInfo.deserialize(allocator, &mock_reader);
    defer metadata.deinit(allocator);

    try std.testing.expect(metadata.intent == .custom);
    try std.testing.expectEqualStrings("hotfix", metadata.intent.name());
    try std.testing.expect(Intent.initCustom("hotfix").eql(metadata.intent));
}

test "Intent.custom trims whitespace before validating and serializing" {
    const allocator = std.testing.allocator;

    const info = CommitMetadataInfo{ .intent = Intent.initCustom("  vendor-import  ") };

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try info.serialize(payload.writer(allocator));

    var mock_reader = MockReader{ .buffer = payload.items };
    var metadata = try CommitMetadataInfo.deserialize(allocator, &mock_reader);
    defer metadata.deinit(allocator);

    try std.testing.expectEqualStrings("vendor-import", metadata.intent.name());
}

test "Intent.custom rejects empty, oversized, and control-character names" {
    try std.testing.expectError(
        error.EmptyCustomIntent,
        (CommitMetadataInfo{ .intent = Intent.initCustom("   ") }).validate(),
    );

    const allocator = std.testing.allocator;
    const huge_name = try allocator.alloc(u8, 65536);
    defer allocator.free(huge_name);
    @memset(huge_name, 'a');
    try std.testing.expectError(
        error.CustomIntentTooLong,
        (CommitMetadataInfo{ .intent = Intent.initCustom(huge_name) }).validate(),
    );

    try std.testing.expectError(
        error.CustomIntentContainsIllegalCharacters,
        (CommitMetadataInfo{ .intent = Intent.initCustom("multi\nline") }).validate(),
    );
}

test "Intent.name and Intent.eql cover built-in and custom kinds" {
    const feature: Intent = .feature;
    const chore: Intent = .chore;
    const fix: Intent = .fix;

    try std.testing.expectEqualStrings("feature", feature.name());
    try std.testing.expectEqualStrings("chore", chore.name());
    try std.testing.expectEqualStrings("hotfix", Intent.initCustom("hotfix").name());

    try std.testing.expect(feature.eql(.feature));
    try std.testing.expect(!feature.eql(fix));
    try std.testing.expect(Intent.initCustom("hotfix").eql(Intent.initCustom("hotfix")));
    try std.testing.expect(!Intent.initCustom("hotfix").eql(Intent.initCustom("coldfix")));
    // A custom name is never considered equal to a built-in kind, even
    // if it happens to share the same text.
    try std.testing.expect(!Intent.initCustom("chore").eql(.chore));
}
