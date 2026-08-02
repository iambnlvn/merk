const std = @import("std");
const wire = @import("wire.zig");
const MockReader = @import("testing.zig").MockReader;

/// The validation failures that can occur when a person record's name or
/// email is checked. These errors stay intentionally specific so callers can
/// report exactly why a signature identity was rejected.
pub const PersonError = error{
    EmptyName,
    EmptyEmail,

    NameTooLong,
    EmailTooLong,

    NameContainsIllegalCharacters,
    EmailContainsIllegalCharacters,

    MissingEmailAtSign,
    InvalidEmailBounds,
};

/// Errors tied to interpreting a timezone offset. The offset must stay in the
/// civil range this build supports, and textual forms must parse as a real
/// git-style `+HHMM` or `-HHMM` value.
pub const TimezoneError = error{
    /// The offset is outside the civil range accepted by this build. See
    /// `Timezone.min_offset_minutes` and `Timezone.max_offset_minutes`.
    InvalidTimezoneOffset,
    /// The text was not a valid `+HHMM`/`-HHMM` string, or the wire tag from
    /// `Timezone.deserialize` was not one merk recognizes.
    InvalidTimezoneFormat,
};

/// The full set of validation failures a signature can surface: a person
/// error, a timezone error, or both.
pub const SignatureError = PersonError || TimezoneError;

const illegal_name_chars = [_]u8{ '\n', '\r', '<', '>', '\x00' };
const illegal_email_chars = [_]u8{ ' ', '\t', '\n', '\r', '<', '>', '\x00' };

// Person is the simple "who" half of a signature: a name and an email only.
// It deliberately stays free of any time or timezone semantics so the same
// structure can be reused in blame data, history walking, imported patches,
// merge metadata, and other places where a human identity matters without a
// timestamp attached.

pub const PersonInfo = struct {
    name: []const u8,
    email: []const u8,

    pub fn init(name: []const u8, email: []const u8) PersonInfo {
        return .{ .name = name, .email = email };
    }

    pub fn validate(self: PersonInfo) PersonError!void {
        const t = self.trimmed();

        if (t.name.len == 0) return error.EmptyName;
        if (t.email.len == 0) return error.EmptyEmail;

        if (t.name.len > std.math.maxInt(u16)) return error.NameTooLong;
        if (t.email.len > std.math.maxInt(u16)) return error.EmailTooLong;

        if (std.mem.indexOfAny(u8, t.name, &illegal_name_chars) != null)
            return error.NameContainsIllegalCharacters;

        if (std.mem.indexOfAny(u8, t.email, &illegal_email_chars) != null)
            return error.EmailContainsIllegalCharacters;

        const at_idx = std.mem.indexOfScalar(u8, t.email, '@') orelse
            return error.MissingEmailAtSign;

        if (at_idx == 0 or at_idx == t.email.len - 1)
            return error.InvalidEmailBounds;

        if (std.mem.indexOfScalar(u8, t.email[at_idx + 1 ..], '@') != null)
            return error.EmailContainsIllegalCharacters;
    }

    /// Trimmed name/email, computed once so `serialize` and `Signature`'s
    /// resolution step don't each re-derive it. Not `pub`: callers outside
    /// this file go through `validate`/`serialize`.
    fn trimmed(self: PersonInfo) struct { name: []const u8, email: []const u8 } {
        return .{
            .name = std.mem.trim(u8, self.name, " \t\r\n"),
            .email = std.mem.trim(u8, self.email, " \t\r\n"),
        };
    }

    pub fn serialize(self: PersonInfo, writer: anytype) !void {
        try self.validate();

        const t = self.trimmed();
        try wire.writeBytes(u16, writer, t.name);
        try wire.writeBytes(u16, writer, t.email);
    }
};

