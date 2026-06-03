const std = @import("std");

pub const Command = struct {
    name: []const u8,
    run: *const fn (
        alloc: std.mem.Allocator,
        args: *std.process.ArgIterator,
    ) anyerror!void,
};
