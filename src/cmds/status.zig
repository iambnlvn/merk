const std = @import("std");
const nodus = @import("nodus");

const repo_root = ".";
const Command = @import("../cli/command.zig").Command;

pub fn run(
    alloc: std.mem.Allocator,
    args: *std.process.ArgIterator,
) !void {
    _ = args;

    var index = try nodus.index.Index.init(alloc, repo_root);
    defer index.deinit();

    try index.load();

    if (index.entries.items.len == 0) {
        std.debug.print("index empty\n", .{});
        return;
    }

    for (index.entries.items) |entry| {
        const state = try index.stateOf(repo_root, entry);
        const short = nodus.hash.shortHex(entry.blob_hash);

        std.debug.print(
            "{s: <8} {s} {s}\n",
            .{ @tagName(state), short, entry.path },
        );
    }
}

pub const command = Command{
    .name = "status",
    .run = run,
};