/// The owned, validated form of `PersonInfo`. This is what you get after
/// deserializing or duplicating a `PersonInfo`. It is a plain value type, so
/// two signatures can each carry their own `Person` without any hidden
/// aliasing or lifecycle surprises.
pub const Person = struct {
    name: []u8,
    email: []u8,

    pub fn initDupe(alloc: std.mem.Allocator, info: PersonInfo) !Person {
        try info.validate();
        const t = info.trimmed();

        const name = try alloc.dupe(u8, t.name);
        errdefer alloc.free(name);

        const email = try alloc.dupe(u8, t.email);
        errdefer alloc.free(email);

        return .{ .name = name, .email = email };
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Person {
        const name = try wire.readBytesAlloc(u16, alloc, reader);
        errdefer alloc.free(name);

        const email = try wire.readBytesAlloc(u16, alloc, reader);
        errdefer alloc.free(email);

        try (PersonInfo{ .name = name, .email = email }).validate();

        return .{ .name = name, .email = email };
    }

    pub fn deinit(self: *Person, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.email);
        self.* = undefined;
    }

    pub fn eql(self: Person, other: Person) bool {
        return std.mem.eql(u8, self.name, other.name) and std.mem.eql(u8, self.email, other.email);
    }
};

// Timezone describes how local wall-clock time relates to UTC. Instead of
// sprinkling raw `i16` values through every signature-related type, merk keeps
// that meaning explicit and well-typed.
//
// In practice there are three useful states: the common `.utc` case, a real
// validated `.offset`, and `.unknown` for commits that genuinely do not carry
// a meaningful offset. That last case matters for imported or generated
// history where the offset was never recorded — `.unknown` is honest, while
// pretending the offset is UTC would be misleading.

pub const Timezone = union(enum) {
    utc,
    offset: i16,
    unknown,

    /// The lowest accepted civil offset: UTC-12:00 (Baker Island). This is a
    /// tighter rule than a generic +/-1440 check, because it rejects impossible
    /// values such as +18:00 instead of merely saying "more than a day away".
    pub const min_offset_minutes: i16 = -12 * 60;
    /// The highest accepted civil offset: UTC+14:00 (Kiribati / Line Islands).
    pub const max_offset_minutes: i16 = 14 * 60;

    const tag_utc: u8 = 0;
    const tag_offset: u8 = 1;
    const tag_unknown: u8 = 2;

    /// Build a timezone from a raw minutes-east-of-UTC value. Zero is
    /// normalized to `.utc`, so `Timezone.init(0)` and `Timezone.utc` are the
    /// same value and compare equal. That keeps the representation canonical.
    pub fn init(offset_minutes: i16) TimezoneError!Timezone {
        if (offset_minutes == 0) return .utc;
        const tz = Timezone{ .offset = offset_minutes };
        try tz.validate();
        return tz;
    }

    pub fn validate(self: Timezone) TimezoneError!void {
        switch (self) {
            .utc, .unknown => {},
            .offset => |m| {
                if (m < min_offset_minutes or m > max_offset_minutes)
                    return error.InvalidTimezoneOffset;
            },
        }
    }

    /// Return the offset in minutes east of UTC for arithmetic. `.unknown` has
    /// no meaningful numeric offset, so this method returns `0` for it. That
    /// makes the fallback usable in calculations, but callers that need the
    /// semantic distinction should still check `self == .unknown` directly.
    pub fn minutes(self: Timezone) i16 {
        return switch (self) {
            .utc, .unknown => 0,
            .offset => |m| m,
        };
    }

    /// Format the timezone in git/RFC 2822 style as a signed, zero-padded
    /// `HHMM` string such as `-0500`, `+0530`, or `+0000`. If the timezone is
    /// `.unknown`, this returns `null` rather than inventing a fake UTC offset.
    /// The caller supplies a 5-byte buffer whose backing slice is returned.
    pub fn format(self: Timezone, buf: *[5]u8) ?[]const u8 {
        if (self == .unknown) return null;

        const m = self.minutes();
        const sign: u8 = if (m < 0) '-' else '+';
        const abs_minutes: u16 = @intCast(@abs(m));
        const hours = abs_minutes / 60;
        const mins = abs_minutes % 60;

        buf[0] = sign;
        _ = std.fmt.bufPrint(buf[1..5], "{d:0>2}{d:0>2}", .{ hours, mins }) catch unreachable;
        return buf[0..5];
    }

    /// Parse a git/RFC 2822-style timezone string such as `+0530` or `-0500`
    /// into a concrete offset. This never produces `.unknown`, because there is
    /// no text form for "offset unavailable" that can be round-tripped
    /// unambiguously.
    pub fn parse(text: []const u8) TimezoneError!Timezone {
        if (text.len != 5) return error.InvalidTimezoneFormat;

        const sign: i16 = switch (text[0]) {
            '+' => 1,
            '-' => -1,
            else => return error.InvalidTimezoneFormat,
        };

        const hours = std.fmt.parseInt(i16, text[1..3], 10) catch return error.InvalidTimezoneFormat;
        const mins = std.fmt.parseInt(i16, text[3..5], 10) catch return error.InvalidTimezoneFormat;
        if (mins >= 60) return error.InvalidTimezoneFormat;

        return Timezone.init(sign * (hours * 60 + mins));
    }

    pub fn serialize(self: Timezone, writer: anytype) !void {
        const tag: u8 = switch (self) {
            .utc => tag_utc,
            .offset => tag_offset,
            .unknown => tag_unknown,
        };
        try writer.writeByte(tag);
        try writer.writeInt(i16, self.minutes(), .little);
    }

    pub fn deserialize(reader: anytype) !Timezone {
        const tag = try reader.takeByte();
        const raw = try reader.takeInt(i16, .little);

        return switch (tag) {
            tag_utc => .utc,
            tag_offset => try Timezone.init(raw),
            tag_unknown => .unknown,
            else => error.InvalidTimezoneFormat,
        };
    }
};

