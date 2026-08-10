const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wire = @import("wire.zig");
const testing_io = @import("testing.zig");

pub const MessageError = error{
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

    pub fn serialize(self: TrailerInfo, writer: *Io.Writer) !void {
        try self.validate();
        try wire.writeBytes(u8, writer, self.key);
        try wire.writeBytes(u16, writer, self.value);
    }

    /// Scan `body` for git-style trailers at its tail and split them off.
    pub fn parseTrailingBlock(
        alloc: Allocator,
        body: []const u8,
        out: *std.ArrayListUnmanaged(TrailerInfo),
    ) ![]const u8 {
        // Collect lines so we can find the contiguous trailer tail by
        // walking backwards from the end.
        var lines = std.ArrayListUnmanaged([]const u8){};
        defer lines.deinit(alloc);

        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| try lines.append(alloc, line);

        // Walk backwards, collecting trailers (scanned back-to-front) until
        // a blank line or a line that fails validation ends the block.
        var found = std.ArrayListUnmanaged(TrailerInfo){};
        defer found.deinit(alloc);

        var trailer_start: usize = lines.items.len; // index of first trailer line

        var i: usize = lines.items.len;
        while (i > 0) {
            i -= 1;
            const line = std.mem.trimRight(u8, lines.items[i], " \t\r");

            // A blank line ends the backwards scan; everything below it is
            // the trailer block (if any were found).
            if (line.len == 0) break;

            // Must look like `key: value` — key, then ": ", then the rest.
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse break;
            const rest = line[colon + 1 ..];
            if (rest.len < 2 or rest[0] != ' ') break;

            const candidate = TrailerInfo{
                .key = line[0..colon],
                .value = std.mem.trim(u8, rest[1..], " \t"),
            };
            candidate.validate() catch break;

            try found.append(alloc, candidate);
            trailer_start = i;
        }

        if (trailer_start == lines.items.len) return body; // nothing found

        // `found` was built back-to-front; append to `out` in source order.
        var idx = found.items.len;
        while (idx > 0) {
            idx -= 1;
            try out.append(alloc, found.items[idx]);
        }

        // Strip the trailer block and the blank line above it from the
        // body. Find the last non-trailer, non-blank line.
        var end = trailer_start;
        while (end > 0 and std.mem.trimRight(u8, lines.items[end - 1], " \t\r").len == 0) {
            end -= 1;
        }

        if (end == 0) return "";

        var kept = std.ArrayListUnmanaged(u8){};
        errdefer kept.deinit(alloc);
        for (lines.items[0..end], 0..) |line, li| {
            if (li > 0) try kept.append(alloc, '\n');
            try kept.appendSlice(alloc, line);
        }
        return kept.toOwnedSlice(alloc);
    }
};

pub const Trailer = struct {
    key: []u8,
    value: []u8,

    pub fn deserialize(alloc: Allocator, reader: *Io.Reader) !Trailer {
        const key = try wire.readBytesAlloc(u8, alloc, reader);
        errdefer alloc.free(key);

        const value = try wire.readBytesAlloc(u16, alloc, reader);
        errdefer alloc.free(value);

        // Re-validate on the way out so corrupt data is caught at read time.
        const info = TrailerInfo{ .key = key, .value = value };
        try info.validate();

        return .{ .key = key, .value = value };
    }

    pub fn deinit(self: *Trailer, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.value);
        self.* = undefined;
    }
};

/// Character encoding of `title`/`body`. merk doesn't transcode
/// anything itself — this is a label so downstream tooling (a UI, a
/// terminal renderer, an export to some other format) knows how to
/// interpret the bytes instead of assuming UTF-8 and mangling
/// legacy/localized commit messages.
pub const Encoding = enum(u8) {
    utf8 = 0,
    ascii = 1,
    latin1 = 2,
    /// Encoding is known to be something else, or unknown — bytes are
    /// stored as-is regardless; this is purely descriptive.
    other = 255,
};

