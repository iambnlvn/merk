const std = @import("std");
const registry = @import("registry.zig");

pub fn print(w: *std.Io.Writer) void {
    w.writeAll(
        \\merk — a content-addressed version control system
        \\
        \\Usage
        \\  merk <command> [options] [arguments]
        \\
    ) catch return;

    for (registry.category_order) |category| {
        var it = registry.commandsInCategory(category);

        const first = it.next() orelse continue;

        w.print("\n{s}\n", .{category.label()}) catch return;
        w.print("  {s:<16} {s}\n", .{ first.name, first.description }) catch return;
        while (it.next()) |cmd| {
            w.print("  {s:<16} {s}\n", .{ cmd.name, cmd.description }) catch return;
        }
    }

    w.writeAll(
        \\
        \\Examples
        \\  merk init
        \\  merk snapshot --all
        \\  merk commit -m "Initial import"
        \\  merk log
        \\  merk status
        \\
        \\merk 0.1.0
        \\
        \\Run `merk help <command>` for detailed documentation.
    ) catch return;

    w.flush() catch {};
}
