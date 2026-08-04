const std = @import("std");
const merk = @import("merk");

const repo_context = @import("repo_context.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    _ = inv;

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    // index was already loaded by Repository.open; re-save just to
    // match the original command's "load then save" round-trip
    // (harmless no-op if nothing changed since load).
    try opened.repo.index.save();

    const hex = try merk.crypto.hash.toHex(ctx.alloc, opened.repo.index.index_root);
    defer ctx.alloc.free(hex);

    try ctx.out.print("{s}\n", .{hex});
}

pub const command = Command{
    .name = "write-tree",
    .description = "Write the current index as a Merkle root.",
    .category = .plumbing,
    .run = run,
};
