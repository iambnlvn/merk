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
        std.debug.print("error: 'restore' requires at least one path\n", .{});
        command.printHelpToStderr();
        return error.MissingPath;
    }

    const staged = inv.flags.boolean("staged");

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const index = &opened.repo.index;

    if (staged) {
        // Drop from the index without touching the worktree file — the
        // same semantics as `Repository.unstage` (mirrors `git reset
        // <path>`, not `checkout`), applied here directly against the
        // index so a multi-path call does one `save` instead of one per
        // path.
        for (inv.positional.items) |path| {
            if (index.lookup(path) == null) {
                std.debug.print("error: '{s}' is not staged\n", .{path});
                return error.NotStaged;
            }
        }
        for (inv.positional.items) |path| try index.remove(path);
        try index.save();

        for (inv.positional.items) |path| {
            std.debug.print("unstaged {s}\n", .{path});
        }
        return;
    }

    // Default: overwrite the working tree file(s) with the index's
    // version — same read-blob-then-write-file shape as
    // `Repository.writeEntriesToWorktree`, just for the paths given
    // rather than every tracked entry.
    const cwd = std.fs.cwd();

    for (inv.positional.items) |path| {
        const entry = index.lookup(path) orelse {
            std.debug.print("error: '{s}' is not tracked\n", .{path});
            return error.NotTracked;
        };

        const obj = try opened.repo.store.get(entry.blob_hash);
        defer inv.alloc.free(obj.payload);

        const full_path = try std.fs.path.join(inv.alloc, &.{ opened.repo.root, path });
        defer inv.alloc.free(full_path);

        if (std.fs.path.dirname(full_path)) |d| try cwd.makePath(d);
        try cwd.writeFile(.{ .sub_path = full_path, .data = obj.payload });
    }

    for (inv.positional.items) |path| {
        std.debug.print("restored {s}\n", .{path});
    }
}

pub const command = Command{
    .name = "restore",
    .description = "Restore working tree paths from the index, or unstage them with --staged.",
    .usage = "<path>...",
    .flags = &.{
        .{
            .long = "staged",
            .kind = .boolean,
            .help = "unstage the path(s) instead of touching the working tree",
        },
    },
    .run = run,
};
