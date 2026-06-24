const std = @import("std");
const MockReader = @import("testing.zig").MockReader;

const MessageError = error{
    EmptyCommitMessage,
    TitleTooLong,
    BodyTooLong,
    TitleContainsIllegalCharacters,
};

pub const MessageInfo = struct {
    title: []const u8,
    body: []const u8 = "",

    pub fn validate(self: MessageInfo) MessageError!void {
        const trimmed_title = std.mem.trim(u8, self.title, " \t\r\n");
        const trimmed_body = std.mem.trim(u8, self.body, " \t\r\n");

        if (trimmed_title.len == 0) return error.EmptyCommitMessage;
        if (trimmed_title.len > std.math.maxInt(u16)) return error.TitleTooLong;
        if (trimmed_body.len > std.math.maxInt(u32)) return error.BodyTooLong;

        // Prevent header injection and malformed commit titles by blocking newlines/nulls
        const illegal_title_chars = &[_]u8{ '\n', '\r', '\x00' };
        if (std.mem.indexOfAny(u8, trimmed_title, illegal_title_chars) != null) {
            return error.TitleContainsIllegalCharacters;
        }
    }

    pub fn serialize(self: MessageInfo, writer: anytype) !void {
        try self.validate();

        const trimmed_title = std.mem.trim(u8, self.title, " \t\r\n");
        const trimmed_body = std.mem.trim(u8, self.body, " \t\r\n");

        // Write title payload (u16 length prefixed)
        try writer.writeInt(u16, @intCast(trimmed_title.len), .little);
        try writer.writeAll(trimmed_title);

        // Write body payload (u32 length prefixed to handle longer content)
        try writer.writeInt(u32, @intCast(trimmed_body.len), .little);
        try writer.writeAll(trimmed_body);
    }
};

pub const Message = struct {
    title: []u8,
    body: []u8,

    pub fn initDupe(alloc: std.mem.Allocator, info: MessageInfo) !Message {
        try info.validate();

        const trimmed_title = std.mem.trim(u8, info.title, " \t\r\n");
        const trimmed_body = std.mem.trim(u8, info.body, " \t\r\n");

        const title = try alloc.dupe(u8, trimmed_title);
        errdefer alloc.free(title);

        const body = try alloc.dupe(u8, trimmed_body);
        errdefer alloc.free(body);

        return .{
            .title = title,
            .body = body,
        };
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Message {
        const title_len = try reader.takeInt(u16, .little);
        const title = try alloc.dupe(u8, try reader.take(title_len));
        errdefer alloc.free(title);

        const body_len = try reader.takeInt(u32, .little);
        const body = try alloc.dupe(u8, try reader.take(body_len));
        errdefer alloc.free(body);

        const info = MessageInfo{
            .title = title,
            .body = body,
        };
        try info.validate();

        return .{
            .title = title,
            .body = body,
        };
    }

    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
        self.* = undefined;
    }
};

test "MessageInfo validation - success and failure cases" {
    // Valid case with trailing whitespace handling
    const valid_msg = MessageInfo{
        .title = "  feat: add custom testing harness  ",
        .body = "This fixes issue #123.\n\nSigned-off-by: Developer  ",
    };
    try valid_msg.validate();

    // Empty title case
    const empty_title = MessageInfo{ .title = "   \t  ", .body = "Some body content" };
    try std.testing.expectError(error.EmptyCommitMessage, empty_title.validate());

    // Illegal character in title (newlines)
    const bad_title = MessageInfo{ .title = "feat: added\nmultiline title", .body = "" };
    try std.testing.expectError(error.TitleContainsIllegalCharacters, bad_title.validate());
}

test "MessageInfo serialization format" {
    const info = MessageInfo{
        .title = " fix(core): memory leak ",
        .body = " resolved ",
    };
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try info.serialize(buf.writer(alloc));

    // Expected byte footprint:
    // u16 length of "fix(core): memory leak" (22) -> \x16\x00
    // "fix(core): memory leak"
    // u32 length of "resolved" (8) -> \x08\x00\x00\x00
    // "resolved"
    const expected = "\x16\x00fix(core): memory leak\x08\x00\x00\x00resolved";
    try std.testing.expectEqualSlices(u8, expected, buf.items);
}

test "Message lifecycle via initDupe" {
    const allocator = std.testing.allocator;
    const info = MessageInfo{
        .title = " docs: update readme ",
        .body = " added instructions ",
    };

    var message = try Message.initDupe(allocator, info);
    defer message.deinit(allocator);

    try std.testing.expectEqualStrings("docs: update readme", message.title);
    try std.testing.expectEqualStrings("added instructions", message.body);
}

test "Message deserialization from binary stream" {
    const allocator = std.testing.allocator;

    const serialized_data = "\x0c\x00refactor: io\x04\x00\x00\x00done";

    var mock_reader = MockReader{ .buffer = serialized_data };

    var message = try Message.deserialize(allocator, &mock_reader);
    defer message.deinit(allocator);

    try std.testing.expectEqualStrings("refactor: io", message.title);
    try std.testing.expectEqualStrings("done", message.body);
}
