const std = @import("std");
const diff_mod = @import("../core/diff.zig");

const repo_context = @import("repo_context.zig");
const errors_mod = @import("../cli/errors.zig");

const CommitDiff = diff_mod.CommitDiff;
const diffCommitAgainstParent = diff_mod.diffCommitAgainstParent;
const diffCommits = diff_mod.diffCommits;
const renderCommit = diff_mod.renderCommit;

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    var cd: CommitDiff = switch (inv.positional.items.len) {
        0 => blk: {
            const head = (try opened.repo.current()) orelse {
                try ctx.err.print("error: no commits yet\n", .{});
                return error.NoCommits;
            };
            break :blk try diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, head, .histogram);
        },
        1 => blk: {
            // `resolveRev` accepts both a full 64-char hash and an 8+ char
            // prefix, resolved the same way `diff --rev` resolves one —
            // see `Repository.resolveRev`'s doc comment.
            const target = opened.repo.resolveRev(inv.positional.items[0]) catch |err| return errors_mod.report(ctx, err);
            break :blk try diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, target, .histogram);
        },
        else => blk: {
            const old_hash = opened.repo.resolveRev(inv.positional.items[0]) catch |err| return errors_mod.report(ctx, err);
            const new_hash = opened.repo.resolveRev(inv.positional.items[1]) catch |err| return errors_mod.report(ctx, err);
            break :blk try diffCommits(inv.alloc, &opened.repo.store, &opened.repo.page_store, old_hash, new_hash, .histogram);
        },
    };
    defer cd.deinit(inv.alloc);

    try renderCommit(ctx.out, &cd, .{}, inv.alloc);
}

pub const command = Command{
    .name = "inspect",
    .description = "Show the changes between two commits, or a commit and its parent.",
    .usage = "[<commit-hash>] [<commit-hash>]",
    .category = .history,
    .flags = &.{},
    .run = run,
};
