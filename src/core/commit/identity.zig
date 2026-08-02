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

    /// `tz_offset_minutes` outside +/-1440 (a full day either way) —
    /// generous on purpose (real-world offsets top out around -12:00/
    /// +14:00) since this only needs to catch corrupt/garbage values,
    /// not enforce the IANA tz database. Also returned by `parseTzOffset`
    /// for malformed "+HHMM"/"-HHMM" text.
    InvalidTimezoneOffset,
};

const illegal_name_chars = [_]u8{ '\n', '\r', '<', '>', '\x00' };
const illegal_email_chars = [_]u8{ ' ', '\t', '\n', '\r', '<', '>', '\x00' };

/// Magnitude bound for `tz_offset_minutes`, in either direction — see
/// `IdentityError.InvalidTimezoneOffset` for why this is deliberately
/// generous rather than IANA-accurate.
pub const max_tz_offset_minutes: i16 = 1440;

fn validateTzOffset(tz_offset_minutes: i16) IdentityError!void {
    if (tz_offset_minutes < -max_tz_offset_minutes or tz_offset_minutes > max_tz_offset_minutes)
        return error.InvalidTimezoneOffset;
}

/// Format a UTC offset the way git/RFC 2822 dates do: sign + zero-padded
/// HHMM, e.g. `-300` -> "-0500", `330` -> "+0530", `0` -> "+0000".
/// `buf` must be at least 5 bytes; the returned slice aliases it.
pub fn formatTzOffset(tz_offset_minutes: i16, buf: *[5]u8) []const u8 {
    const sign: u8 = if (tz_offset_minutes < 0) '-' else '+';
    const abs_minutes: u16 = @intCast(@abs(tz_offset_minutes));
    const hours = abs_minutes / 60;
    const mins = abs_minutes % 60;

    buf[0] = sign;
    _ = std.fmt.bufPrint(buf[1..5], "{d:0>2}{d:0>2}", .{ hours, mins }) catch unreachable;
    return buf[0..5];
}

/// Parse a git/RFC 2822-style UTC offset ("+0530", "-0500") back into
/// minutes east of UTC. Rejects anything not exactly 5 bytes
/// (sign + 2-digit hours + 2-digit minutes), a minutes field >= 60, or a
/// result outside `validateTzOffset`'s bounds.
pub fn parseTzOffset(text: []const u8) IdentityError!i16 {
    if (text.len != 5) return error.InvalidTimezoneOffset;

    const sign: i16 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.InvalidTimezoneOffset,
    };

    const hours = std.fmt.parseInt(i16, text[1..3], 10) catch return error.InvalidTimezoneOffset;
    const mins = std.fmt.parseInt(i16, text[3..5], 10) catch return error.InvalidTimezoneOffset;
    if (mins >= 60) return error.InvalidTimezoneOffset;

    const total = sign * (hours * 60 + mins);
    try validateTzOffset(total);
    return total;
}

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

        if (std.mem.indexOfAny(u8, trimmed_name, &illegal_name_chars) != null)
            return error.NameContainsIllegalCharacters;

        if (std.mem.indexOfAny(u8, trimmed_email, &illegal_email_chars) != null)
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

// TimestampedIdentityInfo — IdentityInfo + an explicit wall-clock timestamp
// and the UTC offset that timestamp was recorded in.
//
// Used for both author and committer.  timestamp_ms == 0 means "use the
// current wall-clock time at serialisation" — the same convention as
// CommitMetadataInfo so callers never have to think about it.
//
// tz_offset_minutes captures local context (work-hours, geographic
// origin) that the absolute `timestamp_ms` alone throws away. It
// defaults to 0 (UTC) and is independent per author/committer, since a
// committer (e.g. a CI bot, or someone applying a patch/cherry-pick)
// may not share the author's timezone

