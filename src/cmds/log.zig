const std = @import("std");
const nodus = @import("nodus");
const refs = nodus.refs;
const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

fn formatCommitSummary(
    alloc: std.mem.Allocator,
    hash_hex: []const u8,
    author: []const u8,
    committer: []const u8,
    message: []const u8,
    parent_hashes: []const []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    const writer = out.writer(alloc);
    try writer.print("commit {s}\n", .{hash_hex});
    try writer.print("author: {s}\n", .{author});
    try writer.print("committer: {s}\n", .{committer});
    try writer.print("message: {s}\n", .{message});

    if (parent_hashes.len == 0) {
        try writer.writeAll("parents: (none)\n");
    } else {
        try writer.writeAll("parents:");
        for (parent_hashes, 0..) |parent_hash, index| {
            if (index > 0) try writer.writeAll(", ");
            try writer.print(" {s}", .{parent_hash});
        }
        try writer.writeByte('\n');
    }

    return try out.toOwnedSlice(alloc);
}

pub fn run(ctx: Context, inv: *Invocation) !void {
    var store = try nodus.object.Store.init(inv.alloc, ctx.repo_root);
    defer store.deinit();

    var nodus_dir = try std.fs.cwd().openDir(".nodus", .{});
    defer nodus_dir.close();

    const head = try refs.resolveHead(inv.alloc, nodus_dir) orelse {
        std.debug.print("error: no commits yet\n", .{});
        return error.NoCommits;
    };

    var seen = std.AutoHashMap(nodus.hash.Hash, void).init(inv.alloc);
    defer seen.deinit();

    var stack = std.ArrayList(nodus.hash.Hash).empty;
    defer stack.deinit(inv.alloc);
    try stack.append(inv.alloc, head);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    while (stack.items.len > 0) {
        const current_hash = stack.pop() orelse continue;
        if (seen.contains(current_hash)) continue;

        try seen.put(current_hash, {});

        var commit = try nodus.commit.read(inv.alloc, &store, current_hash);
        defer commit.deinit(inv.alloc);

        const hash_hex = try nodus.hash.toHex(inv.alloc, current_hash);
        defer inv.alloc.free(hash_hex);

        const author = try std.fmt.allocPrint(inv.alloc, "{s} <{s}>", .{
            commit.identity.author.name,
            commit.identity.author.email,
        });
        defer inv.alloc.free(author);

        const committer = try std.fmt.allocPrint(inv.alloc, "{s} <{s}>", .{
            commit.identity.committer.name,
            commit.identity.committer.email,
        });
        defer inv.alloc.free(committer);

        const message = try inv.alloc.dupe(u8, commit.message.title);
        defer inv.alloc.free(message);

        var parent_hexes = std.ArrayList([]u8).empty;
        defer parent_hexes.deinit(inv.alloc);
        for (commit.snapshot.parents) |parent| {
            const parent_hex = try nodus.hash.toHex(inv.alloc, parent);
            errdefer inv.alloc.free(parent_hex);
            try parent_hexes.append(inv.alloc, parent_hex);
        }
        defer for (parent_hexes.items) |parent_hex| inv.alloc.free(parent_hex);

        const summary = try formatCommitSummary(
            inv.alloc,
            hash_hex,
            author,
            committer,
            message,
            parent_hexes.items,
        );
        defer inv.alloc.free(summary);

        try writer.writeAll(summary);
        try writer.writeByte('\n');

        for (commit.snapshot.parents) |parent| {
            try stack.append(inv.alloc, parent);
        }
    }

    try writer.flush();
}

pub const command = Command{
    .name = "log",
    .description = "Print commits reachable from HEAD with author, committer, message, and parent information.",
    .usage = "",
    .flags = &.{},
    .run = run,
};

test "formatCommitSummary includes core metadata" {
    const alloc = std.testing.allocator;
    const summary = try formatCommitSummary(
        alloc,
        "abc123",
        "Ada <ada@example.com>",
        "Ada <ada@example.com>",
        "Initial commit",
        &.{"parent1"},
    );
    defer alloc.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "commit abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "author: Ada <ada@example.com>") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "message: Initial commit") != null);
}
