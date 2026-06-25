const std = @import("std");
const MockReader = @import("testing.zig").MockReader;

const MessageError = error{
    EmptyCommitMessage,
    TitleTooLong,
    BodyTooLong,
    TitleContainsIllegalCharacters,
    TooManyTrailers,
    TrailerKeyEmpty,
    TrailerKeyTooLong,
    TrailerValueTooLong,
    TrailerKeyContainsIllegalCharacters,
};

// Keys follow the git trailer convention: printable ASCII, no whitespace,
// no colon (the colon is the separator on display).
//
// Examples:
//   closes         #42
//   reviewed-by    alice@corp.com
//   breaks         config.api_url
//   cherry-picked  abc1234

pub const TrailerInfo = struct {
    key: []const u8,
    value: []const u8 = "",

    pub fn validate(self: TrailerInfo) MessageError!void {
        if (self.key.len == 0) return error.TrailerKeyEmpty;
        if (self.key.len > std.math.maxInt(u8)) return error.TrailerKeyTooLong;
        if (self.value.len > std.math.maxInt(u16)) return error.TrailerValueTooLong;

        for (self.key) |c| {
            if (c < 0x21 or c > 0x7E or c == ':')
                return error.TrailerKeyContainsIllegalCharacters;
        }
    }

    pub fn serialize(self: TrailerInfo, writer: anytype) !void {
        try self.validate();
        try writer.writeByte(@intCast(self.key.len));
        try writer.writeAll(self.key);
        try writer.writeInt(u16, @intCast(self.value.len), .little);
        try writer.writeAll(self.value);
    }
};

pub const Trailer = struct {
    key: []u8,
    value: []u8,

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Trailer {
        const key_len = try reader.takeByte();
        const key = try alloc.dupe(u8, try reader.take(key_len));
        errdefer alloc.free(key);

        const value_len = try reader.takeInt(u16, .little);
        const value = try alloc.dupe(u8, try reader.take(value_len));
        errdefer alloc.free(value);

        // Re-validate on the way out so corrupt data is caught at read time.
        const info = TrailerInfo{ .key = key, .value = value };
        try info.validate();

        return .{ .key = key, .value = value };
    }

    pub fn deinit(self: *Trailer, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.value);
        self.* = undefined;
    }
};

pub const MessageInfo = struct {
    title: []const u8,
    body: []const u8 = "",

    /// Structured trailers appended after the body.
    /// Order is preserved; duplicate keys are allowed.
    trailers: []const TrailerInfo = &.{},

    pub fn validate(self: MessageInfo) MessageError!void {
        const trimmed_title = std.mem.trim(u8, self.title, " \t\r\n");
        const trimmed_body = std.mem.trim(u8, self.body, " \t\r\n");

        if (trimmed_title.len == 0) return error.EmptyCommitMessage;
        if (trimmed_title.len > std.math.maxInt(u16)) return error.TitleTooLong;
        if (trimmed_body.len > std.math.maxInt(u32)) return error.BodyTooLong;
        if (self.trailers.len > std.math.maxInt(u8)) return error.TooManyTrailers;

        // Prevent header injection and malformed commit titles by blocking newlines/nulls
        const illegal_title_chars = &[_]u8{ '\n', '\r', '\x00' };
        if (std.mem.indexOfAny(u8, trimmed_title, illegal_title_chars) != null)
            return error.TitleContainsIllegalCharacters;

        for (self.trailers) |t| try t.validate();
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

        // trailers (u8 count, then each key/value)
        try writer.writeByte(@intCast(self.trailers.len));
        for (self.trailers) |t| try t.serialize(writer);
    }
};

