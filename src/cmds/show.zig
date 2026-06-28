const std = @import("std");
const nodus = @import("nodus");
const diff = nodus.diff;
const refs = nodus.refs;
const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    var store = try nodus.object.Store.init(inv.alloc, ctx.repo_root);
    defer store.deinit();

    var nodus_dir = try std.fs.cwd().openDir(".nodus", .{});
    defer nodus_dir.close();

    var cd: diff.CommitDiff = switch (inv.positional.items.len) {
        0 => blk: {
            const head = try refs.resolveHead(inv.alloc, nodus_dir) orelse {
                std.debug.print("error: no commits yet\n", .{});
                return error.NoCommits;
            };
            break :blk try diff.diffCommitAgainstParent(inv.alloc, &store, head, .histogram);
        },
        1 => blk: {
            const target = try nodus.hash.fromHex(inv.positional.items[0]);
            break :blk try diff.diffCommitAgainstParent(inv.alloc, &store, target, .histogram);
        },
        else => blk: {
            const old_hash = try nodus.hash.fromHex(inv.positional.items[0]);
            const new_hash = try nodus.hash.fromHex(inv.positional.items[1]);
            break :blk try diff.diffCommits(inv.alloc, &store, old_hash, new_hash, .histogram);
        },
    };
    defer cd.deinit(inv.alloc);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    try diff.renderCommit(writer, &cd, .{}, inv.alloc);
    try writer.flush();
}

pub const command = Command{
    .name = "show",
    .description = "Show the changes between two commits, or a commit and its parent.",
    .usage = "[<commit-hash>] [<commit-hash>]",
    .flags = &.{},
    .run = run,
};
