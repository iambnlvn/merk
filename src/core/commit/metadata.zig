const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wire = @import("wire.zig");
const testing_io = @import("testing.zig");

/// Wire tag for an `Intent`. Variant tags are pinned explicitly so that
/// on-disk ordering stays consistent regardless of union field sequence.
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
    /// A caller-supplied intent tag name carried as a length-prefixed string.
    custom = 11,
};

/// Validation failures for custom intent names.
pub const IntentError = error{
    EmptyCustomIntent,
    CustomIntentTooLong,
    CustomIntentContainsIllegalCharacters,
};

/// Validation failures for commit metadata as a whole.
pub const MetadataError = error{
    TooManyLabels,
    LabelTooLong,
    EmptyLabel,
    LabelContainsIllegalCharacters,
    DuplicateLabel,
    LabelPayloadTooLarge,
};

const illegal_custom_intent_chars = [_]u8{ '\n', '\r', '\t', '\x00' };
const illegal_label_chars = [_]u8{ '\n', '\r', '\t', '\x00' };

/// Upper bound on the total decoded bytes across all labels for a single
/// commit. This is enforced independently of the per-label and per-count
/// limits below: a payload could satisfy both of those individually
/// (e.g. 65535 labels of 65535 bytes each) while still requesting an
/// unreasonable amount of memory during deserialization. Capping the sum
/// gives deserialize() a cheap way to reject hostile/corrupt input before
/// most of the allocation work happens.
pub const max_total_label_bytes: usize = 1 << 20; // 1 MiB

/// High-level semantic classification for a commit.
///
/// Built-in kinds carry zero allocation overhead. Projects with custom commit
/// taxonomy can utilize `.custom` to carry arbitrary names across the wire.
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

    pub fn initCustom(custom_name: []const u8) Intent {
        return .{ .custom = custom_name };
    }

    /// Parses a string into an `Intent`. Matches against built-in tags first
    /// (case-insensitively), falling back to `.custom(trimmed)` if no
    /// built-in tag matches.
    pub fn fromString(str: []const u8) Intent {
        const trimmed = std.mem.trim(u8, str, " \t\r\n");
        inline for (std.meta.fields(IntentTag)) |field| {
            if (field.value == @intFromEnum(IntentTag.custom)) continue;
            if (std.ascii.eqlIgnoreCase(trimmed, field.name)) {
                return @field(Intent, field.name);
            }
        }
        return initCustom(trimmed);
    }

    /// Display string representing this intent: standard tag name or custom string.
    pub fn name(self: Intent) []const u8 {
        return switch (self) {
            .custom => |n| n,
            else => @tagName(self),
        };
    }

    /// Short prefix in the style used by conventional-commit tooling
    /// (e.g. `.feature` -> "feat", `.performance` -> "perf"). Falls back to
    /// `name()` for kinds without a conventional-commit abbreviation,
    /// including `.custom`.
    pub fn conventionalPrefix(self: Intent) []const u8 {
        return switch (self) {
            .feature => "feat",
            .fix => "fix",
            .refactor => "refactor",
            .docs => "docs",
            .@"test" => "test",
            .performance => "perf",
            .security => "security",
            .build => "build",
            .ci => "ci",
            .release => "release",
            .chore => "chore",
            .custom => |n| n,
        };
    }

    /// True if this is a caller-supplied intent rather than a built-in kind.
    pub fn isCustom(self: Intent) bool {
        return self == .custom;
    }

    /// True if this is one of the built-in intent kinds.
    pub fn isBuiltin(self: Intent) bool {
        return self != .custom;
    }

    /// Equality comparison for two intents.
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

    /// Returns an owned copy of this intent, duplicating the custom string
    /// (if any) with `alloc`. The result must be `deinit`'d independently
    /// of `self`.
    pub fn clone(self: Intent, alloc: Allocator) Allocator.Error!Intent {
        return switch (self) {
            .custom => |n| .{ .custom = try alloc.dupe(u8, n) },
            else => self,
        };
    }

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

    pub fn serialize(self: Intent, writer: *Io.Writer) !void {
        try self.validate();

        try writer.writeByte(@intFromEnum(self.tag()));
        if (self == .custom) {
            try wire.writeBytes(u16, writer, self.trimmedCustom());
        }
    }

    pub fn deserialize(alloc: Allocator, reader: *Io.Reader) !Intent {
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

    pub fn deinit(self: *Intent, alloc: Allocator) void {
        switch (self.*) {
            .custom => |n| alloc.free(n),
            else => {},
        }
    }
};

