const std = @import("std");
const crypto = @import("crypto");

const repo_context = @import("repo_context.zig");
const errors_mod = @import("../cli/errors.zig");
const repository_mod = @import("../core/repository.zig");
const UncommitMode = repository_mod.Repository.UncommitMode;

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    const hard = inv.flags.boolean("hard");
    const mixed = inv.flags.boolean("mixed");
    const keep = inv.flags.boolean("keep");
    const confirmed = inv.flags.boolean("yes");

    const modes_given = @as(u8, @intFromBool(hard)) + @intFromBool(mixed) + @intFromBool(keep);
    if (modes_given > 1) {
        try ctx.err.print("error: --hard, --mixed, and --keep are mutually exclusive\n", .{});
        return error.ConflictingUncommitMode;
    }

    const mode: UncommitMode = if (hard) .hard else if (mixed) .mixed else if (keep) .keep else .soft;

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const track_name = opened.repo.channel.raw;

    const result = opened.repo.uncommit(.{
        .mode = mode,
        .confirm_root_hard = confirmed,
    }) catch |err| switch (err) {
        error.RootHardUncommitRequiresConfirmation => {
            try ctx.err.print(
                "error: uncommitting the root commit with --hard deletes tracked files from the working tree, with nothing else reachable pointing at their content; pass --yes to confirm\n",
                .{},
            );
            return err;
        },
        error.MergeCommit => {
            try ctx.err.print(
                "error: HEAD is a merge commit; uncommit only supports linear history\n",
                .{},
            );
            return err;
        },
        error.TrackedPathsMissing => {
            try ctx.err.print(
                "error: --keep needs every tracked path to still exist on disk; some were deleted since the commit\n",
                .{},
            );
            return err;
        },
        else => return errors_mod.report(ctx, err),
    };

    const undone_hex = try crypto.toHex(inv.alloc, result.undone);
    defer inv.alloc.free(undone_hex);

    try ctx.out.print("undone         {s}\n", .{undone_hex});

    if (result.new_current) |new_hash| {
        const new_hex = try crypto.toHex(inv.alloc, new_hash);
        defer inv.alloc.free(new_hex);

        try ctx.out.print("{s} is now at  {s}\n", .{ track_name, new_hex });
    } else {
        try ctx.out.print("{s} is now at  (no commits)\n", .{track_name});
        try ctx.out.print(
            "\nThat was the root commit — '{s}' has no commits now.\n",
            .{track_name},
        );
    }

    switch (mode) {
        .soft => try ctx.out.print(
            "\nChanges from the undone commit are still staged — edit and re-run\n`merk commit` when ready, or `merk restore --staged <path>` to drop\nspecific files back out of staging.\n",
            .{},
        ),
        .mixed => try ctx.out.print(
            "\nStaging now matches the parent commit's tree; the working tree is untouched.\n",
            .{},
        ),
        .hard => try ctx.out.print(
            "\nStaging and the working tree now match the parent commit.\n",
            .{},
        ),
        .keep => try ctx.out.print(
            "\nStaging was rebuilt from the current on-disk content of every tracked path,\nso edits made after the commit are preserved as the new staged state.\n",
            .{},
        ),
    }
}

pub const command = Command{
    .name = "uncommit",
    .description = "Move the current track back to its parent, undoing the last commit.",
    .usage = "[--hard | --mixed | --keep] [--yes]",
    .category = .history,
    .flags = &.{
        .{
            .long = "hard",
            .kind = .boolean,
            .help = "reset staging AND the working tree to the parent commit (destructive)",
        },
        .{
            .long = "mixed",
            .kind = .boolean,
            .help = "reset staging to the parent commit; leave the working tree alone",
        },
        .{
            .long = "keep",
            .kind = .boolean,
            .help = "rebuild staging from the current on-disk content of tracked paths",
        },
        .{
            .long = "yes",
            .short = "y",
            .kind = .boolean,
            .help = "confirm a --hard uncommit of the root commit (deletes tracked files)",
        },
    },
    .run = run,
};
