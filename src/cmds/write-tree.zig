//TODO: wip

const std = @import("std");
const crypto = @import("crypto");

const repo_context = @import("repo_context.zig");
const errors_mod = @import("../cli/errors.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    _ = inv;

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const root_hash = opened.repo.stagedRoot() catch |err| return errors_mod.report(ctx, err);

    const hex = try crypto.toHex(ctx.alloc, root_hash);
    defer ctx.alloc.free(hex);

    try ctx.out.print("{s}\n", .{hex});
}

pub const command = Command{
    .name = "write-tree",
    .description = "Write the current staging area as a Merkle root.",
    .category = .plumbing,
    .run = run,
};
