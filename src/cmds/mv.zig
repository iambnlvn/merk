const std = @import("std");
const merk = @import("merk");

const repo_context = @import("repo_context.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

fn validatePath(ctx: Context, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        try ctx.err.print("error: '{s}' must be a path relative to the repo root\n", .{path});
        return error.InvalidPath;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) {
            try ctx.err.print("error: '{s}' escapes the repo root\n", .{path});
            return error.InvalidPath;
        }
    }
}

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len != 2) {
        try ctx.err.print("error: 'mv' takes exactly two paths: <from> <to>\n", .{});
        command.printHelp(ctx.err) catch {};
        return error.MissingPath;
    }

    const from = inv.positional.items[0];
    const to = inv.positional.items[1];
    const force = inv.flags.boolean("force");

    if (std.mem.eql(u8, from, to)) {
        try ctx.err.print("error: source and destination are the same path\n", .{});
        return error.InvalidPath;
    }

    try validatePath(ctx, from);
    try validatePath(ctx, to);

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    if (opened.repo.index.lookup(from) == null) {
        try ctx.err.print("error: '{s}' is not tracked\n", .{from});
        return error.NotTracked;
    }
    if (!force and opened.repo.index.lookup(to) != null) {
        try ctx.err.print("error: '{s}' is already tracked (pass --force to overwrite)\n", .{to});
        return error.AlreadyTracked;
    }

    const from_full = try std.fs.path.join(inv.alloc, &.{ opened.repo.root, from });
    defer inv.alloc.free(from_full);
    const to_full = try std.fs.path.join(inv.alloc, &.{ opened.repo.root, to });
    defer inv.alloc.free(to_full);

    if (std.fs.path.dirname(to_full)) |d| try std.fs.cwd().makePath(d);

    std.fs.cwd().rename(from_full, to_full) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.err.print("error: '{s}' does not exist on disk\n", .{from});
            return error.NotFound;
        },
        else => return err,
    };

    // Drop the old index entry, then re-stage at the new path. Content is
    // unchanged (only the location moved), so this recomputes the same
    // blob hash from the file at its new home — same "remove, then
    // repo.add persists everything in one save" shape rm.zig documents.
    try opened.repo.index.remove(from);
    try opened.repo.add(&.{to});

    try ctx.out.print("renamed  {s} -> {s}\n", .{ from, to });
}

pub const command = Command{
    .name = "mv",
    .description = "Move or rename a tracked file, updating both the index and working tree.",
    .usage = "<from> <to>",
    .category = .snapshot,
    .flags = &.{
        .{ .long = "force", .kind = .boolean, .help = "overwrite an already-tracked destination path" },
    },
    .run = run,
};
