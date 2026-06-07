const std = @import("std");
const nodus = @import("nodus");

const repo_root = ".";
const cli = @import("../cli/command.zig");
const Command = cli.Command;

fn printUsage() void {
    cli.printHelpToStdout(command);
}

pub fn run(
    alloc: std.mem.Allocator,
    args: *std.process.ArgIterator,
) !void {
    if (cli.hasHelpFlag(args)) {
        printUsage();
        return;
    }

    var store = try nodus.object.Store.init(alloc, repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(alloc, repo_root);
    defer index.deinit();

    try index.save();

    std.debug.print("initialized .nodus\n", .{});
}

pub const command = Command{
    .name = "init",
    .description = "Initialize a new nodus repository.",
    .run = run,
};
