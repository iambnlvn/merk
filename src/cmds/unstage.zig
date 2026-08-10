const std = @import("std");

const repo_context = @import("repo_context.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len == 0) {
        try ctx.err.print("error: 'rm' requires at least one path\n", .{});
        command.printHelp(ctx.err) catch {};
        return error.MissingPath;
    }

    const cached = inv.flags.boolean("cached");

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const staging = &opened.repo.staging;
    const cwd = std.fs.cwd();

    // Validate every path is tracked before mutating anything, so a typo
    // partway through a multi-path `rm` doesn't leave the repo (or the
    // worktree) half-mutated.
    for (inv.positional.items) |path| {
        if (staging.lookup(path) == null) {
            try ctx.err.print("error: '{s}' is not tracked\n", .{path});
            return error.NotTracked;
        }
    }

    for (inv.positional.items) |path| {
        if (!cached) {
            const full_path = try std.fs.path.join(inv.alloc, &.{ opened.repo.root, path });
            defer inv.alloc.free(full_path);

            cwd.deleteFile(full_path) catch |err| switch (err) {
                // Already gone from the worktree (e.g. deleted by hand) —
                // still drop it from the staging below.
                error.FileNotFound => {},
                else => return err,
            };
        }
        // `staging.remove` shifts `entries` in place, so removing one path
        // at a time here is fine; `path_index` gets rebuilt once inside
        // `remove` and once more in `save` below — cheap relative to the
        // I/O either side of it.
        try staging.remove(path);
    }
    try staging.save();

    for (inv.positional.items) |path| {
        if (cached) {
            try ctx.out.print("removed (cached) {s}\n", .{path});
        } else {
            try ctx.out.print("removed {s}\n", .{path});
        }
    }
}

pub const command = Command{
    .name = "unstage",
    .description = "Remove paths from the staging and, unless --cached, the working tree.",
    .usage = "<path>...",
    .category = .staging,
    .flags = &.{
        .{
            .long = "cached",
            .kind = .boolean,
            .help = "only unstage; leave the working tree file alone",
        },
    },
    .run = run,
};
