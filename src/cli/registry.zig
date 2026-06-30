const std = @import("std");
const Command = @import("command.zig").Command;

const init = @import("../cmds/init.zig");
const add = @import("../cmds/add.zig");
const status = @import("../cmds/status.zig");
const diff = @import("../cmds/diff.zig");
const writeTree = @import("../cmds/write-tree.zig");
const commit = @import("../cmds/commit.zig");
const show = @import("../cmds/show.zig");
/// To add a new command, import its module and add its `.command` constant
pub const commands: []const Command = &[_]Command{
    init.command,
    add.command,
    status.command,
    diff.command,
    writeTree.command,
    commit.command,
    show.command,
};

/// Returns a pointer into the `commands` slice
pub fn find(name: []const u8) ?*const Command {
    for (commands) |*cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}
