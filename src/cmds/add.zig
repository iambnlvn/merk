const std = @import("std");
const nodus = @import("nodus");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;

const repo_root = ".";

pub fn run(inv: *Invocation) !void {
    if (inv.positional.items.len == 0) {
        std.debug.print("error: 'add' requires at least one path\n", .{});
        command.printHelpToStderr();
        return error.MissingPath;
    }

    var store = try nodus.object.Store.init(inv.alloc, repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(inv.alloc, repo_root);
    defer index.deinit();

    try index.load();

    for (inv.positional.items) |path| {
        const blob_hash = try index.addFile(&store, repo_root, path);
        const short = nodus.hash.shortHex(blob_hash);
        std.debug.print("staged {s} {s}\n", .{ path, short });
    }

    try index.save();
}

pub const command = Command{
    .name = "add",
    .description = "Stage paths in the index.",
    .usage = "<path>...",
    .run = run,
};
