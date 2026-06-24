const std = @import("std");
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
        const trimmed_name =
            std.mem.trim(u8, self.name, " \t\r\n");

        const trimmed_email =
            std.mem.trim(u8, self.email, " \t\r\n");

        if (trimmed_name.len == 0)
            return error.EmptyName;

        if (trimmed_email.len == 0)
            return error.EmptyEmail;

        if (trimmed_name.len > std.math.maxInt(u16))
            return error.NameTooLong;

        if (trimmed_email.len > std.math.maxInt(u16))
            return error.EmailTooLong;

        // Prevent header/object injection.
        const illegal_name_chars = &[_]u8{
            '\n',
            '\r',
            '<',
            '>',
            '\x00',
        };

        if (std.mem.indexOfAny(
            u8,
            trimmed_name,
            illegal_name_chars,
        ) != null) {
            return error.NameContainsIllegalCharacters;
        }

        // Emails must not contain whitespace,
        // control chars, or angle brackets.
        const illegal_email_chars = &[_]u8{
            ' ',
            '\t',
            '\n',
            '\r',
            '<',
            '>',
            '\x00',
        };

        if (std.mem.indexOfAny(
            u8,
            trimmed_email,
            illegal_email_chars,
        ) != null) {
            return error.EmailContainsIllegalCharacters;
        }

        const at_idx =
            std.mem.indexOfScalar(
                u8,
                trimmed_email,
                '@',
            ) orelse return error.MissingEmailAtSign;

        if (at_idx == 0 or at_idx == trimmed_email.len - 1)
            return error.InvalidEmailBounds;

        if (std.mem.indexOfScalar(
            u8,
            trimmed_email[at_idx + 1 ..],
            '@',
        ) != null) {
            return error.EmailContainsIllegalCharacters;
        }
    }

    pub fn serialize(
        self: IdentityInfo,
        writer: anytype,
    ) !void {
        try self.validate();

        const trimmed_name =
            std.mem.trim(u8, self.name, " \t\r\n");

        const trimmed_email =
            std.mem.trim(u8, self.email, " \t\r\n");

        try writer.writeInt(
            u16,
            @intCast(trimmed_name.len),
            .little,
        );
        try writer.writeAll(trimmed_name);

        try writer.writeInt(
            u16,
            @intCast(trimmed_email.len),
            .little,
        );
        try writer.writeAll(trimmed_email);
    }
};

/// The allocated, owned identity variant stored inside a deserialized Commit object.
pub const Identity = struct {
    name: []u8,
    email: []u8,

    pub fn initDupe(
        alloc: std.mem.Allocator,
        info: IdentityInfo,
    ) !Identity {
        try info.validate();

        const trimmed_name =
            std.mem.trim(u8, info.name, " \t\r\n");

        const trimmed_email =
            std.mem.trim(u8, info.email, " \t\r\n");

        const name = try alloc.dupe(
            u8,
            trimmed_name,
        );
        errdefer alloc.free(name);

        const email = try alloc.dupe(
            u8,
            trimmed_email,
        );
        errdefer alloc.free(email);

        return .{
            .name = name,
            .email = email,
        };
    }

    pub fn deserialize(
        alloc: std.mem.Allocator,
        reader: anytype,
    ) !Identity {
        const name_len = try reader.takeInt(u16, .little);

        const name = try alloc.dupe(
            u8,
            try reader.take(name_len),
        );
        errdefer alloc.free(name);

        const email_len = try reader.takeInt(u16, .little);

        const email = try alloc.dupe(
            u8,
            try reader.take(email_len),
        );
        errdefer alloc.free(email);

        const info = IdentityInfo{
            .name = name,
            .email = email,
        };

        try info.validate();

        return .{
            .name = name,
            .email = email,
        };
    }

    pub fn deinit(
        self: *Identity,
        alloc: std.mem.Allocator,
    ) void {
        alloc.free(self.name);
        alloc.free(self.email);

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

test "Identity initDupe lifecycle" {
    const allocator = std.testing.allocator;
    const info = IdentityInfo{
        .name = "  Clean Name  ",
        .email = "clean@email.com  ",
    };

    var identity = try Identity.initDupe(allocator, info);
    defer identity.deinit(allocator);

    try std.testing.expectEqualStrings("Clean Name", identity.name);
    try std.testing.expectEqualStrings("clean@email.com", identity.email);
}

test "Identity deserialization" {
    const allocator = std.testing.allocator;

    const serialized_data = "\x04\x00User\x0e\x00user@email.com";

    var mock_reader = MockReader{ .buffer = serialized_data };

    var identity = try Identity.deserialize(allocator, &mock_reader);
    defer identity.deinit(allocator);

    try std.testing.expectEqualStrings("User", identity.name);
    try std.testing.expectEqualStrings("user@email.com", identity.email);
}