/// A persistent identifier for a single logical change across rewrites (amend, rebase).
pub const ChangeId = [16]u8;

/// Generates a fresh 16-byte random ChangeId.
pub fn generateChangeId() ChangeId {
    var id: ChangeId = undefined;
    std.crypto.random.bytes(&id);
    return id;
}

/// Formats a `ChangeId` as 32 lowercase hex characters.
pub fn changeIdToHex(id: ChangeId) [32]u8 {
    var buf: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (id, 0..) |byte, i| {
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return buf;
}

/// Parses a 32-character hex string (as produced by `changeIdToHex`) into a
/// `ChangeId`. Accepts upper- or lower-case hex digits.
pub const ChangeIdParseError = error{InvalidChangeIdHex};

pub fn changeIdFromHex(hex: []const u8) ChangeIdParseError!ChangeId {
    if (hex.len != 32) return error.InvalidChangeIdHex;

    var id: ChangeId = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = std.fmt.charToDigit(hex[i * 2], 16) catch return error.InvalidChangeIdHex;
        const lo = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch return error.InvalidChangeIdHex;
        id[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return id;
}

pub fn changeIdEql(a: ChangeId, b: ChangeId) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Validates a single label: non-empty once trimmed, within the on-wire
/// length limit, and free of control characters that would make it awkward
/// to render or round-trip.
fn validateLabel(label: []const u8) MetadataError!void {
    const trimmed = std.mem.trim(u8, label, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyLabel;
    if (label.len > std.math.maxInt(u16)) return error.LabelTooLong;
    if (std.mem.indexOfAny(u8, label, &illegal_label_chars) != null)
        return error.LabelContainsIllegalCharacters;
}

pub const CommitMetadataInfo = struct {
    change_id: ChangeId = [_]u8{0} ** 16,
    timestamp_ms: i64 = 0,
    intent: Intent = .chore,
    labels: []const []const u8 = &.{},

    pub fn validate(self: CommitMetadataInfo) !void {
        try self.intent.validate();

        if (self.labels.len > std.math.maxInt(u16))
            return error.TooManyLabels;

        var total_bytes: usize = 0;
        for (self.labels) |label| {
            try validateLabel(label);
            total_bytes += label.len;
        }
        if (total_bytes > max_total_label_bytes)
            return error.LabelPayloadTooLarge;

        // O(n^2) duplicate check. Label lists are expected to be small
        // (bounded well under u16 in practice), so this trades a bit of
        // work for not requiring an allocator in validate().
        for (self.labels, 0..) |label, i| {
            for (self.labels[i + 1 ..]) |other| {
                if (std.mem.eql(u8, label, other)) return error.DuplicateLabel;
            }
        }
    }

    pub fn serialize(self: CommitMetadataInfo, writer: *Io.Writer) !void {
        try self.validate();

        try writer.writeAll(&self.change_id);

        const ts = wire.resolveTimestampMs(self.timestamp_ms);
        try writer.writeInt(i64, ts, .little);

        try self.intent.serialize(writer);
        try wire.writeStringArray(u16, u16, writer, self.labels);
    }

    pub fn deserialize(alloc: Allocator, reader: *Io.Reader) !CommitMetadata {
        var change_id: ChangeId = undefined;
        try reader.readSliceAll(&change_id);

        const timestamp_ms = try reader.takeInt(i64, .little);

        var commit_intent = try Intent.deserialize(alloc, reader);
        errdefer commit_intent.deinit(alloc);

        const labels = try wire.readStringArrayAlloc(u16, u16, alloc, reader);
        errdefer {
            for (labels) |label| alloc.free(label);
            alloc.free(labels);
        }

        var total_bytes: usize = 0;
        for (labels) |label| total_bytes += label.len;
        if (total_bytes > max_total_label_bytes)
            return error.LabelPayloadTooLarge;

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
    labels: [][]u8,

    pub fn deinit(self: *CommitMetadata, alloc: Allocator) void {
        self.intent.deinit(alloc);

        for (self.labels) |label| {
            alloc.free(label);
        }

        alloc.free(self.labels);
        self.* = undefined;
    }

    /// Structural equality: same change id, timestamp, intent, and label
    /// set (order-sensitive — labels are compared positionally).
    pub fn eql(self: CommitMetadata, other: CommitMetadata) bool {
        if (!changeIdEql(self.change_id, other.change_id)) return false;
        if (self.timestamp_ms != other.timestamp_ms) return false;
        if (!self.intent.eql(other.intent)) return false;
        if (self.labels.len != other.labels.len) return false;
        for (self.labels, other.labels) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        return true;
    }

    /// Returns a deep, independently-owned copy of this metadata. The
    /// result must be `deinit`'d independently of `self`.
    pub fn clone(self: CommitMetadata, alloc: Allocator) Allocator.Error!CommitMetadata {
        var cloned_intent = try self.intent.clone(alloc);
        errdefer cloned_intent.deinit(alloc);

        const cloned_labels = try alloc.alloc([]u8, self.labels.len);
        var filled: usize = 0;
        errdefer {
            for (cloned_labels[0..filled]) |l| alloc.free(l);
            alloc.free(cloned_labels);
        }
        for (self.labels, 0..) |label, i| {
            cloned_labels[i] = try alloc.dupe(u8, label);
            filled += 1;
        }

        return .{
            .change_id = self.change_id,
            .timestamp_ms = self.timestamp_ms,
            .intent = cloned_intent,
            .labels = cloned_labels,
        };
    }
};

test "Intent.fromString parses built-in tags and custom fallbacks" {
    try testing.expect(Intent.fromString("feature") == .feature);
    try testing.expect(Intent.fromString("  fix  ") == .fix);
    try testing.expect(Intent.fromString("chore") == .chore);

    const custom = Intent.fromString("hotfix");
    try testing.expect(custom == .custom);
    try testing.expectEqualStrings("hotfix", custom.name());
}

test "Intent.fromString is case-insensitive for built-in tags" {
    try testing.expect(Intent.fromString("Feature") == .feature);
    try testing.expect(Intent.fromString("FIX") == .fix);
    try testing.expect(Intent.fromString("ReFaCtOr") == .refactor);

    // Still falls back to custom for genuinely unknown names, preserving
    // the caller's casing.
    const custom = Intent.fromString("HotFix");
    try testing.expect(custom == .custom);
    try testing.expectEqualStrings("HotFix", custom.name());
}

test "Intent.conventionalPrefix maps built-ins to conventional-commit prefixes" {
    const feature: Intent = .feature;
    const fix: Intent = .fix;
    const perf: Intent = .performance;
    try testing.expectEqualStrings("feat", feature.conventionalPrefix());
    try testing.expectEqualStrings("fix", fix.conventionalPrefix());
    try testing.expectEqualStrings("perf", perf.conventionalPrefix());
    try testing.expectEqualStrings("hotfix", Intent.initCustom("hotfix").conventionalPrefix());
}

test "Intent.isCustom / isBuiltin" {
    try testing.expect(Intent.initCustom("hotfix").isCustom());
    try testing.expect(!Intent.initCustom("hotfix").isBuiltin());
    const feature: Intent = .feature;
    try testing.expect(feature.isBuiltin());
    try testing.expect(!feature.isCustom());
}

test "Intent.clone duplicates custom string independently" {
    const allocator = std.testing.allocator;

    const original_buf = try allocator.dupe(u8, "hotfix");
    defer allocator.free(original_buf);

    var original = Intent.initCustom(original_buf);
    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try testing.expect(original.eql(cloned));
    try testing.expect(cloned.custom.ptr != original_buf.ptr);

    // Mutating the clone's backing storage independence: freeing original's
    // buffer separately must not affect the clone (already proven by
    // pointer distinctness above; this just documents the intent).
    _ = &original;
}

test "Intent.validate rejects empty, oversized, and illegal custom intents" {
    try testing.expectError(error.EmptyCustomIntent, Intent.initCustom("   ").validate());
    try testing.expectError(error.EmptyCustomIntent, Intent.initCustom("").validate());

    const huge = try testing.allocator.alloc(u8, std.math.maxInt(u16) + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'a');
    try testing.expectError(error.CustomIntentTooLong, Intent.initCustom(huge).validate());

    try testing.expectError(
        error.CustomIntentContainsIllegalCharacters,
        Intent.initCustom("bad\nname").validate(),
    );
    try testing.expectError(
        error.CustomIntentContainsIllegalCharacters,
        Intent.initCustom("bad\x00name").validate(),
    );

    // Sanity: a normal custom intent validates cleanly.
    try Intent.initCustom("hotfix").validate();
}

test "Intent.eql covers custom-vs-custom and custom-vs-builtin branches" {
    const feature: Intent = .feature;
    try testing.expect(feature.eql(.feature));
    try testing.expect(!feature.eql(.fix));

    const a = Intent.initCustom("hotfix");
    const b = Intent.initCustom("hotfix");
    const c = Intent.initCustom("coldfix");
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));

    try testing.expect(!a.eql(feature));
    try testing.expect(!feature.eql(a));
}

test "CommitMetadataInfo validation - label boundaries" {
    const allocator = std.testing.allocator;

    const huge_label = try allocator.alloc(u8, 65536);
    defer allocator.free(huge_label);
    @memset(huge_label, 'a');

    const labels_too_long = [_][]const u8{huge_label};
    const info_bad_label = CommitMetadataInfo{
        .labels = &labels_too_long,
    };
    try std.testing.expectError(error.LabelTooLong, info_bad_label.validate());

    const huge_label_array = try allocator.alloc([]const u8, 65536);
    defer allocator.free(huge_label_array);
    @memset(huge_label_array, &[_]u8{});

    const info_too_many_labels = CommitMetadataInfo{
        .labels = huge_label_array,
    };
    try std.testing.expectError(error.TooManyLabels, info_too_many_labels.validate());
}

test "CommitMetadataInfo validation - empty, illegal-char, and duplicate labels" {
    const empty_label = [_][]const u8{"   "};
    try std.testing.expectError(
        error.EmptyLabel,
        (CommitMetadataInfo{ .labels = &empty_label }).validate(),
    );

    const illegal_label = [_][]const u8{"bad\nlabel"};
    try std.testing.expectError(
        error.LabelContainsIllegalCharacters,
        (CommitMetadataInfo{ .labels = &illegal_label }).validate(),
    );

    const dup_labels = [_][]const u8{ "v2", "v2" };
    try std.testing.expectError(
        error.DuplicateLabel,
        (CommitMetadataInfo{ .labels = &dup_labels }).validate(),
    );

    const ok_labels = [_][]const u8{ "feat", "v2" };
    try (CommitMetadataInfo{ .labels = &ok_labels }).validate();
}

test "CommitMetadataInfo validation - total label payload cap" {
    const allocator = std.testing.allocator;

    // Each label individually satisfies the per-label (u16) length limit,
    // but enough of them together exceed max_total_label_bytes. This is
    // deliberately a case the per-label and per-count checks alone would
    // both pass.
    const label_len: usize = std.math.maxInt(u16);
    const needed = (max_total_label_bytes / label_len) + 2;

    const label_storage = try allocator.alloc(u8, label_len);
    defer allocator.free(label_storage);
    @memset(label_storage, 'a');

    const labels = try allocator.alloc([]const u8, needed);
    defer allocator.free(labels);
    for (labels) |*l| l.* = label_storage;

    try std.testing.expectError(
        error.LabelPayloadTooLarge,
        (CommitMetadataInfo{ .labels = labels }).validate(),
    );
}

test "generateChangeId produces distinct 16-byte ids" {
    const a = generateChangeId();
    const b = generateChangeId();
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "changeIdToHex / changeIdFromHex round-trip" {
    const id: ChangeId = [_]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };
    const hex = changeIdToHex(id);
    try testing.expectEqualStrings("00112233445566778899aabbccddeeff", &hex);

    const parsed = try changeIdFromHex(&hex);
    try testing.expect(changeIdEql(id, parsed));

    // Upper-case input should parse identically.
    const upper_hex = "00112233445566778899AABBCCDDEEFF";
    const parsed_upper = try changeIdFromHex(upper_hex);
    try testing.expect(changeIdEql(id, parsed_upper));

    try testing.expectError(error.InvalidChangeIdHex, changeIdFromHex("too-short"));
    try testing.expectError(error.InvalidChangeIdHex, changeIdFromHex("zz112233445566778899aabbccddeeff"[0..32]));
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

    var sink = testing_io.ByteSink.init(allocator);
    defer sink.deinit();

    try info.serialize(sink.writer());
    const payload = sink.bytes();

    try testing.expectEqualSlices(u8, &change_id, payload[0..16]);

    const expected_rest = "\x00\x30\xed\xf6\x9e\x01\x00\x00\x00\x02\x00\x04\x00feat\x02\x00v2";
    try testing.expectEqualSlices(u8, expected_rest, payload[16..]);
}

test "CommitMetadata deserialization - successful lifecycle" {
    const allocator = std.testing.allocator;

    var sink = testing_io.ByteSink.init(allocator);
    defer sink.deinit();

    const target_change_id: ChangeId = [_]u8{0xCD} ** 16;
    const target_ts: i64 = 987654321;
    const target_intent: Intent = .fix;
    const label_text = "critical-bug";

    const w = sink.writer();
    try w.writeAll(&target_change_id);
    try w.writeInt(i64, target_ts, .little);
    try w.writeByte(@intFromEnum(IntentTag.fix));
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, @intCast(label_text.len), .little);
    try w.writeAll(label_text);

    var reader = testing_io.fixedReader(sink.bytes());
    var meta = try CommitMetadataInfo.deserialize(allocator, &reader);
    defer meta.deinit(allocator);

    try testing.expectEqualSlices(u8, &target_change_id, &meta.change_id);
    try testing.expectEqual(target_ts, meta.timestamp_ms);
    try testing.expect(target_intent.eql(meta.intent));
    try testing.expectEqual(@as(usize, 1), meta.labels.len);
    try testing.expectEqualStrings(label_text, meta.labels[0]);
}

test "CommitMetadata deserialization - corrupt enum safety check" {
    const allocator = std.testing.allocator;

    var sink = testing_io.ByteSink.init(allocator);
    defer sink.deinit();

    const w = sink.writer();
    try w.writeAll(&([_]u8{0} ** 16));
    try w.writeInt(i64, 12345, .little);
    try w.writeByte(99); // 99 is out-of-bounds for IntentTag
    try w.writeInt(u16, 0, .little);

    var reader = testing_io.fixedReader(sink.bytes());
    try testing.expectError(error.CorruptCommit, CommitMetadataInfo.deserialize(allocator, &reader));
}

test "CommitMetadataInfo serialize -> deserialize round trip" {
    const allocator = std.testing.allocator;

    const labels = [_][]const u8{ "feat", "v2", "release-candidate" };
    const original = CommitMetadataInfo{
        .change_id = [_]u8{0x42} ** 16,
        .timestamp_ms = 1_700_000_000_000,
        .intent = .performance,
        .labels = &labels,
    };

    var sink = testing_io.ByteSink.init(allocator);
    defer sink.deinit();
    try original.serialize(sink.writer());

    var reader = testing_io.fixedReader(sink.bytes());
    var round_tripped = try CommitMetadataInfo.deserialize(allocator, &reader);
    defer round_tripped.deinit(allocator);

    try testing.expectEqualSlices(u8, &original.change_id, &round_tripped.change_id);
    try testing.expectEqual(original.timestamp_ms, round_tripped.timestamp_ms);
    try testing.expect(original.intent.eql(round_tripped.intent));
    try testing.expectEqual(labels.len, round_tripped.labels.len);
    for (labels, round_tripped.labels) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }
}

