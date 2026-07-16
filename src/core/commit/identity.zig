const std = @import("std");
const wire = @import("wire.zig");
const MockReader = @import("testing.zig").MockReader;

pub const IdentityError = error{
    EmptyName,
    EmptyEmail,

    NameTooLong,
    EmailTooLong,

    NameContainsIllegalCharacters,
    EmailContainsIllegalCharacters,

    MissingEmailAtSign,
    InvalidEmailBounds,
};

pub const IdentityInfo = struct {
    name: []const u8,
    email: []const u8,

    pub fn validate(self: IdentityInfo) IdentityError!void {
        const trimmed_name = std.mem.trim(u8, self.name, " \t\r\n");
        const trimmed_email = std.mem.trim(u8, self.email, " \t\r\n");

        if (trimmed_name.len == 0) return error.EmptyName;
        if (trimmed_email.len == 0) return error.EmptyEmail;

        if (trimmed_name.len > std.math.maxInt(u16)) return error.NameTooLong;
        if (trimmed_email.len > std.math.maxInt(u16)) return error.EmailTooLong;

        const illegal_name_chars = &[_]u8{ '\n', '\r', '<', '>', '\x00' };
        if (std.mem.indexOfAny(u8, trimmed_name, illegal_name_chars) != null)
            return error.NameContainsIllegalCharacters;

        const illegal_email_chars = &[_]u8{ ' ', '\t', '\n', '\r', '<', '>', '\x00' };
        if (std.mem.indexOfAny(u8, trimmed_email, illegal_email_chars) != null)
            return error.EmailContainsIllegalCharacters;

        const at_idx = std.mem.indexOfScalar(u8, trimmed_email, '@') orelse
            return error.MissingEmailAtSign;

        if (at_idx == 0 or at_idx == trimmed_email.len - 1)
            return error.InvalidEmailBounds;

        if (std.mem.indexOfScalar(u8, trimmed_email[at_idx + 1 ..], '@') != null)
            return error.EmailContainsIllegalCharacters;
    }

    /// Trimmed name/email, computed once so `serialize` and any future
    /// caller don't each re-derive it
    fn trimmed(self: IdentityInfo) struct { name: []const u8, email: []const u8 } {
        return .{
            .name = std.mem.trim(u8, self.name, " \t\r\n"),
            .email = std.mem.trim(u8, self.email, " \t\r\n"),
        };
    }

    pub fn serialize(self: IdentityInfo, writer: anytype) !void {
        try self.validate();

        const t = self.trimmed();
        try wire.writeBytes(u16, writer, t.name);
        try wire.writeBytes(u16, writer, t.email);
    }
};

// TimestampedIdentityInfo — IdentityInfo + an explicit wall-clock timestamp.
//
// Used for both author and committer.  timestamp_ms == 0 means "use the
// current wall-clock time at serialisation" — the same convention as
// CommitMetadataInfo so callers never have to think about it.

pub const TimestampedIdentityInfo = struct {
    name: []const u8,
    email: []const u8,

    /// Unix milliseconds.  0 = auto-fill at serialisation time.
    timestamp_ms: i64 = 0,

    pub fn validate(self: TimestampedIdentityInfo) IdentityError!void {
        const base = IdentityInfo{ .name = self.name, .email = self.email };
        try base.validate();
    }

    /// Trimmed name/email plus the resolved (never-0) timestamp — the one
    /// place `serialize` and `Identity.initDupe` both derive their data
    /// from, so the trimming and auto-fill rules can't drift apart
    fn trimmed(self: TimestampedIdentityInfo) struct { name: []const u8, email: []const u8, timestamp_ms: i64 } {
        const base = (IdentityInfo{ .name = self.name, .email = self.email }).trimmed();
        return .{
            .name = base.name,
            .email = base.email,
            .timestamp_ms = wire.resolveTimestampMs(self.timestamp_ms),
        };
    }

    pub fn serialize(self: TimestampedIdentityInfo, writer: anytype) !void {
        try self.validate();

        const t = self.trimmed();
        try wire.writeBytes(u16, writer, t.name);
        try wire.writeBytes(u16, writer, t.email);
        try writer.writeInt(i64, t.timestamp_ms, .little);
    }
};

