const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ConfigFormat = struct {
    entries: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *ConfigFormat, alloc: Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            alloc.free(kv.key_ptr.*);
            alloc.free(kv.value_ptr.*);
        }
        self.entries.deinit(alloc);
    }

    pub fn get(self: *const ConfigFormat, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    pub fn getBool(self: *const ConfigFormat, key: []const u8) !?bool {
        const raw = self.get(key) orelse return null;
        if (std.mem.eql(u8, raw, "true")) return true;
        if (std.mem.eql(u8, raw, "false")) return false;
        return error.InvalidBooleanValue;
    }

    pub fn parse(alloc: Allocator, text: []const u8) !ConfigFormat {
        var cf: ConfigFormat = .{};
        errdefer cf.deinit(alloc);
        try cf.mergeText(alloc, text);
        return cf;
    }
    pub fn mergeText(self: *ConfigFormat, alloc: Allocator, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == ';' or line[0] == '#') continue;

            const sep_idx = std.mem.indexOfAny(u8, line, " \t=") orelse return error.InvalidConfigSyntax;
            const key = line[0..sep_idx];

            const val_start_offset = std.mem.indexOfNone(u8, line[sep_idx..], " \t=") orelse return error.InvalidConfigSyntax;
            var value = line[sep_idx + val_start_offset ..];

            // this trimming is done manually to avoid accidentally stripping a valid trailing '='
            while (value.len > 0 and (value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) {
                value = value[0 .. value.len - 1];
            }

            if (key.len == 0 or value.len == 0) return error.InvalidConfigSyntax;

            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
            }

            try self.set(alloc, key, value);
        }
    }

    fn set(self: *ConfigFormat, alloc: Allocator, key: []const u8, value: []const u8) !void {
        const gop = try self.entries.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(gop.value_ptr.*);
            gop.value_ptr.* = try alloc.dupe(u8, value);
        } else {
            gop.key_ptr.* = try alloc.dupe(u8, key);
            gop.value_ptr.* = try alloc.dupe(u8, value);
        }
    }
};

const testing = std.testing;

test "parses dotted keys and both quoted and bare values" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc,
        \\identity.name "MM"
        \\identity.email "mm@merk.com"
        \\workspace.channel "main"
        \\history.sign false
    );
    defer cf.deinit(alloc);

    try testing.expectEqualStrings("MM", cf.get("identity.name").?);
    try testing.expectEqualStrings("mm@merk.com", cf.get("identity.email").?);
    try testing.expectEqualStrings("main", cf.get("workspace.channel").?);
    try testing.expectEqual(false, (try cf.getBool("history.sign")).?);
}

test "supports equal signs and spaces as separators" {
    const alloc = std.testing.allocator;
    var cf = try ConfigFormat.parse(alloc,
        \\identity.name=MM
        \\identity.email = "mm@merk.com"
        \\workspace.channel   "main"
        \\rel = "a=b"
    );
    defer cf.deinit(alloc);

    try std.testing.expectEqualStrings("MM", cf.get("identity.name").?);
    try std.testing.expectEqualStrings("mm@merk.com", cf.get("identity.email").?);
    try std.testing.expectEqualStrings("main", cf.get("workspace.channel").?);

    try std.testing.expectEqualStrings("a=b", cf.get("rel").?);
}

test "ignores comments and blank lines" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc,
        \\; a comment
        \\# also a comment
        \\
        \\identity.name "bnlvn"
        \\
    );
    defer cf.deinit(alloc);
    try testing.expectEqualStrings("bnlvn", cf.get("identity.name").?);
}

test "unquoted value is stored literally, not with quote-stripping applied twice" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc, "stage.mode snapshot\n");
    defer cf.deinit(alloc);
    try testing.expectEqualStrings("snapshot", cf.get("stage.mode").?);
}

test "duplicate key: last value wins" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc, "identity.name \"First\"\nidentity.name \"Second\"\n");
    defer cf.deinit(alloc);
    try testing.expectEqualStrings("Second", cf.get("identity.name").?);
}

test "mergeText lets a second file override individual keys from the first" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc,
        \\identity.name "User Level"
        \\identity.email "user@example.com"
        \\workspace.channel "main"
    );
    defer cf.deinit(alloc);

    try cf.mergeText(alloc, "identity.email \"repo@example.com\"\n");

    try testing.expectEqualStrings("User Level", cf.get("identity.name").?);
    try testing.expectEqualStrings("repo@example.com", cf.get("identity.email").?);
    try testing.expectEqualStrings("main", cf.get("workspace.channel").?);
}

test "a key with no value at all is a syntax error" {
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidConfigSyntax, ConfigFormat.parse(alloc, "identity.name\n"));
}

test "trailing whitespace with nothing after it is a syntax error, not an empty value" {
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidConfigSyntax, ConfigFormat.parse(alloc, "identity.name   \n"));
}

test "an explicit empty-quoted value is valid and distinct from the error above" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc, "identity.name \"\"\n");
    defer cf.deinit(alloc);
    try testing.expectEqualStrings("", cf.get("identity.name").?);
}