pub const TimestampedIdentityInfo = struct {
    name: []const u8,
    email: []const u8,

    /// Unix milliseconds.  0 = auto-fill at serialisation time.
    timestamp_ms: i64 = 0,

    /// Minutes east of UTC (negative = west), e.g. -300 for US Eastern
    /// Standard Time, 345 for Nepal Time. 0 = UTC, and is also what
    /// callers get if they never set this
    ///! NOTE: it does not mean "unknown"
    tz_offset_minutes: i16 = 0,

    pub fn validate(self: TimestampedIdentityInfo) IdentityError!void {
        const base = IdentityInfo{ .name = self.name, .email = self.email };
        try base.validate();
        try validateTzOffset(self.tz_offset_minutes);
    }

    /// Trimmed name/email plus the resolved (never-0) timestamp and the
    /// tz offset — the one place `serialize` and `Identity.initDupe`
    /// both derive their data from, so the trimming and auto-fill rules
    /// can't drift apart
    fn trimmed(self: TimestampedIdentityInfo) struct {
        name: []const u8,
        email: []const u8,
        timestamp_ms: i64,
        tz_offset_minutes: i16,
    } {
        const base = (IdentityInfo{ .name = self.name, .email = self.email }).trimmed();
        return .{
            .name = base.name,
            .email = base.email,
            .timestamp_ms = wire.resolveTimestampMs(self.timestamp_ms),
            .tz_offset_minutes = self.tz_offset_minutes,
        };
    }

    /// This offset formatted git-style ("+0530", "-0500"). `buf` must be
    /// at least 5 bytes; the returned slice aliases it.
    pub fn formattedTzOffset(self: TimestampedIdentityInfo, buf: *[5]u8) []const u8 {
        return formatTzOffset(self.tz_offset_minutes, buf);
    }

    pub fn serialize(self: TimestampedIdentityInfo, writer: anytype) !void {
        try self.validate();

        const t = self.trimmed();
        try wire.writeBytes(u16, writer, t.name);
        try wire.writeBytes(u16, writer, t.email);
        try writer.writeInt(i64, t.timestamp_ms, .little);
        try writer.writeInt(i16, t.tz_offset_minutes, .little);
    }
};