pub const Message = struct {
    title: []u8,
    body: []u8,

    trailers: []Trailer,

    pub fn initDupe(alloc: std.mem.Allocator, info: MessageInfo) !Message {
        try info.validate();

        const trimmed_title = std.mem.trim(u8, info.title, " \t\r\n");
        const trimmed_body = std.mem.trim(u8, info.body, " \t\r\n");

        const title = try alloc.dupe(u8, trimmed_title);
        errdefer alloc.free(title);

        const body = try alloc.dupe(u8, trimmed_body);
        errdefer alloc.free(body);

        const trailers = try alloc.alloc(Trailer, info.trailers.len);
        var initialized: usize = 0;
        errdefer {
            for (trailers[0..initialized]) |*t| t.deinit(alloc);
            alloc.free(trailers);
        }

        for (info.trailers) |src| {
            const key = try alloc.dupe(u8, src.key);
            errdefer alloc.free(key);
            const value = try alloc.dupe(u8, src.value);
            errdefer alloc.free(value);
            trailers[initialized] = .{ .key = key, .value = value };
            initialized += 1;
        }

        return .{
            .title = title,
            .body = body,
            .trailers = trailers,
        };
    }

    pub fn deserialize(alloc: std.mem.Allocator, reader: anytype) !Message {
        const title_len = try reader.takeInt(u16, .little);
        const title = try alloc.dupe(u8, try reader.take(title_len));
        errdefer alloc.free(title);

        const body_len = try reader.takeInt(u32, .little);
        const body = try alloc.dupe(u8, try reader.take(body_len));
        errdefer alloc.free(body);

        const trailer_count = try reader.takeByte();
        const trailers = try alloc.alloc(Trailer, trailer_count);
        var initialized: usize = 0;
        errdefer {
            for (trailers[0..initialized]) |*t| t.deinit(alloc);
            alloc.free(trailers);
        }

        while (initialized < trailer_count) : (initialized += 1) {
            trailers[initialized] = try Trailer.deserialize(alloc, reader);
        }

        // Re-validate title after allocation (body and trailers already validated
        // inside their own deserialize calls).
        const info = MessageInfo{
            .title = title,
            .body = body,
        };
        try info.validate();

        return .{
            .title = title,
            .body = body,
            .trailers = trailers,
        };
    }

    /// Find the first trailer value for the given key, or null.
    pub fn trailer(self: Message, key: []const u8) ?[]const u8 {
        for (self.trailers) |t| {
            if (std.mem.eql(u8, t.key, key)) return t.value;
        }
        return null;
    }

    /// Iterate over all trailers matching key.
    pub fn trailersFor(
        self: Message,
        key: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
        alloc: std.mem.Allocator,
    ) !void {
        for (self.trailers) |t| {
            if (std.mem.eql(u8, t.key, key)) try out.append(alloc, t.value);
        }
    }

    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
        for (self.trailers) |*t| t.deinit(alloc);
        alloc.free(self.trailers);
        self.* = undefined;
    }
};

test "MessageInfo validation - success and failure cases" {
    const valid_msg = MessageInfo{
        .title = "  feat: add custom testing harness  ",
        .body = "This fixes issue #123.\n\nSigned-off-by: Developer  ",
    };
    try valid_msg.validate();

    const empty_title = MessageInfo{
        .title = "   \t  ",
        .body = "Some body content",
    };
    try std.testing.expectError(error.EmptyCommitMessage, empty_title.validate());

    const bad_title = MessageInfo{
        .title = "feat: added\nmultiline title",
        .body = "",
    };
    try std.testing.expectError(error.TitleContainsIllegalCharacters, bad_title.validate());
}

test "MessageInfo serialization format - no trailers" {
    const info = MessageInfo{
        .title = " fix(core): memory leak ",
        .body = " resolved ",
    };
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try info.serialize(buf.writer(alloc));

    // u16 title len + title + u32 body len + body + u8 trailer count (0)
    const expected = "\x16\x00fix(core): memory leak\x08\x00\x00\x00resolved\x00";
    try std.testing.expectEqualSlices(u8, expected, buf.items);
}

