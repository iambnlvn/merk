const std = @import("std");
const Command = @import("command.zig").Command;
const Category = @import("command.zig").Category;

const init = @import("../cmds/init.zig");
const stage = @import("../cmds/stage.zig");
const status = @import("../cmds/status.zig");
const diff = @import("../cmds/diff.zig");
const writeTree = @import("../cmds/write-tree.zig");
const commit = @import("../cmds/commit.zig");
const uncommit = @import("../cmds/uncommit.zig");
const inspect = @import("../cmds/inspect.zig");
const log = @import("../cmds/log.zig");
const unstage = @import("../cmds/unstage.zig");
const restore = @import("../cmds/restore.zig");
const mv = @import("../cmds/mv.zig");

/// To add a new command: import its module above, add its `.command`
/// constant here, and give the command a `.category` so it groups
/// correctly in `merk help`
pub const commands: []const Command = &[_]Command{
    init.command,
    stage.command,
    unstage.command,
    mv.command,
    restore.command,
    status.command,
    diff.command,
    writeTree.command,
    commit.command,
    uncommit.command,
    inspect.command,
    log.command,
};

/// Returns a pointer into the `commands` slice
pub fn find(name: []const u8) ?*const Command {
    for (commands) |*cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

/// All categories, in the order they should be displayed in help output.
pub const category_order = [_]Category{ .repository, .staging, .history, .plumbing };

/// Zero-allocation iterator over commands belonging to a single category,
/// preserving registration order within that category.
pub const CategoryIterator = struct {
    category: Category,
    index: usize = 0,

    pub fn next(self: *CategoryIterator) ?*const Command {
        while (self.index < commands.len) {
            const cmd = &commands[self.index];
            self.index += 1;
            if (cmd.category == self.category) return cmd;
        }
        return null;
    }
};

pub fn commandsInCategory(category: Category) CategoryIterator {
    return .{ .category = category };
}
