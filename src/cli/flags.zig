/// Command handlers pull raw strings from `FlagMap` and convert them here
/// All functions return `null` on bad input so callers can emit an error
const std = @import("std");

pub fn parseEnum(comptime T: type, raw: []const u8) ?T {
    return std.meta.stringToEnum(T, raw);
}

pub fn parseBool(raw: []const u8) ?bool {
    if (std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on")) return true;

    if (std.mem.eql(u8, raw, "0") or
        std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        std.ascii.eqlIgnoreCase(raw, "off")) return false;

    return null;
}

pub fn parseUnsigned(comptime T: type, raw: []const u8) ?T {
    return std.fmt.parseInt(T, raw, 10) catch null;
}

pub fn parseInt(comptime T: type, raw: []const u8) ?T {
    return std.fmt.parseInt(T, raw, 10) catch null;
}
