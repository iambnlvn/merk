const std = @import("std");
const nodus = @import("nodus");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    var store = try nodus.object.Store.init(inv.alloc, ctx.repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(inv.alloc, ctx.repo_root);
    defer index.deinit();

    try index.save();

    std.debug.print("initialized .nodus\n", .{});
}

pub const command = Command{
    .name = "init",
    .description = "Initialize a new nodus repository.",
    .run = run,
};
