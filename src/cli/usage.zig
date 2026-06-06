const std = @import("std");
const registry = @import("registry.zig");

pub fn print() void {
    std.debug.print(
        \\usage:
        \\  nodus <command>
        \\
        \\commands:
        \\
    , .{});

    for (registry.commands) |cmd| {
        std.debug.print("  {s: <12} {s}\n", .{ cmd.name, cmd.description });
    }
}
