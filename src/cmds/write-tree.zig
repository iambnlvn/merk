const std = @import("std");
const nodus = @import("nodus");

const repo_root = ".";
const Command = @import("../cli/command.zig").Command;

pub fn run(
    alloc: std.mem.Allocator,
    args: *std.process.ArgIterator,
) !void {
    _ = args;

    var store = try nodus.object.Store.init(alloc, repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(alloc, repo_root);
    defer index.deinit();

    try index.load();

    const tree_hash = try nodus.tree.writeFromIndex(
        alloc,
        &store,
        index.entries.items,
    );

    const hex = try nodus.hash.toHex(alloc, tree_hash);
    defer alloc.free(hex);

    std.debug.print("{s}\n", .{hex});
}

pub const command = Command{
    .name = "write-tree",
    .run = run,
};
