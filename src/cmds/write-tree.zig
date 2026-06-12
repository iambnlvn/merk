const std = @import("std");
const nodus = @import("nodus");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;

const repo_root = ".";

pub fn run(inv: *Invocation) !void {
    var store = try nodus.object.Store.init(inv.alloc, repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(inv.alloc, repo_root);
    defer index.deinit();
    try index.load();

    const tree_hash = try nodus.tree.writeFromIndex(
        inv.alloc,
        &store,
        index.entries.items,
    );

    const hex = try nodus.hash.toHex(inv.alloc, tree_hash);
    defer inv.alloc.free(hex);

    std.debug.print("{s}\n", .{hex});
}

pub const command = Command{
    .name = "write-tree",
    .description = "Write the current index as a tree object.",
    .run = run,
};
