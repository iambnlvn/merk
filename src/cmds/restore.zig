const std = @import("std");

const repo_context = @import("repo_context.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len == 0) {
        try ctx.err.print("error: 'restore' requires at least one path\n", .{});
        command.printHelp(ctx.err) catch {};
        return error.MissingPath;
    }

    const staged = inv.flags.boolean("staged");
    const paths = inv.positional.items;

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    if (staged) {
        opened.repo.unstagePaths(paths) catch |err| switch (err) {
            error.NotTracked => {
                try ctx.err.print("error: one or more paths are not staged\n", .{});
                return err;
            },
            else => return err,
        };
        for (paths) |path| try ctx.out.print("unstaged {s}\n", .{path});
        return;
    }

    opened.repo.restorePaths(paths) catch |err| switch (err) {
        error.NotTracked => {
            try ctx.err.print("error: one or more paths are not tracked\n", .{});
            return err;
        },
        else => return err,
    };
    for (paths) |path| try ctx.out.print("restored {s}\n", .{path});
}

pub const command = Command{
    .name = "restore",
    .description = "Restore working tree paths from the index, or unstage them with --staged.",
    .usage = "<path>...",
    .category = .snapshot,
    .flags = &.{
        .{
            .long = "staged",
            .kind = .boolean,
            .help = "unstage the path(s) instead of touching the working tree",
        },
    },
    .run = run,
};