pub const MessageInfo = struct {
    title: []const u8,
    body: []const u8 = "",

    /// Character encoding of `title`/`body`. Defaults to UTF-8, which
    /// is what merk assumes unless told otherwise.
    encoding: Encoding = .utf8,

    /// Structured trailers appended after the body.
    /// Order is preserved; duplicate keys are allowed.
    trailers: []const TrailerInfo = &.{},

    /// Trimmed title/body, computed once so `validate`, `serialize`, and
    /// `Message.initDupe` all agree on what "trimmed" means.
    fn trimmed(self: MessageInfo) struct { title: []const u8, body: []const u8 } {
        return .{
            .title = std.mem.trim(u8, self.title, " \t\r\n"),
            .body = std.mem.trim(u8, self.body, " \t\r\n"),
        };
    }

    pub fn validate(self: MessageInfo) MessageError!void {
        const t = self.trimmed();

        if (t.title.len == 0) return error.EmptyCommitMessage;
        if (t.title.len > std.math.maxInt(u16)) return error.TitleTooLong;
        if (t.body.len > std.math.maxInt(u32)) return error.BodyTooLong;
        if (self.trailers.len > std.math.maxInt(u8)) return error.TooManyTrailers;

        // Prevent header injection and malformed commit titles by blocking newlines/nulls.
        const illegal_title_chars = &[_]u8{ '\n', '\r', '\x00' };
        if (std.mem.indexOfAny(u8, t.title, illegal_title_chars) != null)
            return error.TitleContainsIllegalCharacters;

        for (self.trailers) |trailer_info| try trailer_info.validate();
    }

    pub fn serialize(self: MessageInfo, writer: *Io.Writer) !void {
        try self.validate();

        try writer.writeByte(@intFromEnum(self.encoding));

        const t = self.trimmed();
        try wire.writeBytes(u16, writer, t.title);
        try wire.writeBytes(u32, writer, t.body);

        // trailers (u8 count, then each key/value)
        try wire.writeList(TrailerInfo, u8, writer, self.trailers);
    }
};

