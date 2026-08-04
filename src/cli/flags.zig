/// Command handlers pull raw strings from `FlagMap` and convert them here.
/// Every `parse*` function returns `null` on bad input so callers can decide
/// whether to fall back to a default or emit an error.
const std = @import("std");

pub fn parseEnum(comptime T: type, raw: []const u8) ?T {
    return std.meta.stringToEnum(T, raw);
}

pub fn parseBool(raw: []const u8) ?bool {
    const true_values = .{ "1", "true", "yes", "on" };
    const false_values = .{ "0", "false", "no", "off" };

    inline for (true_values) |val| {
        if (std.ascii.eqlIgnoreCase(raw, val)) return true;
    }

    inline for (false_values) |val| {
        if (std.ascii.eqlIgnoreCase(raw, val)) return false;
    }

    return null;
}

pub fn parseUnsigned(comptime T: type, raw: []const u8) ?T {
    return std.fmt.parseUnsigned(T, raw, 10) catch null;
}

pub fn parseInt(comptime T: type, raw: []const u8) ?T {
    return std.fmt.parseInt(T, raw, 10) catch null;
}

pub fn parseFloat(comptime T: type, raw: []const u8) ?T {
    return std.fmt.parseFloat(T, raw) catch null;
}
