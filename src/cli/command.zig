const std = @import("std");

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    usage: []const u8 = "",
    flags: []const Flag = &.{},
    run: *const fn (
        alloc: std.mem.Allocator,
        args: *std.process.ArgIterator,
    ) anyerror!void,

    pub fn printHelp(self: Command, writer: anytype) !void {
        try writer.print("usage: nodus {s}", .{self.name});
        if (self.usage.len > 0) {
            try writer.print(" {s}", .{self.usage});
        }
        try writer.writeByte('\n');

        if (self.description.len > 0) {
            try writer.writeByte('\n');
            try writer.print("{s}\n", .{self.description});
        }

        if (self.flags.len == 0) return;

        try writer.writeByte('\n');
        try writer.writeAll("options:\n");

        for (self.flags) |flag| {
            try writer.writeAll("  ");
            if (flag.short) |short| {
                try writer.print("-{c}", .{short});
                if (flag.long.len > 0) {
                    try writer.writeAll(", ");
                }
            }
            try writer.print("--{s}", .{flag.long});
            if (flag.kind == .value) {
                const value_name = flag.value_name orelse "value";
                try writer.print(" <{s}>", .{value_name});
            }
            if (flag.help.len > 0) {
                var used: usize = 4 + flag.long.len;
                if (flag.short != null) {
                    used += 4;
                }
                if (flag.kind == .value) {
                    const value_name = flag.value_name orelse "value";
                    used += value_name.len + 3;
                }
                if (used < 22) {
                    var pad: usize = 22 - used;
                    while (pad > 0) : (pad -= 1) {
                        try writer.writeByte(' ');
                    }
                } else {
                    try writer.writeByte(' ');
                }
                try writer.print("{s}", .{flag.help});
            }
            try writer.writeByte('\n');
        }

        try writer.writeAll("  -h, --help            show this help\n");
    }
};

pub const FlagKind = enum {
    boolean,
    value,
};

pub const Flag = struct {
    short: ?u8 = null,
    long: []const u8,
    kind: FlagKind,
    value_name: ?[]const u8 = null,
    help: []const u8 = "",
};

pub fn hasHelpFlag(args: *std.process.ArgIterator) bool {
    var peek = args.*;

    while (peek.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return true;
        }
    }

    return false;
}

pub fn printHelpToStdout(self: Command) void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    self.printHelp(writer) catch {};
    writer.flush() catch {};
}
