const std = @import("std");
const Command = @import("command.zig").Command;
const nodus = @import("nodus");
const init = @import("../cmds/init.zig");
const add = @import("../cmds/add.zig");
const status = @import("../cmds/status.zig");
const diff = @import("../cmds/diff.zig");
const writeTree = @import("../cmds/write-tree.zig");

// used to register cmds only
pub const commands = [_]Command{
    init.command,
    add.command,
    status.command,
    diff.command,
    writeTree.command,
};

pub fn find(name: []const u8) ?Command {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name))
            return cmd;
    }
    return null;
}