pub const Identity = struct {
    name: []u8,
    email: []u8,

    /// Resolved Unix milliseconds (never 0 after deserialisation).
    timestamp_ms: i64,

    pub fn initDupe(
        alloc: std.mem.Allocator,
        info: TimestampedIdentityInfo,
    ) !Identity {
        try info.validate();

        const t = info.trimmed();

        const name = try alloc.dupe(u8, t.name);
        errdefer alloc.free(name);

        const email = try alloc.dupe(u8, t.email);
        errdefer alloc.free(email);

        return .{ .name = name, .email = email, .timestamp_ms = t.timestamp_ms };
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Identity {
        const name = try wire.readBytesAlloc(u16, alloc, reader);
        errdefer alloc.free(name);

        const email = try wire.readBytesAlloc(u16, alloc, reader);
        errdefer alloc.free(email);

        const ts = try reader.takeInt(i64, .little);

        const info = IdentityInfo{ .name = name, .email = email };
        try info.validate();

        return .{ .name = name, .email = email, .timestamp_ms = ts };
    }

    pub fn deinit(self: *Identity, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.email);
        self.* = undefined;
    }
};

// CommitIdentityInfo — groups author + committer at the CommitInfo level.
//
// committer defaults to null, which means "same as author".  The serialiser
// always writes both fields; when committer is null it writes a copy of the
// author bytes.  This keeps the wire format symmetric and reader code simple.

pub const CommitIdentityInfo = struct {
    author: TimestampedIdentityInfo,

    /// null = committer is the same person as the author at the same time.
    /// Supply a value for cherry-picks, rebases, patch imports, etc.
    committer: ?TimestampedIdentityInfo = null,

    pub fn validate(self: CommitIdentityInfo) IdentityError!void {
        try self.author.validate();
        if (self.committer) |c| try c.validate();
    }

    pub fn serialize(self: CommitIdentityInfo, writer: anytype) !void {
        try self.validate();

        try self.author.serialize(writer);

        const effective_committer = self.committer orelse self.author;
        try effective_committer.serialize(writer);
    }
};

pub const CommitIdentity = struct {
    author: Identity,
    committer: Identity,

    /// True when author and committer are the same person with the same
    /// timestamp — useful for display ("authored and committed by …").
    pub fn isAuthorCommitter(self: CommitIdentity) bool {
        return std.mem.eql(u8, self.author.name, self.committer.name) and
            std.mem.eql(u8, self.author.email, self.committer.email) and
            self.author.timestamp_ms == self.committer.timestamp_ms;
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !CommitIdentity {
        const author = try Identity.deserialize(alloc, reader);
        errdefer @constCast(&author).deinit(alloc);

        const committer = try Identity.deserialize(alloc, reader);
        errdefer @constCast(&committer).deinit(alloc);

        return .{ .author = author, .committer = committer };
    }

    pub fn deinit(self: *CommitIdentity, alloc: std.mem.Allocator) void {
        self.author.deinit(alloc);
        self.committer.deinit(alloc);
        self.* = undefined;
    }
};

test "IdentityInfo validation - success cases" {
    const info = IdentityInfo{
        .name = "  Bruce Wayne  ",
        .email = "bruce@example.com\n",
    };

    // Should validate successfully and handle trimming implicitly
    try info.validate();
}

test "IdentityInfo validation - empty names and emails" {
    const empty_name = IdentityInfo{ .name = "   ", .email = "test@example.com" };
    try std.testing.expectError(error.EmptyName, empty_name.validate());

    const empty_email = IdentityInfo{ .name = "Valid Name", .email = "\t\r\n" };
    try std.testing.expectError(error.EmptyEmail, empty_email.validate());
}

test "IdentityInfo validation - illegal characters in name" {
    const bad_names = [_][]const u8{
        "Name\nWithNewline",
        "Name\rWithCarriage",
        "<TagBuilder>",
        "Null\x00Byte",
    };

    for (bad_names) |bad_name| {
        const info = IdentityInfo{ .name = bad_name, .email = "test@example.com" };
        try std.testing.expectError(error.NameContainsIllegalCharacters, info.validate());
    }
}

test "IdentityInfo validation - illegal characters in email" {
    const bad_emails = [_][]const u8{
        "spaces are@illegal.com",
        "tabs\tare@illegal.com",
        "newlines\nare@illegal.com",
        "<brackets>@illegal.com",
        "null\x00byte@illegal.com",
    };

    for (bad_emails) |bad_email| {
        const info = IdentityInfo{ .name = "Valid Name", .email = bad_email };
        try std.testing.expectError(error.EmailContainsIllegalCharacters, info.validate());
    }
}

test "IdentityInfo validation - email bounds and at-sign checks" {
    // Missing @ sign
    const missing_at = IdentityInfo{ .name = "Valid Name", .email = "no-at-sign.com" };
    try std.testing.expectError(error.MissingEmailAtSign, missing_at.validate());

    // Starts with @
    const starts_with_at = IdentityInfo{ .name = "Valid Name", .email = "@missing-local.com" };
    try std.testing.expectError(error.InvalidEmailBounds, starts_with_at.validate());

    // Ends with @
    const ends_with_at = IdentityInfo{ .name = "Valid Name", .email = "missing-domain@" };
    try std.testing.expectError(error.InvalidEmailBounds, ends_with_at.validate());

    // Multiple @ signs
    const multiple_at = IdentityInfo{ .name = "Valid Name", .email = "user@domain@extra.com" };
    try std.testing.expectError(error.EmailContainsIllegalCharacters, multiple_at.validate());
}

test "IdentityInfo serialization" {
    const info = IdentityInfo{
        .name = "  Nodus Dev  ",
        .email = "dev@nodus.internal  ",
    };
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try info.serialize(buf.writer(alloc));

    // Expected:
    // u16 len of "Nodus Dev" (9) -> \x09\x00
    // "Nodus Dev"
    // u16 len of "dev@nodus.internal" (18) -> \x12\x00
    // "dev@nodus.internal"
    const expected_slice = "\x09\x00Nodus Dev\x12\x00dev@nodus.internal";
    try std.testing.expectEqualSlices(u8, expected_slice, buf.items);
}

test "TimestampedIdentityInfo serialization includes timestamp" {
    const alloc = std.testing.allocator;
    const info = TimestampedIdentityInfo{
        .name = "Ada Lovelace",
        .email = "ada@nodus.dev",
        .timestamp_ms = 1_700_000_000_000,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    // name len(u16) + name + email len(u16) + email + ts(i64) = 2+12+2+13+8 = 37
    try std.testing.expectEqual(@as(usize, 37), buf.items.len);

    // Timestamp bytes at the end (little-endian i64)
    const ts_bytes = buf.items[29..37];
    const ts = std.mem.readInt(i64, ts_bytes[0..8], .little);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), ts);
}

