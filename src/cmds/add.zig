const std = @import("std");
const merk = @import("merk");

const repo_context = @import("repo_context.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len == 0) {
        std.debug.print("error: 'add' requires at least one path\n", .{});
        command.printHelpToStderr();
        return error.MissingPath;
    }

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    try opened.repo.add(inv.positional.items);

    for (inv.positional.items) |path| {
        std.debug.print("staged {s}\n", .{path});
    }
}

pub const command = Command{
    .name = "add",
    .description = "Stage paths in the index.",
    .usage = "<path>...",
    .run = run,
};