pub const Timestamp = union(enum) {
    /// Resolve to the current wall-clock time at the moment `resolve()` is
    /// called (i.e. at serialization time).
    now,
    /// An explicit, already-known instant — including, unambiguously,
    /// epoch 0 if that's genuinely what's meant.
    value: i64,

    pub fn resolve(self: Timestamp) i64 {
        return switch (self) {
            // Routed through wire.resolveTimestampMs(0) rather than calling
            // std.time.milliTimestamp() directly, on the assumption that
            // helper is merk's one sanctioned "what time is it" source
            // (and may be mockable in tests elsewhere) — worth confirming
            // against wire.zig if that assumption turns out wrong.
            .now => wire.resolveTimestampMs(0),
            .value => |ms| ms,
        };
    }
};

// A signature ties together a person, a moment in time, and a timezone
// interpretation for that moment. The timezone may be known or genuinely
// unavailable, and the API keeps that distinction explicit.

pub const SignatureInfo = struct {
    person: PersonInfo,
    timestamp: Timestamp = .now,
    timezone: Timezone = .utc,

    pub fn init(person: PersonInfo) SignatureInfo {
        return .{ .person = person };
    }

    pub fn validate(self: SignatureInfo) SignatureError!void {
        try self.person.validate();
        try self.timezone.validate();
    }

    /// Normalize the person fields and resolve the timestamp exactly once.
    /// `serialize` and `Signature.initDupe` both go through this same view,
    /// which keeps their rules consistent.
    fn resolved(self: SignatureInfo) struct {
        name: []const u8,
        email: []const u8,
        timestamp_ms: i64,
        timezone: Timezone,
    } {
        const p = self.person.trimmed();
        return .{
            .name = p.name,
            .email = p.email,
            .timestamp_ms = self.timestamp.resolve(),
            .timezone = self.timezone,
        };
    }

    /// Format this signature's timezone as a git-style offset string, or
    /// return `null` when the offset is `.unknown`. The caller provides a
    /// 5-byte buffer to hold the formatted result.
    pub fn formattedTimezone(self: SignatureInfo, buf: *[5]u8) ?[]const u8 {
        return self.timezone.format(buf);
    }

    pub fn serialize(self: SignatureInfo, writer: anytype) !void {
        try self.validate();

        const r = self.resolved();
        try wire.writeBytes(u16, writer, r.name);
        try wire.writeBytes(u16, writer, r.email);
        try writer.writeInt(i64, r.timestamp_ms, .little);
        try r.timezone.serialize(writer);
    }
};

