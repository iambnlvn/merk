const std = @import("std");
const nodus = @import("nodus");

const repo_root = ".";
const Command = @import("../cli/command.zig").Command;

pub fn run(
    alloc: std.mem.Allocator,
    args: *std.process.ArgIterator,
) !void {
    var store = try nodus.object.Store.init(alloc, repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(alloc, repo_root);
    defer index.deinit();

    try index.load();

    var added: usize = 0;

    while (args.next()) |path| {
        const blob_hash = try index.addFile(
            &store,
            repo_root,
            path,
        );

        const short = nodus.hash.shortHex(blob_hash);

        std.debug.print(
            "staged {s} {s}\n",
            .{ path, short },
        );

        added += 1;
    }

    if (added == 0)
        return error.MissingPath;

    try index.save();
}

pub const command = Command{
    .name = "add",
    .run = run,
};
