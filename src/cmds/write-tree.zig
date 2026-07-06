const std = @import("std");
const nodus = @import("nodus");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;

const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    var index = try nodus.index.Index.init(inv.alloc, ctx.repo_root);
    defer index.deinit();
    try index.load();
    try index.save();

    const hex = try nodus.hash.toHex(inv.alloc, index.index_root);
    defer inv.alloc.free(hex);

    std.debug.print("{s}\n", .{hex});
}

pub const command = Command{
    .name = "write-tree",
    .description = "Write the current index as a Merkle root.",
    .run = run,
};
