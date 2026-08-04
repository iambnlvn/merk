//TODO: wip for implementing a pager like less for long outputs

const std = @import("std");
const merk = @import("merk");

const repo_context = @import("repo_context.zig");
const commit_mod = @import("../core/commit.zig");

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
    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    var walk = (try opened.repo.log(.all)) orelse {
        try ctx.err.print("error: no commits yet\n", .{});
        return error.NoCommits;
    };
    defer walk.deinit();

    const writer = ctx.out;

    while (try walk.next()) |current_hash| {
        var commit = try commit_mod.read(inv.alloc, &opened.repo.store, current_hash);
        defer commit.deinit(inv.alloc);

        const hash_hex = try merk.crypto.hash.toHex(inv.alloc, current_hash);
        defer inv.alloc.free(hash_hex);

        const author = try std.fmt.allocPrint(inv.alloc, "{s} <{s}>", .{
            commit.identity.author.person.name,
            commit.identity.author.person.email,
        });
        defer inv.alloc.free(author);

        const committer = try std.fmt.allocPrint(inv.alloc, "{s} <{s}>", .{
            commit.identity.committer.person.name,
            commit.identity.committer.person.email,
        });
        defer inv.alloc.free(committer);

        const message = try inv.alloc.dupe(u8, commit.message.title);
        defer inv.alloc.free(message);

        var parent_hexes = std.ArrayList([]u8).empty;
        defer parent_hexes.deinit(inv.alloc);
        for (commit.parents) |parent| {
            const parent_hex = try merk.crypto.hash.toHex(inv.alloc, parent.hash);
            errdefer inv.alloc.free(parent_hex);
            try parent_hexes.append(inv.alloc, parent_hex);
        }
        defer for (parent_hexes.items) |parent_hex| inv.alloc.free(parent_hex);

        const summary = try formatCommitSummary(
            inv.alloc,
            hash_hex, // maybe this should be short hex but the user may want the full hex
            author,
            committer,
            message,
            parent_hexes.items,
        );
        defer inv.alloc.free(summary);

        try writer.writeAll(summary);
        try writer.writeByte('\n');
    }
}

pub const command = Command{
    .name = "log",
    .description = "Print commits reachable from HEAD with author, committer, message, and parent information.",
    .usage = "",
    .category = .history,
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
