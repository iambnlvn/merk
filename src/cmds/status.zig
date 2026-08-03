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

    const index = &opened.repo.index;

    if (index.entries.items.len == 0) {
        std.debug.print("index empty\n", .{});
        return;
    }

    for (index.entries.items) |entry| {
        const state = try index.stateOf(opened.repo.root, entry);
        const short = merk.crypto.hash.shortHex(entry.blob_hash);

        std.debug.print(
            "{s: <8} {s} {s}\n",
            .{ @tagName(state), short, entry.path },
        );
    }
}

pub const command = Command{
    .name = "status",
    .description = "Show the current index state.",
    .run = run,
};