test "CommitMetadataInfo serialize -> deserialize round trip with custom intent" {
    const allocator = std.testing.allocator;

    const labels = [_][]const u8{};
    const original = CommitMetadataInfo{
        .change_id = [_]u8{0x99} ** 16,
        .timestamp_ms = 42,
        .intent = Intent.initCustom("hotfix"),
        .labels = &labels,
    };

    var sink = testing_io.ByteSink.init(allocator);
    defer sink.deinit();
    try original.serialize(sink.writer());

    var reader = testing_io.fixedReader(sink.bytes());
    var round_tripped = try CommitMetadataInfo.deserialize(allocator, &reader);
    defer round_tripped.deinit(allocator);

    try testing.expect(original.intent.eql(round_tripped.intent));
    try testing.expectEqual(@as(usize, 0), round_tripped.labels.len);
}

test "CommitMetadata.eql and clone" {
    const allocator = std.testing.allocator;

    const labels = try allocator.alloc([]u8, 2);
    labels[0] = try allocator.dupe(u8, "feat");
    labels[1] = try allocator.dupe(u8, "v2");

    var original = CommitMetadata{
        .change_id = [_]u8{0x7} ** 16,
        .timestamp_ms = 123,
        .intent = try Intent.initCustom("hotfix").clone(allocator),
        .labels = labels,
    };
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try testing.expect(original.eql(cloned));

    // Independence: freeing/mutating one must not affect the other. We
    // can't literally free `original` mid-test, so instead assert the
    // underlying label buffers are distinct allocations.
    try testing.expect(original.labels[0].ptr != cloned.labels[0].ptr);
    try testing.expect(original.intent.custom.ptr != cloned.intent.custom.ptr);
}

test "CommitMetadataInfo serialization - zero labels" {
    const allocator = std.testing.allocator;

    const info = CommitMetadataInfo{
        .change_id = [_]u8{0x01} ** 16,
        .timestamp_ms = 1,
        .intent = .chore,
        .labels = &.{},
    };

    var sink = testing_io.ByteSink.init(allocator);
    defer sink.deinit();
    try info.serialize(sink.writer());

    var reader = testing_io.fixedReader(sink.bytes());
    var meta = try CommitMetadataInfo.deserialize(allocator, &reader);
    defer meta.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), meta.labels.len);
}