/// Owned, validated form of `SignatureInfo`.
pub const Signature = struct {
    person: Person,
    timestamp_ms: i64,
    timezone: Timezone,

    pub fn initDupe(alloc: std.mem.Allocator, info: SignatureInfo) !Signature {
        try info.validate();
        const r = info.resolved();

        const person = try Person.initDupe(alloc, .{ .name = r.name, .email = r.email });
        return .{
            .person = person,
            .timestamp_ms = r.timestamp_ms,
            .timezone = r.timezone,
        };
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Signature {
        var person = try Person.deserialize(alloc, reader);
        errdefer person.deinit(alloc);

        const timestamp_ms = try reader.takeInt(i64, .little);
        const timezone = try Timezone.deserialize(reader);

        return .{
            .person = person,
            .timestamp_ms = timestamp_ms,
            .timezone = timezone,
        };
    }

    pub fn deinit(self: *Signature, alloc: std.mem.Allocator) void {
        self.person.deinit(alloc);
        self.* = undefined;
    }

    /// This signature's timezone formatted git-style ("+0530"), or `null`
    /// for `.unknown`. `buf` must be at least 5 bytes.
    pub fn formattedTimezone(self: Signature, buf: *[5]u8) ?[]const u8 {
        return self.timezone.format(buf);
    }

    /// Same person, regardless of when or in what timezone they signed.
    pub fn samePerson(self: Signature, other: Signature) bool {
        return self.person.eql(other.person);
    }

    /// Same moment, regardless of who. Deliberately timestamp-only, not
    /// timezone-aware: two signatures at the same `timestamp_ms` are the
    /// same instant no matter how each one's local offset is notated.
    pub fn sameInstant(self: Signature, other: Signature) bool {
        return self.timestamp_ms == other.timestamp_ms;
    }

    /// Same person, same instant. Ignores timezone notation entirely (see
    /// `sameInstant`) — two identical people/moments recorded with
    /// different-but-equivalent UTC offsets are still "the same signing".
    pub fn eql(self: Signature, other: Signature) bool {
        return self.samePerson(other) and self.sameInstant(other);
    }
};

// `CommitSignatures` is the author/committer pairing for a commit. The
// committer is never optional: callers choose at construction time whether it
// mirrors the author (`.soloAuthor`) or is distinct (`.init`), so every
// `CommitSignaturesInfo` is complete up front rather than filling in a hidden
// default during serialization.

pub const CommitSignaturesInfo = struct {
    author: SignatureInfo,
    committer: SignatureInfo,

    /// Author and committer are different people/moments — cherry-picks,
    /// rebases, patch imports, CI bots committing someone else's change.
    pub fn init(author: SignatureInfo, committer: SignatureInfo) CommitSignaturesInfo {
        return .{ .author = author, .committer = committer };
    }

    /// The common case: one person, committing their own change right now.
    pub fn soloAuthor(author: SignatureInfo) CommitSignaturesInfo {
        return .{ .author = author, .committer = author };
    }

    pub fn validate(self: CommitSignaturesInfo) SignatureError!void {
        try self.author.validate();
        try self.committer.validate();
    }

    pub fn serialize(self: CommitSignaturesInfo, writer: anytype) !void {
        try self.validate();
        try self.author.serialize(writer);
        try self.committer.serialize(writer);
    }
};

pub const CommitSignatures = struct {
    author: Signature,
    committer: Signature,

    /// True when author and committer are the same person at the same
    /// instant — useful for display ("authored and committed by …").
    pub fn isAuthorCommitter(self: CommitSignatures) bool {
        return self.author.eql(self.committer);
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !CommitSignatures {
        var author = try Signature.deserialize(alloc, reader);
        errdefer author.deinit(alloc);

        var committer = try Signature.deserialize(alloc, reader);
        errdefer committer.deinit(alloc);

        return .{ .author = author, .committer = committer };
    }

    pub fn deinit(self: *CommitSignatures, alloc: std.mem.Allocator) void {
        self.author.deinit(alloc);
        self.committer.deinit(alloc);
        self.* = undefined;
    }
};

test "PersonInfo validation - success cases" {
    const info = PersonInfo.init("  Bruce Wayne  ", "bruce@example.com\n");
    try info.validate();
}

test "PersonInfo validation - empty names and emails" {
    const empty_name = PersonInfo.init("   ", "test@example.com");
    try std.testing.expectError(error.EmptyName, empty_name.validate());

    const empty_email = PersonInfo.init("Valid Name", "\t\r\n");
    try std.testing.expectError(error.EmptyEmail, empty_email.validate());
}

test "PersonInfo validation - illegal characters in name" {
    const bad_names = [_][]const u8{
        "Name\nWithNewline",
        "Name\rWithCarriage",
        "<TagBuilder>",
        "Null\x00Byte",
    };

    for (bad_names) |bad_name| {
        const info = PersonInfo.init(bad_name, "test@example.com");
        try std.testing.expectError(error.NameContainsIllegalCharacters, info.validate());
    }
}

test "PersonInfo validation - illegal characters in email" {
    const bad_emails = [_][]const u8{
        "spaces are@illegal.com",
        "tabs\tare@illegal.com",
        "newlines\nare@illegal.com",
        "<brackets>@illegal.com",
        "null\x00byte@illegal.com",
    };

    for (bad_emails) |bad_email| {
        const info = PersonInfo.init("Valid Name", bad_email);
        try std.testing.expectError(error.EmailContainsIllegalCharacters, info.validate());
    }
}

test "PersonInfo validation - email bounds and at-sign checks" {
    try std.testing.expectError(error.MissingEmailAtSign, PersonInfo.init("Valid Name", "no-at-sign.com").validate());
    try std.testing.expectError(error.InvalidEmailBounds, PersonInfo.init("Valid Name", "@missing-local.com").validate());
    try std.testing.expectError(error.InvalidEmailBounds, PersonInfo.init("Valid Name", "missing-domain@").validate());
    try std.testing.expectError(error.EmailContainsIllegalCharacters, PersonInfo.init("Valid Name", "user@domain@extra.com").validate());
}

test "PersonInfo serialization" {
    const info = PersonInfo.init("  Nodus Dev  ", "dev@nodus.internal  ");
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try info.serialize(buf.writer(alloc));

    const expected_slice = "\x09\x00Nodus Dev\x12\x00dev@nodus.internal";
    try std.testing.expectEqualSlices(u8, expected_slice, buf.items);
}

test "Person deserialization round-trip" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try PersonInfo.init("User", "user@email.com").serialize(buf.writer(alloc));

    var mock_reader = MockReader{ .buffer = buf.items };
    var person = try Person.deserialize(alloc, &mock_reader);
    defer person.deinit(alloc);

    try std.testing.expectEqualStrings("User", person.name);
    try std.testing.expectEqualStrings("user@email.com", person.email);
}

test "Person.eql compares name and email only" {
    const alloc = std.testing.allocator;
    var a = try Person.initDupe(alloc, PersonInfo.init("A", "a@b.com"));
    defer a.deinit(alloc);
    var b = try Person.initDupe(alloc, PersonInfo.init("A", "a@b.com"));
    defer b.deinit(alloc);
    var c = try Person.initDupe(alloc, PersonInfo.init("A", "different@b.com"));
    defer c.deinit(alloc);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "Timezone.init collapses zero to .utc" {
    try std.testing.expectEqual(Timezone.utc, try Timezone.init(0));
}

test "Timezone.init rejects offsets outside the civil range" {
    try std.testing.expectEqual(Timezone{ .offset = 840 }, try Timezone.init(840)); // +14:00, valid (Kiribati)
    try std.testing.expectEqual(Timezone{ .offset = -720 }, try Timezone.init(-720)); // -12:00, valid (Baker Island)

    // +18:00 isn't real — the old +/-1440 bound would have let this through
    try std.testing.expectError(error.InvalidTimezoneOffset, Timezone.init(18 * 60));
    try std.testing.expectError(error.InvalidTimezoneOffset, Timezone.init(841));
    try std.testing.expectError(error.InvalidTimezoneOffset, Timezone.init(-721));
}

test "Timezone.format produces git-style +HHMM/-HHMM, null for unknown" {
    var buf: [5]u8 = undefined;
    const utc: Timezone = .utc;
    const unknown: Timezone = .unknown;

    try std.testing.expectEqualStrings("+0000", utc.format(&buf).?);
    try std.testing.expectEqualStrings("-0500", (try Timezone.init(-300)).format(&buf).?);
    try std.testing.expectEqualStrings("+0530", (try Timezone.init(330)).format(&buf).?);
    try std.testing.expectEqual(@as(?[]const u8, null), unknown.format(&buf));
}

test "Timezone.parse inverts format for concrete offsets" {
    const samples = [_]i16{ 0, -300, 330, 840, -720, 60, -60 };
    var buf: [5]u8 = undefined;

    for (samples) |mins| {
        const tz = try Timezone.init(mins);
        const text = tz.format(&buf).?;
        const parsed = try Timezone.parse(text);
        try std.testing.expectEqual(tz, parsed);
    }
}

test "Timezone.parse rejects malformed input" {
    try std.testing.expectError(error.InvalidTimezoneFormat, Timezone.parse("530"));
    try std.testing.expectError(error.InvalidTimezoneFormat, Timezone.parse("+053"));
    try std.testing.expectError(error.InvalidTimezoneFormat, Timezone.parse("053000"));
    try std.testing.expectError(error.InvalidTimezoneFormat, Timezone.parse("*0530"));
    try std.testing.expectError(error.InvalidTimezoneFormat, Timezone.parse("+0X30"));
    try std.testing.expectError(error.InvalidTimezoneFormat, Timezone.parse("+0560")); // minutes >= 60
}

test "Timezone serialization round-trips utc, offset, and unknown" {
    const alloc = std.testing.allocator;
    const cases = [_]Timezone{ .utc, .{ .offset = 330 }, .{ .offset = -300 }, .unknown };

    for (cases) |tz| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try tz.serialize(buf.writer(alloc));

        // tag(1) + minutes(2)
        try std.testing.expectEqual(@as(usize, 3), buf.items.len);

        var mock_reader = MockReader{ .buffer = buf.items };
        const back = try Timezone.deserialize(&mock_reader);
        try std.testing.expectEqual(tz, back);
    }
}

test "Timestamp.value is never coerced to 'now', including zero" {
    try std.testing.expectEqual(@as(i64, 0), (Timestamp{ .value = 0 }).resolve());
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), (Timestamp{ .value = 1_700_000_000_000 }).resolve());
}

