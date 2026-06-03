const std = @import("std");
const Command = @import("command.zig").Command;
const nodus = @import("nodus");

// used to register cmds only
pub const commands = [_]Command{};

pub fn find(name: []const u8) ?Command {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name))
            return cmd;
    }
    return null;
}
