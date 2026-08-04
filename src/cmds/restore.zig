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
        try ctx.err.writeAll(
            \\error: expected at least one path
            \\
        );
        command.printHelp(ctx.err) catch {};
        return error.MissingPath;
    }

    const staged = inv.flags.boolean("staged");

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const index = &opened.repo.index;

    if (staged) {
        // Remove paths from the pending snapshot.
        for (inv.positional.items) |path| {
            if (index.lookup(path) == null) {
                try ctx.err.print(
                    "error: path '{s}' is not in the pending snapshot\n",
                    .{path},
                );
                return error.NotStaged;
            }
        }

        for (inv.positional.items) |path| {
            try index.remove(path);
        }

        try index.save();

        if (inv.positional.items.len == 1) {
            try ctx.out.print(
                "Removed '{s}' from the pending snapshot.\n",
                .{inv.positional.items[0]},
            );
        } else {
            try ctx.out.print(
                "Removed {d} paths from the pending snapshot.\n",
                .{inv.positional.items.len},
            );
        }

        return;
    }

    // Restore working tree files from the pending snapshot.
    const cwd = std.fs.cwd();

    for (inv.positional.items) |path| {
        const entry = index.lookup(path) orelse {
            try ctx.err.print(
                "error: path '{s}' is not tracked by this repository\n",
                .{path},
            );
            return error.NotTracked;
        };

        const obj = try opened.repo.store.get(entry.blob_hash);
        defer inv.alloc.free(obj.payload);

        const full_path = try std.fs.path.join(inv.alloc, &.{ opened.repo.root, path });
        defer inv.alloc.free(full_path);

        if (std.fs.path.dirname(full_path)) |dir| {
            try cwd.makePath(dir);
        }

        try cwd.writeFile(.{
            .sub_path = full_path,
            .data = obj.payload,
        });
    }

    if (inv.positional.items.len == 1) {
        try ctx.out.print(
            "Restored '{s}'.\n",
            .{inv.positional.items[0]},
        );
    } else {
        try ctx.out.print(
            "Restored {d} paths.\n",
            .{inv.positional.items.len},
        );
    }
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
