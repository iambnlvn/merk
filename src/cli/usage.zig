const std = @import("std");
const registry = @import("registry.zig");

pub fn print() void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const w = &stderr_writer.interface;

    w.writeAll(
        \\usage:
        \\  nodus <command> [options] [args]
        \\
        \\commands:
        \\
    ) catch return;

    for (registry.commands) |cmd| {
        w.print("  {s: <14} {s}\n", .{ cmd.name, cmd.description }) catch return;
    }

    w.writeAll(
        \\
        \\Run `nodus <command> --help` for command-specific options.
        \\
    ) catch return;

    w.flush() catch {};
}
