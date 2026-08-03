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

pub fn run(ctx: Context, inv: *Invocation) !void {
    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    var cd: diff_algorithms.CommitDiff = switch (inv.positional.items.len) {
        0 => blk: {
            const head = (try opened.repo.ref_store.readTrack(opened.repo.current_track)) orelse {
                std.debug.print("error: no commits yet\n", .{});
                return error.NoCommits;
            };
            break :blk try diff_snapshot.diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, head, .histogram);
        },
        1 => blk: {
            const target = try merk.crypto.hash.fromHex(inv.positional.items[0]);
            break :blk try diff_snapshot.diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, target, .histogram);
        },
        else => blk: {
            const old_hash = try merk.crypto.hash.fromHex(inv.positional.items[0]);
            const new_hash = try merk.crypto.hash.fromHex(inv.positional.items[1]);
            break :blk try diff_snapshot.diffCommits(inv.alloc, &opened.repo.store, &opened.repo.page_store, old_hash, new_hash, .histogram);
        },
    };
    defer cd.deinit(inv.alloc);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    try diff_render.renderCommit(writer, &cd, .{}, inv.alloc);
    try writer.flush();
}

pub const command = Command{
    .name = "show",
    .description = "Show the changes between two commits, or a commit and its parent.",
    .usage = "[<commit-hash>] [<commit-hash>]",
    .flags = &.{},
    .run = run,
};