test "Timestamp.now resolves near the current wall clock" {
    const before = std.time.milliTimestamp();
    const t: Timestamp = .now;
    const resolved = t.resolve();
    const after = std.time.milliTimestamp();

    try std.testing.expect(resolved >= before);
    try std.testing.expect(resolved <= after);
}

test "SignatureInfo validation surfaces both person and timezone errors" {
    const bad_person = SignatureInfo.init(PersonInfo.init("", "a@b.com"));
    try std.testing.expectError(error.EmptyName, bad_person.validate());

    const bad_tz = SignatureInfo{
        .person = PersonInfo.init("A", "a@b.com"),
        .timezone = .{ .offset = 2000 },
    };
    try std.testing.expectError(error.InvalidTimezoneOffset, bad_tz.validate());
}

test "Signature serialization round-trips person, timestamp, and timezone" {
    const alloc = std.testing.allocator;
    const info = SignatureInfo{
        .person = PersonInfo.init("Ada Lovelace", "ada@nodus.dev"),
        .timestamp = .{ .value = 1_700_000_000_000 },
        .timezone = try Timezone.init(-300), // US Eastern
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    // name_len(2)+name(12) + email_len(2)+email(13) + timestamp(8) + tz_tag(1)+tz_minutes(2)
    try std.testing.expectEqual(@as(usize, 2 + 12 + 2 + 13 + 8 + 1 + 2), buf.items.len);

    var mock_reader = MockReader{ .buffer = buf.items };
    var sig = try Signature.deserialize(alloc, &mock_reader);
    defer sig.deinit(alloc);

    try std.testing.expectEqualStrings("Ada Lovelace", sig.person.name);
    try std.testing.expectEqualStrings("ada@nodus.dev", sig.person.email);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), sig.timestamp_ms);
    try std.testing.expectEqual(Timezone{ .offset = -300 }, sig.timezone);

    var tz_buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("-0500", sig.formattedTimezone(&tz_buf).?);
}