pub const Message = struct {
    title: []u8,
    body: []u8,
    encoding: Encoding,

    trailers: []Trailer,

    pub fn initDupe(alloc: Allocator, info: MessageInfo) !Message {
        try info.validate();

        const t = info.trimmed();

        const title = try alloc.dupe(u8, t.title);
        errdefer alloc.free(title);

        const body = try alloc.dupe(u8, t.body);
        errdefer alloc.free(body);

        const trailers = try alloc.alloc(Trailer, info.trailers.len);
        var initialized: usize = 0;
        errdefer {
            for (trailers[0..initialized]) |*tr| tr.deinit(alloc);
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
            .encoding = info.encoding,
            .trailers = trailers,
        };
    }

    pub fn deserialize(alloc: Allocator, reader: *Io.Reader) !Message {
        const raw_encoding = try reader.takeByte();
        const encoding = std.meta.intToEnum(Encoding, raw_encoding) catch return error.CorruptCommit;

        const title = try wire.readBytesAlloc(u16, alloc, reader);
        errdefer alloc.free(title);

        const body = try wire.readBytesAlloc(u32, alloc, reader);
        errdefer alloc.free(body);

        // Same "count-prefixed, self-deserializing, owning items" shape
        // as any other wire list of allocation-owning elements — see
        // `wire.readOwningListAlloc`'s doc comment. The `errdefer` here
        // covers the `info.validate()` call below: if that fails after
        // every trailer already decoded successfully, they still need
        // freeing, which is outside `readOwningListAlloc`'s own scope.
        const trailers = try wire.readOwningListAlloc(Trailer, u8, alloc, reader);
        errdefer {
            for (trailers) |*t| t.deinit(alloc);
            alloc.free(trailers);
        }

        // Re-validate title after allocation (body and trailers already validated
        // inside their own deserialize calls).
        const info = MessageInfo{
            .title = title,
            .body = body,
            .encoding = encoding,
        };
        try info.validate();

        return .{
            .title = title,
            .body = body,
            .encoding = encoding,
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
        alloc: Allocator,
    ) !void {
        for (self.trailers) |t| {
            if (std.mem.eql(u8, t.key, key)) try out.append(alloc, t.value);
        }
    }

    pub fn deinit(self: *Message, alloc: Allocator) void {
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
    try testing.expectError(error.EmptyCommitMessage, empty_title.validate());

    const bad_title = MessageInfo{
        .title = "feat: added\nmultiline title",
        .body = "",
    };
    try testing.expectError(error.TitleContainsIllegalCharacters, bad_title.validate());
}

test "MessageInfo serialization format - no trailers" {
    const info = MessageInfo{
        .title = " fix(core): memory leak ",
        .body = " resolved ",
    };
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    try info.serialize(sink.writer());

    // encoding byte (utf8 = 0) + u16 title len + title + u32 body len + body
    // + u8 trailer count (0)
    const expected = "\x00\x16\x00fix(core): memory leak\x08\x00\x00\x00resolved\x00";
    try testing.expectEqualSlices(u8, expected, sink.bytes());
}

test "MessageInfo serialization records a non-default encoding" {
    const info = MessageInfo{
        .title = "legacy import",
        .encoding = .latin1,
    };
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();
    try info.serialize(sink.writer());

    try testing.expectEqual(@as(u8, 2), sink.bytes()[0]);

    var reader = testing_io.fixedReader(sink.bytes());
    var msg = try Message.deserialize(alloc, &reader);
    defer msg.deinit(alloc);
    try testing.expectEqual(Encoding.latin1, msg.encoding);
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
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();
    try info.serialize(sink.writer());

    // Deserialise and check round-trip
    var reader = testing_io.fixedReader(sink.bytes());
    var msg = try Message.deserialize(alloc, &reader);
    defer msg.deinit(alloc);

    try testing.expectEqualStrings("fix: patch the thing", msg.title);
    try testing.expectEqual(Encoding.utf8, msg.encoding);
    try testing.expectEqual(@as(usize, 2), msg.trailers.len);
    try testing.expectEqualStrings("closes", msg.trailers[0].key);
    try testing.expectEqualStrings("#42", msg.trailers[0].value);
    try testing.expectEqualStrings("reviewed-by", msg.trailers[1].key);
    try testing.expectEqualStrings("alice@corp.com", msg.trailers[1].value);
}

test "Message.trailer lookup" {
    const alloc = testing.allocator;
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
    try testing.expectEqualStrings("#99", msg.trailer("closes").?);
    try testing.expectEqualStrings("api.v1", msg.trailer("breaks").?);
    try testing.expectEqual(@as(?[]const u8, null), msg.trailer("missing"));
}

test "Message.trailersFor - multiple values for same key" {
    const alloc = testing.allocator;
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

    try testing.expectEqual(@as(usize, 3), found.items.len);
    try testing.expectEqualStrings("#1", found.items[0]);
    try testing.expectEqualStrings("#2", found.items[1]);
    try testing.expectEqualStrings("#3", found.items[2]);
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
        try testing.expectError(e, t.validate());
    }
}

test "Message lifecycle via initDupe" {
    const allocator = testing.allocator;
    const info = MessageInfo{
        .title = " docs: update readme ",
        .body = " added instructions ",
        .trailers = &.{.{ .key = "reviewed-by", .value = "carol@corp.com" }},
    };

    var msg = try Message.initDupe(allocator, info);
    defer msg.deinit(allocator);

    try testing.expectEqualStrings("docs: update readme", msg.title);
    try testing.expectEqualStrings("added instructions", msg.body);
    try testing.expectEqual(@as(usize, 1), msg.trailers.len);
    try testing.expectEqualStrings("reviewed-by", msg.trailers[0].key);
    try testing.expectEqualStrings("carol@corp.com", msg.trailers[0].value);
}

test "TrailerInfo.parseTrailingBlock - splits a trailing trailer block" {
    const alloc = testing.allocator;
    const body = "Fixes the thing.\n\nMore detail here.\n\ncloses: #42\nreviewed-by: alice@corp.com";

    var out = std.ArrayListUnmanaged(TrailerInfo){};
    defer out.deinit(alloc);

    const rest = try TrailerInfo.parseTrailingBlock(alloc, body, &out);
    defer if (rest.ptr != body.ptr) alloc.free(rest);

    try testing.expectEqualStrings("Fixes the thing.\n\nMore detail here.", rest);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("closes", out.items[0].key);
    try testing.expectEqualStrings("#42", out.items[0].value);
    try testing.expectEqualStrings("reviewed-by", out.items[1].key);
    try testing.expectEqualStrings("alice@corp.com", out.items[1].value);
}

test "TrailerInfo.parseTrailingBlock - no trailer block returns body unchanged" {
    const alloc = testing.allocator;
    const body = "Just a description, no trailers here.";

    var out = std.ArrayListUnmanaged(TrailerInfo){};
    defer out.deinit(alloc);

    const rest = try TrailerInfo.parseTrailingBlock(alloc, body, &out);

    try testing.expectEqual(body.ptr, rest.ptr);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "TrailerInfo.parseTrailingBlock - invalid key stops the scan" {
    const alloc = testing.allocator;
    // "bad key" has a space in the key, so it fails TrailerInfo.validate()
    // and isn't treated as a trailer — nor is "closes" below it, since the
    // block must be contiguous from the bottom up.
    const body = "Body text.\n\nbad key: nope\ncloses: #1";

    var out = std.ArrayListUnmanaged(TrailerInfo){};
    defer out.deinit(alloc);

    const rest = try TrailerInfo.parseTrailingBlock(alloc, body, &out);

    try testing.expectEqual(body.ptr, rest.ptr);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "TrailerInfo.parseTrailingBlock - whole body is a trailer block" {
    const alloc = testing.allocator;
    const body = "closes: #1\nbreaks: api.v1";

    var out = std.ArrayListUnmanaged(TrailerInfo){};
    defer out.deinit(alloc);

    const rest = try TrailerInfo.parseTrailingBlock(alloc, body, &out);
    defer if (rest.ptr != body.ptr) alloc.free(rest);

    try testing.expectEqualStrings("", rest);
    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "Message deserialization from binary stream - legacy no trailers" {
    const allocator = std.testing.allocator;

    const serialized_data = "\x00\x11\x00refactor: storage\x04\x00\x00\x00done\x00";

    var reader = testing_io.fixedReader(serialized_data);
    var msg = try Message.deserialize(allocator, &reader);
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("refactor: storage", msg.title);
    try std.testing.expectEqualStrings("done", msg.body);
    try std.testing.expectEqual(Encoding.utf8, msg.encoding);
    try std.testing.expectEqual(@as(usize, 0), msg.trailers.len);
}