test "Identity initDupe - timestamp auto-fill" {
    const alloc = std.testing.allocator;
    const before = std.time.milliTimestamp();
    var id = try Identity.initDupe(alloc, .{
        .name = "Test",
        .email = "t@test.dev",
        .timestamp_ms = 0,
    });
    defer id.deinit(alloc);
    const after = std.time.milliTimestamp();

    try std.testing.expect(id.timestamp_ms >= before);
    try std.testing.expect(id.timestamp_ms <= after);
}

test "Identity deserialization round-trip" {
    const alloc = std.testing.allocator;

    const info = TimestampedIdentityInfo{
        .name = "User",
        .email = "user@email.com",
        .timestamp_ms = 99_999,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    var mock_reader = MockReader{ .buffer = buf.items };
    var id = try Identity.deserialize(alloc, &mock_reader);
    defer id.deinit(alloc);

    try std.testing.expectEqualStrings("User", id.name);
    try std.testing.expectEqualStrings("user@email.com", id.email);
    try std.testing.expectEqual(@as(i64, 99_999), id.timestamp_ms);
}

test "CommitIdentityInfo - committer defaults to author" {
    const alloc = std.testing.allocator;

    const info = CommitIdentityInfo{
        .author = .{
            .name = "Bruce Wayne",
            .email = "bruce@wayne.corp",
            .timestamp_ms = 1_000,
        },
        // committer intentionally omitted
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    var mock_reader = MockReader{ .buffer = buf.items };
    var ids = try CommitIdentity.deserialize(alloc, &mock_reader);
    defer ids.deinit(alloc);

    try std.testing.expectEqualStrings("Bruce Wayne", ids.author.name);
    // committer mirrors author when not supplied
    try std.testing.expectEqualStrings("Bruce Wayne", ids.committer.name);
    try std.testing.expectEqualStrings("bruce@wayne.corp", ids.committer.email);
    try std.testing.expect(ids.isAuthorCommitter());
}

test "CommitIdentityInfo - distinct committer" {
    const alloc = std.testing.allocator;

    const info = CommitIdentityInfo{
        .author = .{
            .name = "Alan Turing",
            .email = "alan@lab.net",
            .timestamp_ms = 1_000,
        },
        .committer = .{
            .name = "Nodus Bot",
            .email = "bot@nodus.dev",
            .timestamp_ms = 2_000,
        },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    var mock_reader = MockReader{ .buffer = buf.items };
    var ids = try CommitIdentity.deserialize(alloc, &mock_reader);
    defer ids.deinit(alloc);

    try std.testing.expectEqualStrings("Alan Turing", ids.author.name);
    try std.testing.expectEqualStrings("Nodus Bot", ids.committer.name);
    try std.testing.expectEqual(@as(i64, 1_000), ids.author.timestamp_ms);
    try std.testing.expectEqual(@as(i64, 2_000), ids.committer.timestamp_ms);
    try std.testing.expect(!ids.isAuthorCommitter());
}