test "Signature deserialize rejects an out-of-range timezone offset" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try wire.writeBytes(u16, buf.writer(alloc), "User");
    try wire.writeBytes(u16, buf.writer(alloc), "user@email.com");
    try buf.writer(alloc).writeInt(i64, 1_000, .little);
    try buf.writer(alloc).writeByte(1); // tag_offset
    try buf.writer(alloc).writeInt(i16, 2000, .little); // out of civil range

    var mock_reader = MockReader{ .buffer = buf.items };
    try std.testing.expectError(error.InvalidTimezoneOffset, Signature.deserialize(alloc, &mock_reader));
}

test "Signature.samePerson / sameInstant / eql" {
    const alloc = std.testing.allocator;
    var a = try Signature.initDupe(alloc, .{
        .person = PersonInfo.init("Bruce Wayne", "bruce@wayne.corp"),
        .timestamp = .{ .value = 1_000 },
    });
    defer a.deinit(alloc);
    var b = try Signature.initDupe(alloc, .{
        .person = PersonInfo.init("Bruce Wayne", "bruce@wayne.corp"),
        .timestamp = .{ .value = 1_000 },
        .timezone = try Timezone.init(300), // different notation, same instant/person
    });
    defer b.deinit(alloc);
    var c = try Signature.initDupe(alloc, .{
        .person = PersonInfo.init("Bruce Wayne", "bruce@wayne.corp"),
        .timestamp = .{ .value = 2_000 },
    });
    defer c.deinit(alloc);

    try std.testing.expect(a.samePerson(b));
    try std.testing.expect(a.sameInstant(b));
    try std.testing.expect(a.eql(b)); // tz notation doesn't affect eql

    try std.testing.expect(a.samePerson(c));
    try std.testing.expect(!a.sameInstant(c));
    try std.testing.expect(!a.eql(c));
}