pub const Identity = struct {
    name: []u8,
    email: []u8,

    /// Resolved Unix milliseconds (never 0 after deserialisation).
    timestamp_ms: i64,

    /// Minutes east of UTC that `timestamp_ms` was recorded in.
    tz_offset_minutes: i16,

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

        return .{
            .name = name,
            .email = email,
            .timestamp_ms = t.timestamp_ms,
            .tz_offset_minutes = t.tz_offset_minutes,
        };
    }

    /// This identity's timestamp offset formatted git-style ("+0530",
    /// "-0500"). `buf` must be at least 5 bytes; the returned slice
    /// aliases it.
    pub fn formattedTzOffset(self: Identity, buf: *[5]u8) []const u8 {
        return formatTzOffset(self.tz_offset_minutes, buf);
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Identity {
        const name = try wire.readBytesAlloc(u16, alloc, reader);
        errdefer alloc.free(name);

        const email = try wire.readBytesAlloc(u16, alloc, reader);
        errdefer alloc.free(email);

        const ts = try reader.takeInt(i64, .little);
        const tz_offset_minutes = try reader.takeInt(i16, .little);
        try validateTzOffset(tz_offset_minutes);

        const info = IdentityInfo{ .name = name, .email = email };
        try info.validate();

        return .{ .name = name, .email = email, .timestamp_ms = ts, .tz_offset_minutes = tz_offset_minutes };
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
// author bytes (tz offset included, since a mirrored committer is the same
// person at the same moment, in the same place). This keeps the wire format
// symmetric and reader code simple

pub const CommitIdentityInfo = struct {
    author: TimestampedIdentityInfo,

    /// null = committer is the same person as the author at the same time.
    /// Supply a value for cherry-picks, rebases, patch imports, etc.
    committer: ?TimestampedIdentityInfo = null,

    pub fn validate(self: CommitIdentityInfo) IdentityError!void {
        try self.author.validate();
        if (self.committer) |c| try c.validate();
    }

    /// The committer that will actually be serialized: `committer` if one
    /// was supplied, otherwise `author`. Pulled out as its own accessor —
    /// rather than left as an inline `orelse` only `serialize` could see —
    /// so any other caller needing "who's the effective committer here"
    /// (a CLI `--committer` override check, a future commit-building
    /// helper, etc.) derives it the same way `serialize` does, instead of
    /// re-deriving the same default and risking it drifting out of sync.
    pub fn effectiveCommitter(self: CommitIdentityInfo) TimestampedIdentityInfo {
        return self.committer orelse self.author;
    }

    pub fn serialize(self: CommitIdentityInfo, writer: anytype) !void {
        try self.validate();

        try self.author.serialize(writer);
        try self.effectiveCommitter().serialize(writer);
    }
};

pub const CommitIdentity = struct {
    author: Identity,
    committer: Identity,

    /// True when author and committer are the same person with the same
    /// timestamp — useful for display ("authored and committed by …").
    /// Deliberately doesn't compare `tz_offset_minutes`: two identical
    /// identities recorded with a different (but equivalent) UTC offset
    /// notation are still "the same person, same moment".
    pub fn isAuthorCommitter(self: CommitIdentity) bool {
        return std.mem.eql(u8, self.author.name, self.committer.name) and
            std.mem.eql(u8, self.author.email, self.committer.email) and
            self.author.timestamp_ms == self.committer.timestamp_ms;
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !CommitIdentity {
        var author = try Identity.deserialize(alloc, reader);
        errdefer author.deinit(alloc);

        var committer = try Identity.deserialize(alloc, reader);
        errdefer committer.deinit(alloc);

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

test "TimestampedIdentityInfo validation - tz offset bounds" {
    const ok = TimestampedIdentityInfo{ .name = "A", .email = "a@b.com", .tz_offset_minutes = 840 };
    try ok.validate();

    const too_far_east = TimestampedIdentityInfo{ .name = "A", .email = "a@b.com", .tz_offset_minutes = 1441 };
    try std.testing.expectError(error.InvalidTimezoneOffset, too_far_east.validate());

    const too_far_west = TimestampedIdentityInfo{ .name = "A", .email = "a@b.com", .tz_offset_minutes = -1441 };
    try std.testing.expectError(error.InvalidTimezoneOffset, too_far_west.validate());
}

test "TimestampedIdentityInfo serialization includes timestamp and tz offset" {
    const alloc = std.testing.allocator;
    const info = TimestampedIdentityInfo{
        .name = "Ada Lovelace",
        .email = "ada@nodus.dev",
        .timestamp_ms = 1_700_000_000_000,
        .tz_offset_minutes = -300, // US Eastern
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    // name len(u16) + name + email len(u16) + email + ts(i64) + tz(i16)
    // = 2+12+2+13+8+2 = 39
    try std.testing.expectEqual(@as(usize, 39), buf.items.len);

    // Timestamp bytes (little-endian i64), then tz offset (little-endian i16)
    const ts_bytes = buf.items[29..37];
    const ts = std.mem.readInt(i64, ts_bytes[0..8], .little);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), ts);

    const tz_bytes = buf.items[37..39];
    const tz = std.mem.readInt(i16, tz_bytes[0..2], .little);
    try std.testing.expectEqual(@as(i16, -300), tz);
}

test "formatTzOffset produces git-style +HHMM/-HHMM" {
    var buf: [5]u8 = undefined;

    try std.testing.expectEqualStrings("+0000", formatTzOffset(0, &buf));
    try std.testing.expectEqualStrings("-0500", formatTzOffset(-300, &buf));
    try std.testing.expectEqualStrings("+0530", formatTzOffset(330, &buf));
    try std.testing.expectEqualStrings("+1400", formatTzOffset(840, &buf));
    try std.testing.expectEqualStrings("-1200", formatTzOffset(-720, &buf));
}

test "parseTzOffset inverts formatTzOffset" {
    const samples = [_]i16{ 0, -300, 330, 840, -720, 60, -60, 1440, -1440 };
    var buf: [5]u8 = undefined;

    for (samples) |mins| {
        const text = formatTzOffset(mins, &buf);
        const parsed = try parseTzOffset(text);
        try std.testing.expectEqual(mins, parsed);
    }
}

test "parseTzOffset rejects malformed input" {
    try std.testing.expectError(error.InvalidTimezoneOffset, parseTzOffset("530"));
    try std.testing.expectError(error.InvalidTimezoneOffset, parseTzOffset("+053"));
    try std.testing.expectError(error.InvalidTimezoneOffset, parseTzOffset("053000"));
    try std.testing.expectError(error.InvalidTimezoneOffset, parseTzOffset("*0530"));
    try std.testing.expectError(error.InvalidTimezoneOffset, parseTzOffset("+0X30"));
    try std.testing.expectError(error.InvalidTimezoneOffset, parseTzOffset("+0560")); // minutes >= 60
}

test "Identity initDupe - timestamp auto-fill, tz offset passthrough" {
    const alloc = std.testing.allocator;
    const before = std.time.milliTimestamp();
    var id = try Identity.initDupe(alloc, .{
        .name = "Test",
        .email = "t@test.dev",
        .timestamp_ms = 0,
        .tz_offset_minutes = 60,
    });
    defer id.deinit(alloc);
    const after = std.time.milliTimestamp();

    try std.testing.expect(id.timestamp_ms >= before);
    try std.testing.expect(id.timestamp_ms <= after);
    try std.testing.expectEqual(@as(i16, 60), id.tz_offset_minutes);
}

test "Identity deserialization round-trip" {
    const alloc = std.testing.allocator;

    const info = TimestampedIdentityInfo{
        .name = "User",
        .email = "user@email.com",
        .timestamp_ms = 99_999,
        .tz_offset_minutes = 330, // India Standard Time
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
    try std.testing.expectEqual(@as(i16, 330), id.tz_offset_minutes);

    var tz_buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("+0530", id.formattedTzOffset(&tz_buf));
}

test "Identity deserialize rejects an out-of-range tz offset" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try wire.writeBytes(u16, buf.writer(alloc), "User");
    try wire.writeBytes(u16, buf.writer(alloc), "user@email.com");
    try buf.writer(alloc).writeInt(i64, 1_000, .little);
    try buf.writer(alloc).writeInt(i16, 2000, .little); // out of range

    var mock_reader = MockReader{ .buffer = buf.items };
    try std.testing.expectError(error.InvalidTimezoneOffset, Identity.deserialize(alloc, &mock_reader));
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

    // effectiveCommitter() mirrors author before serialization even happens
    try std.testing.expectEqualStrings("Bruce Wayne", info.effectiveCommitter().name);

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

test "CommitIdentityInfo - distinct committer with its own tz offset" {
    const alloc = std.testing.allocator;

    const info = CommitIdentityInfo{
        .author = .{
            .name = "Alan Turing",
            .email = "alan@lab.net",
            .timestamp_ms = 1_000,
            .tz_offset_minutes = 60, // BST
        },
        .committer = .{
            .name = "Nodus Bot",
            .email = "bot@nodus.dev",
            .timestamp_ms = 2_000,
            .tz_offset_minutes = 0, // UTC
        },
    };

    // effectiveCommitter() returns the explicit committer, not the author
    try std.testing.expectEqualStrings("Nodus Bot", info.effectiveCommitter().name);

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
    try std.testing.expectEqual(@as(i16, 60), ids.author.tz_offset_minutes);
    try std.testing.expectEqual(@as(i16, 0), ids.committer.tz_offset_minutes);
    try std.testing.expect(!ids.isAuthorCommitter());
}
