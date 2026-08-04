const std = @import("std");
const merk = @import("merk");
const diff_mod = @import("../core/diff.zig");
const diff_algorithms = diff_mod.diff_algorithms;
const diff_snapshot = diff_mod.diff_snapshot;
const diff_render = diff_mod.diff_render;
const index = @import("../core/index.zig").Index;

const repo_context = @import("repo_context.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

/// Resolves a commit reference the same way diff's --rev does: a full
/// 64-char hex hash, or a short (8+ char) prefix resolved against the
/// object store. Kept consistent between the two commands so a hash
/// copy-pasted from one always works in the other.
fn resolveCommit(ctx: Context, opened: repo_context.Opened, raw: []const u8) !merk.crypto.hash.Hash {
    return merk.crypto.hash.fromHex(raw) catch {
        return opened.repo.store.resolveHashPrefix(raw) catch |e| {
            switch (e) {
                error.Ambiguous => ctx.err.print("error: ambiguous hash '{s}' (matches multiple objects)\n", .{raw}) catch {},
                error.NotFound => ctx.err.print("error: '{s}' not found\n", .{raw}) catch {},
                else => ctx.err.print("error: invalid hash '{s}'\n", .{raw}) catch {},
            }
            return error.InvalidRev;
        };
    };
}

pub fn run(ctx: Context, inv: *Invocation) !void {
    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    var cd: diff_algorithms.CommitDiff = switch (inv.positional.items.len) {
        0 => blk: {
            const head = (try opened.repo.ref_store.readTrack(opened.repo.current_track)) orelse {
                try ctx.err.print("error: no commits yet\n", .{});
                return error.NoCommits;
            };
            break :blk try diff_snapshot.diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, head, .histogram);
        },
        1 => blk: {
            const target = try resolveCommit(ctx, opened, inv.positional.items[0]);
            break :blk try diff_snapshot.diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, target, .histogram);
        },
        else => blk: {
            const old_hash = try resolveCommit(ctx, opened, inv.positional.items[0]);
            const new_hash = try resolveCommit(ctx, opened, inv.positional.items[1]);
            break :blk try diff_snapshot.diffCommits(inv.alloc, &opened.repo.store, &opened.repo.page_store, old_hash, new_hash, .histogram);
        },
    };
    defer cd.deinit(inv.alloc);

    try diff_render.renderCommit(ctx.out, &cd, .{}, inv.alloc);
}

pub const command = Command{
    .name = "show",
    .description = "Show the changes between two commits, or a commit and its parent.",
    .usage = "[<commit-hash>] [<commit-hash>]",
    .category = .history,
    .flags = &.{},
    .run = run,
};
