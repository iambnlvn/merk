const std = @import("std");
const wire = @import("wire.zig");
const MockReader = @import("testing.zig").MockReader;

pub const Intent = enum(u8) {
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
};

pub const CommitMetadataInfo = struct {
    /// Unix timestamp in milliseconds.
    ///
    /// 0 = use current wall-clock time.
    timestamp_ms: i64 = 0,

    /// High-level semantic classification.
    intent: Intent = .chore,

    /// Optional labels used for grouping,
    /// filtering, and release automation.
    labels: []const []const u8 = &.{},

    pub fn validate(
        self: CommitMetadataInfo,
    ) !void {
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

        const ts = wire.resolveTimestampMs(self.timestamp_ms);
        try writer.writeInt(i64, ts, .little);
        try writer.writeByte(@intFromEnum(self.intent));
        try wire.writeStringArray(u16, u16, writer, self.labels);
    }

    pub fn deserialize(
        alloc: std.mem.Allocator,
        reader: anytype,
    ) !CommitMetadata {
        const timestamp_ms = try reader.takeInt(i64, .little);

        const intent = std.meta.intToEnum(
            Intent,
            try reader.takeByte(),
        ) catch return error.CorruptCommit;

        const labels = try wire.readStringArrayAlloc(u16, u16, alloc, reader);

        return .{
            .timestamp_ms = timestamp_ms,
            .intent = intent,
            .labels = labels,
        };
    }
};

pub const CommitMetadata = struct {
    /// Creation timestamp.
    timestamp_ms: i64,

    /// Semantic classification.
    intent: Intent,

    /// Owned labels.
    labels: [][]u8,

    pub fn deinit(
        self: *CommitMetadata,
        alloc: std.mem.Allocator,
    ) void {
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

test "CommitMetadataInfo serialization layout" {
    const allocator = std.testing.allocator;

    const labels = [_][]const u8{ "feat", "v2" };
    const info = CommitMetadataInfo{
        .timestamp_ms = 1782259200000,
        .intent = .feature,
        .labels = &labels,
    };

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    // Call serialize as defined in CommitMetadata namespace using 0.15 allocator-aware writer
    try CommitMetadataInfo.serialize(info, payload.writer(allocator));

    // Expected binary breakdown:
    // [8 Bytes: Timestamp i64 LE]       -> \x00\x30\xed\xf6\x9e\x01\x00\x00
    // [1 Byte: Intent u8 (.feature = 0)] -> \x00
    // [2 Bytes: Label Count u16 LE (2)] -> \x02\x00
    // [2 Bytes: Label[0] Len u16 LE (4)] -> \x04\x00
    // [4 Bytes: Label[0] String Content] -> "feat"
    // [2 Bytes: Label[1] Len u16 LE (2)] -> \x02\x00
    // [2 Bytes: Label[1] String Content] -> "v2"
    const expected = "\x00\x30\xed\xf6\x9e\x01\x00\x00\x00\x02\x00\x04\x00feat\x02\x00v2";
    try std.testing.expectEqualSlices(u8, expected, payload.items);
}

test "CommitMetadata deserialization - successful lifecycle" {
    const allocator = std.testing.allocator;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    const target_ts: i64 = 987654321;
    const target_intent = Intent.fix;
    const label_text = "critical-bug";

    // Build binary input manually using the payload writer
    try payload.writer(allocator).writeInt(i64, target_ts, .little);
    try payload.writer(allocator).writeByte(@intFromEnum(target_intent));
    try payload.writer(allocator).writeInt(u16, 1, .little); // 1 label
    try payload.writer(allocator).writeInt(u16, @intCast(label_text.len), .little);
    try payload.writer(allocator).writeAll(label_text);

    var mock_reader = MockReader{ .buffer = payload.items };

    var metadata = try CommitMetadataInfo.deserialize(allocator, &mock_reader);
    defer metadata.deinit(allocator);

    // Validate memory allocations and property reconstruction
    try std.testing.expectEqual(target_ts, metadata.timestamp_ms);
    try std.testing.expectEqual(target_intent, metadata.intent);
    try std.testing.expectEqual(@as(usize, 1), metadata.labels.len);
    try std.testing.expectEqualStrings(label_text, metadata.labels[0]);
}

test "CommitMetadata deserialization - corrupt enum safety check" {
    const allocator = std.testing.allocator;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.writer(allocator).writeInt(i64, 12345, .little);
    try payload.writer(allocator).writeByte(99); // 99 is completely out-of-bounds for the Intent enum
    try payload.writer(allocator).writeInt(u16, 0, .little);

    var mock_reader = MockReader{ .buffer = payload.items };

    // Should break gracefully inside catch block and return error.CorruptCommit
    try std.testing.expectError(error.CorruptCommit, CommitMetadataInfo.deserialize(allocator, &mock_reader));
}
