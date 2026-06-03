const std = @import("std");

pub const Parsed = struct {
    command: []const u8,
};

pub fn parse(args: *std.process.ArgIterator) ?Parsed {
    _ = args.next(); // skip binary name

    const cmd = args.next() orelse return null;

    return .{
        .command = cmd,
    };
}
