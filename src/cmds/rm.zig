const std = @import("std");
const merk = @import("merk");

const repo_context = @import("repo_context.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len == 0) {
        std.debug.print("error: 'rm' requires at least one path\n", .{});
        command.printHelpToStderr();
        return error.MissingPath;
    }

    const cached = inv.flags.boolean("cached");

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const index = &opened.repo.index;
    const cwd = std.fs.cwd();

    // Validate every path is tracked before mutating anything, so a typo
    // partway through a multi-path `rm` doesn't leave the repo (or the
    // worktree) half-mutated.
    for (inv.positional.items) |path| {
        if (index.lookup(path) == null) {
            std.debug.print("error: '{s}' is not tracked\n", .{path});
            return error.NotTracked;
        }
    }

    for (inv.positional.items) |path| {
        if (!cached) {
            const full_path = try std.fs.path.join(inv.alloc, &.{ opened.repo.root, path });
            defer inv.alloc.free(full_path);

            cwd.deleteFile(full_path) catch |err| switch (err) {
                // Already gone from the worktree (e.g. deleted by hand) —
                // still drop it from the index below.
                error.FileNotFound => {},
                else => return err,
            };
        }
        // `Index.remove` shifts `entries` in place, so removing one path
        // at a time here is fine; `path_index` gets rebuilt once inside
        // `remove` and once more in `save` below — cheap relative to the
        // I/O either side of it.
        try index.remove(path);
    }
    try index.save();

    for (inv.positional.items) |path| {
        if (cached) {
            std.debug.print("removed (cached) {s}\n", .{path});
        } else {
            std.debug.print("removed {s}\n", .{path});
        }
    }
}

pub const command = Command{
    .name = "rm",
    .description = "Remove paths from the index and, unless --cached, the working tree.",
    .usage = "<path>...",
    .flags = &.{
        .{ .long = "cached", .kind = .boolean, .help = "only unstage; leave the working tree file alone" },
    },
    .run = run,
};
