const std = @import("std");
const nodus = @import("nodus");

const registry = @import("cli/registry.zig");
const usage = @import("cli/usage.zig");
const cli = @import("cli/command.zig");

pub fn main() void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const alloc = debug_alloc.allocator();

    run(alloc) catch |err| switch (err) {
        cli.Error.HelpRequested => {},

        cli.Error.UnknownFlag,
        cli.Error.MissingValue,
        cli.Error.UnexpectedValue,
        cli.Error.MissingRequired,
        cli.Error.Overflow,
        => {
            // Flag-parse errors print their own message; just exit non-zero
            std.process.exit(1);
        },

        else => {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };
}

fn run(alloc: std.mem.Allocator) anyerror!void {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();

    const cmd_name = args.next() orelse {
        usage.print();
        return;
    };

    if (std.mem.eql(u8, cmd_name, "--help") or
        std.mem.eql(u8, cmd_name, "-h") or
        std.mem.eql(u8, cmd_name, "help"))
    {
        usage.print();
        return;
    }

    const cmd = registry.find(cmd_name) orelse {
        std.debug.print("nodus: '{s}' is not a known command\n\n", .{cmd_name});
        usage.print();
        std.process.exit(1);
    };

    var inv = try cmd.parseArgs(alloc, &args);
    defer inv.deinit();

    try cmd.run(&inv);
}