test "MessageInfo serialization format - with trailers" {
    const trailers = [_]TrailerInfo{
        .{ .key = "closes", .value = "#42" },
        .{ .key = "reviewed-by", .value = "alice@corp.com" },
    };
    const info = MessageInfo{
        .title = "fix: patch the thing",
        .body = "",
        .trailers = &trailers,
    };
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try info.serialize(buf.writer(alloc));

    // Deserialise and check round-trip
    var mock_reader = MockReader{ .buffer = buf.items };
    var msg = try Message.deserialize(alloc, &mock_reader);
    defer msg.deinit(alloc);

    try std.testing.expectEqualStrings("fix: patch the thing", msg.title);
    try std.testing.expectEqual(@as(usize, 2), msg.trailers.len);
    try std.testing.expectEqualStrings("closes", msg.trailers[0].key);
    try std.testing.expectEqualStrings("#42", msg.trailers[0].value);
    try std.testing.expectEqualStrings("reviewed-by", msg.trailers[1].key);
    try std.testing.expectEqualStrings("alice@corp.com", msg.trailers[1].value);
}

test "Message.trailer lookup" {
    const alloc = std.testing.allocator;
    const trailers = [_]TrailerInfo{
        .{ .key = "closes", .value = "#99" },
        .{ .key = "breaks", .value = "api.v1" },
        .{ .key = "closes", .value = "#100" }, // duplicate key
    };
    var msg = try Message.initDupe(alloc, .{
        .title = "refactor: rename endpoint",
        .trailers = &trailers,
    });
    defer msg.deinit(alloc);

    // Returns first match
    try std.testing.expectEqualStrings("#99", msg.trailer("closes").?);
    try std.testing.expectEqualStrings("api.v1", msg.trailer("breaks").?);
    try std.testing.expectEqual(@as(?[]const u8, null), msg.trailer("missing"));
}

test "Message.trailersFor - multiple values for same key" {
    const alloc = std.testing.allocator;
    const trailers = [_]TrailerInfo{
        .{ .key = "closes", .value = "#1" },
        .{ .key = "closes", .value = "#2" },
        .{ .key = "closes", .value = "#3" },
    };
    var msg = try Message.initDupe(alloc, .{
        .title = "feat: big feature",
        .trailers = &trailers,
    });
    defer msg.deinit(alloc);

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    defer found.deinit(alloc);
    try msg.trailersFor("closes", &found, alloc);

    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    try std.testing.expectEqualStrings("#1", found.items[0]);
    try std.testing.expectEqualStrings("#2", found.items[1]);
    try std.testing.expectEqualStrings("#3", found.items[2]);
}

test "TrailerInfo validation - illegal key characters" {
    const bad_keys = [_][]const u8{
        "", // empty
        "key with space",
        "key\twith\ttabs",
        "key:with:colon",
        "key\x00null",
    };
    const expected_errors = [_]anyerror{
        error.TrailerKeyEmpty,
        error.TrailerKeyContainsIllegalCharacters,
        error.TrailerKeyContainsIllegalCharacters,
        error.TrailerKeyContainsIllegalCharacters,
        error.TrailerKeyContainsIllegalCharacters,
    };
    for (bad_keys, expected_errors) |k, e| {
        const t = TrailerInfo{ .key = k, .value = "val" };
        try std.testing.expectError(e, t.validate());
    }
}

test "Message lifecycle via initDupe" {
    const allocator = std.testing.allocator;
    const info = MessageInfo{
        .title = " docs: update readme ",
        .body = " added instructions ",
        .trailers = &.{.{ .key = "reviewed-by", .value = "carol@corp.com" }},
    };

    var msg = try Message.initDupe(allocator, info);
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("docs: update readme", msg.title);
    try std.testing.expectEqualStrings("added instructions", msg.body);
    try std.testing.expectEqual(@as(usize, 1), msg.trailers.len);
    try std.testing.expectEqualStrings("reviewed-by", msg.trailers[0].key);
    try std.testing.expectEqualStrings("carol@corp.com", msg.trailers[0].value);
}

test "Message deserialization from binary stream - legacy no trailers" {
    const allocator = std.testing.allocator;
    // Wire format with 0 trailers (backward compat)
    const serialized_data = "\x0c\x00refactor: io\x04\x00\x00\x00done\x00";

    var mock_reader = MockReader{ .buffer = serialized_data };
    var msg = try Message.deserialize(allocator, &mock_reader);
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("refactor: io", msg.title);
    try std.testing.expectEqualStrings("done", msg.body);
    try std.testing.expectEqual(@as(usize, 0), msg.trailers.len);
}
