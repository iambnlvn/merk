const std = @import("std");

const registry = @import("cli/registry.zig");
const usage = @import("cli/usage.zig");
const cli = @import("cli/command.zig");
const Context = @import("cli/context.zig").Context;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("warning: memory leak detected\n", .{});
        }
    }
    const alloc = gpa.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    defer stdout_writer.interface.flush() catch {};
    defer stderr_writer.interface.flush() catch {};

    run(alloc, &stdout_writer.interface, &stderr_writer.interface) catch |err| switch (err) {
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
            stdout_writer.interface.flush() catch {};
            stderr_writer.interface.flush() catch {};
            std.process.exit(1);
        },
    };
}

fn run(alloc: std.mem.Allocator, out: *std.Io.Writer, err_w: *std.Io.Writer) anyerror!void {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();

    const cmd_name = args.next() orelse {
        usage.print(err_w);
        return;
    };

    if (std.mem.eql(u8, cmd_name, "--help") or
        std.mem.eql(u8, cmd_name, "-h") or
        std.mem.eql(u8, cmd_name, "help"))
    {
        usage.print(err_w);
        return;
    }

    const cmd = registry.find(cmd_name) orelse {
        err_w.print("merk: '{s}' is not a known command\n\n", .{cmd_name}) catch {};
        usage.print(err_w);
        err_w.flush() catch {};
        std.process.exit(1);
    };

    var inv = try cmd.parseArgs(alloc, &args, err_w);
    defer inv.deinit();

    const ctx = Context{ .alloc = alloc, .repo_root = ".", .out = out, .err = err_w };

    try cmd.run(ctx, &inv);
}
