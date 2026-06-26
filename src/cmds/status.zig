const std = @import("std");
const nodus = @import("nodus");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    var index = try nodus.index.Index.init(inv.alloc, ctx.repo_root);
    defer index.deinit();

    try index.load();

    if (index.entries.items.len == 0) {
        std.debug.print("index empty\n", .{});
        return;
    }

    for (index.entries.items) |entry| {
        const state = try index.stateOf(ctx.repo_root, entry);
        const short = nodus.hash.shortHex(entry.blob_hash);

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
