const std = @import("std");
const nodus = @import("root.zig");
const repo_root = ".";

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();
    const command = args.next() orelse return usage();

    if (std.mem.eql(u8, command, "init")) {
        var store = try nodus.object.Store.init(alloc, repo_root);
        defer store.deinit();
        var index = try nodus.index.Index.init(alloc, repo_root);
        defer index.deinit();
        try index.save();
        std.debug.print("initialized .nodus\n", .{});
        return;
    }

    if (std.mem.eql(u8, command, "add")) {
        var store = try nodus.object.Store.init(alloc, repo_root);
        defer store.deinit();
        var index = try nodus.index.Index.init(alloc, repo_root);
        defer index.deinit();
        try index.load();

        var added: usize = 0;
        while (args.next()) |path| {
            const blob_hash = try index.addFile(&store, repo_root, path);
            const short = nodus.hash.shortHex(blob_hash);
            std.debug.print("staged {s} {s}\n", .{ path, short });
            added += 1;
        }
        if (added == 0) return error.MissingPath;
        try index.save();
        return;
    }

    if (std.mem.eql(u8, command, "status")) {
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
            std.debug.print("{s: <8} {s} {s}\n", .{ @tagName(state), short, entry.path });
        }
        return;
    }

    return usage();
}

fn usage() void {
    std.debug.print(
        \\usage:
        \\  nodus init
        \\  nodus add <path>...
        \\  nodus status
        \\
    , .{});
}