test "CommitSignaturesInfo.soloAuthor mirrors author into committer" {
    const alloc = std.testing.allocator;

    const info = CommitSignaturesInfo.soloAuthor(.{
        .person = PersonInfo.init("Bruce Wayne", "bruce@wayne.corp"),
        .timestamp = .{ .value = 1_000 },
    });

    try std.testing.expectEqualStrings("Bruce Wayne", info.committer.person.name);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    var mock_reader = MockReader{ .buffer = buf.items };
    var sigs = try CommitSignatures.deserialize(alloc, &mock_reader);
    defer sigs.deinit(alloc);

    try std.testing.expectEqualStrings("Bruce Wayne", sigs.author.person.name);
    try std.testing.expectEqualStrings("Bruce Wayne", sigs.committer.person.name);
    try std.testing.expect(sigs.isAuthorCommitter());
}

test "CommitSignaturesInfo.init keeps a distinct committer with its own timezone" {
    const alloc = std.testing.allocator;

    const info = CommitSignaturesInfo.init(
        .{
            .person = PersonInfo.init("Alan Turing", "alan@lab.net"),
            .timestamp = .{ .value = 1_000 },
            .timezone = try Timezone.init(60), // BST
        },
        .{
            .person = PersonInfo.init("Nodus Bot", "bot@nodus.dev"),
            .timestamp = .{ .value = 2_000 },
            .timezone = .utc,
        },
    );

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    var mock_reader = MockReader{ .buffer = buf.items };
    var sigs = try CommitSignatures.deserialize(alloc, &mock_reader);
    defer sigs.deinit(alloc);

    try std.testing.expectEqualStrings("Alan Turing", sigs.author.person.name);
    try std.testing.expectEqualStrings("Nodus Bot", sigs.committer.person.name);
    try std.testing.expectEqual(@as(i64, 1_000), sigs.author.timestamp_ms);
    try std.testing.expectEqual(@as(i64, 2_000), sigs.committer.timestamp_ms);
    try std.testing.expectEqual(Timezone{ .offset = 60 }, sigs.author.timezone);
    try std.testing.expectEqual(Timezone.utc, sigs.committer.timezone);
    try std.testing.expect(!sigs.isAuthorCommitter());
}

test "CommitSignatures round-trips a genuinely unknown committer timezone" {
    const alloc = std.testing.allocator;

    const info = CommitSignaturesInfo.init(
        .{ .person = PersonInfo.init("Original Author", "orig@example.com"), .timestamp = .{ .value = 500 } },
        .{
            .person = PersonInfo.init("Patch Importer", "importer@example.com"),
            .timestamp = .{ .value = 1_500 },
            .timezone = .unknown, // imported patch, offset genuinely not recorded
        },
    );

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    var mock_reader = MockReader{ .buffer = buf.items };
    var sigs = try CommitSignatures.deserialize(alloc, &mock_reader);
    defer sigs.deinit(alloc);

    try std.testing.expectEqual(Timezone.unknown, sigs.committer.timezone);

    var tz_buf: [5]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), sigs.committer.formattedTimezone(&tz_buf));
}
