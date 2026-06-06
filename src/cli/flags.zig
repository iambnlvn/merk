const std = @import("std");

pub const Error = error{
    MissingValue,
    InvalidValue,
};

pub fn inlineValue(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    if (arg.len <= prefix.len + 1) return null;
    if (arg[prefix.len] != '=') return null;
    return arg[prefix.len + 1 ..];
}

pub fn nextValue(args: *std.process.ArgIterator) ![]const u8 {
    return args.next() orelse Error.MissingValue;
}

pub fn parseEnum(comptime T: type, raw: []const u8) ?T {
    return std.meta.stringToEnum(T, raw);
}

pub fn parseBool(raw: []const u8) ?bool {
    if (std.mem.eql(u8, raw, "1") or std.ascii.eqlIgnoreCase(raw, "true") or std.ascii.eqlIgnoreCase(raw, "yes") or std.ascii.eqlIgnoreCase(raw, "on")) {
        return true;
    }
    if (std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "false") or std.ascii.eqlIgnoreCase(raw, "no") or std.ascii.eqlIgnoreCase(raw, "off")) {
        return false;
    }
    return null;
}

pub fn parseUnsigned(comptime T: type, raw: []const u8) ?T {
    return std.fmt.parseInt(T, raw, 10) catch null;
}
