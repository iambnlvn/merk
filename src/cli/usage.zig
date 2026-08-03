const std = @import("std");
const registry = @import("registry.zig");

pub fn print(w: *std.Io.Writer) void {
    w.writeAll(
        \\merk — a content-addressed version control system
        \\
        \\Usage
        \\  merk <command> [options] [arguments]
        \\
        \\Common commands
        \\
    ) catch return;

    for (registry.commands) |cmd| {
        w.print("  {s:<16} {s}\n", .{ cmd.name, cmd.description }) catch return;
    }

    w.writeAll(
        \\
        \\Examples
        \\  merk init
        \\  merk snapshot --all
        \\  merk commit -m "Initial import"
        \\  merk history
        \\  merk status
        \\
        \\merk 0.1.0
        \\
        \\Run `merk help <command>` for detailed documentation.
    ) catch return;

    w.flush() catch {};
}
