const std = @import("std");
const testing = std.testing;

const config_format = @import("format.zig");
const ConfigFormat = config_format.ConfigFormat;

pub const Schema = struct {
    @"identity.name": ?[]const u8 = null,
    @"identity.email": ?[]const u8 = null,
    @"workspace.channel": ?[]const u8 = null,
    @"workspace.ignore": ?[]const u8 = null,

    @"history.sign": ?bool = null,

    @"commit.intent": ?[]const u8 = null,

    ///falls back to `$merk_AUTHOR_NAME` / `$USER`.
    @"commit.author": ?[]const u8 = null,

    /// falls back to`$merk_AUTHOR_EMAIL`.
    @"commit.author_email": ?[]const u8 = null,

    @"commit.committer": ?[]const u8 = null,

    @"commit.committer_email": ?[]const u8 = null,

    @"commit.no_body_trailers": ?bool = null,
};

pub fn reflect(comptime T: type, cf: *const ConfigFormat) !T {
    var result: T = .{};
    inline for (std.meta.fields(T)) |field| {
        if (cf.get(field.name)) |raw| {
            @field(result, field.name) = try parseValue(field.type, raw);
        }
    }
    return result;
}

fn parseValue(comptime FieldType: type, raw: []const u8) !FieldType {
    return switch (@typeInfo(FieldType)) {
        .optional => |opt| try parseValue(opt.child, raw),

        .bool => if (std.mem.eql(u8, raw, "true"))
            true
        else if (std.mem.eql(u8, raw, "false"))
            false
        else
            error.InvalidBooleanValue,

        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8)
            raw
        else
            @compileError("unsupported config field pointer type: " ++ @typeName(FieldType)),

        .@"enum" => std.meta.stringToEnum(FieldType, raw) orelse error.InvalidConfigValue,

        .int => std.fmt.parseInt(FieldType, raw, 10) catch error.InvalidConfigValue,

        else => @compileError("unsupported config field type: " ++ @typeName(FieldType)),
    };
}

test "reflect leaves unset fields at their default" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc, "identity.name \"bnlvn\"\n");
    defer cf.deinit(alloc);

    const settings = try reflect(Schema, &cf);
    try testing.expectEqualStrings("bnlvn", settings.@"identity.name".?);
    try testing.expect(settings.@"identity.email" == null);
    try testing.expect(settings.@"history.sign" == null);
}

test "reflect populates every field across the full v1 schema" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc,
        \\identity.name "bnlvn"
        \\identity.email "test@test.com"
        \\workspace.channel "main"
        \\workspace.ignore ".merkignore"
        \\history.sign false
    );
    defer cf.deinit(alloc);

    const settings = try reflect(Schema, &cf);
    try testing.expectEqualStrings("bnlvn", settings.@"identity.name".?);
    try testing.expectEqualStrings("test@test.com", settings.@"identity.email".?);
    try testing.expectEqualStrings("main", settings.@"workspace.channel".?);
    try testing.expectEqualStrings(".merkignore", settings.@"workspace.ignore".?);
    try testing.expectEqual(false, settings.@"history.sign".?);
}

test "reflect populates the commit.* keys mirrored from commit.zig's flags" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc,
        \\commit.intent "fix"
        \\commit.author "bnlvn"
        \\commit.author_email "bnlvn@merk.com"
        \\commit.committer "release-test"
        \\commit.committer_email "test@merk.com"
        \\commit.no_body_trailers true
    );
    defer cf.deinit(alloc);

    const settings = try reflect(Schema, &cf);
    try testing.expectEqualStrings("fix", settings.@"commit.intent".?);
    try testing.expectEqualStrings("bnlvn", settings.@"commit.author".?);
    try testing.expectEqualStrings("bnlvn@merk.com", settings.@"commit.author_email".?);
    try testing.expectEqualStrings("release-test", settings.@"commit.committer".?);
    try testing.expectEqualStrings("test@merk.com", settings.@"commit.committer_email".?);
    try testing.expectEqual(true, settings.@"commit.no_body_trailers".?);
}

test "commit.* keys default to null (unset), same as every other optional field" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc, "identity.name \"bnlvn\"\n");
    defer cf.deinit(alloc);

    const settings = try reflect(Schema, &cf);

    try testing.expect(settings.@"commit.intent" == null);
    try testing.expect(settings.@"commit.committer" == null);
    try testing.expect(settings.@"commit.no_body_trailers" == null);
}

test "reflect propagates InvalidBooleanValue for a malformed bool field" {
    const alloc = testing.allocator;
    var cf = try ConfigFormat.parse(alloc, "history.sign yes\n");
    defer cf.deinit(alloc);

    try testing.expectError(error.InvalidBooleanValue, reflect(Schema, &cf));
}

test "parseValue: enum fields validate against the enum's members" {
    const Color = enum { red, green, blue };
    try testing.expectEqual(Color.green, try parseValue(?Color, "green"));
    try testing.expectError(error.InvalidConfigValue, parseValue(?Color, "chartreuse"));
}

test "parseValue: int fields parse and reject non-numeric input" {
    try testing.expectEqual(@as(u32, 42), try parseValue(?u32, "42"));
    try testing.expectError(error.InvalidConfigValue, parseValue(?u32, "forty-two"));
}

test {
    testing.refAllDecls(@This());
}
