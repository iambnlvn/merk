const std = @import("std");
const merk = @import("merk");

const repo_context = @import("repo_context.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

const SnapshotAction = enum {
    added,
    updated,
};

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len == 0) {
        try ctx.err.writeAll(
            \\error: expected at least one path
            \\
        );
        command.printHelp(ctx.err) catch {};
        return error.MissingPath;
    }

    const dry_run = inv.flags.boolean("dry-run");

    // Remove duplicate paths while preserving the original order.
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(inv.alloc);

    var paths = std.ArrayListUnmanaged([]const u8){};
    defer paths.deinit(inv.alloc);

    for (inv.positional.items) |path| {
        const gop = try seen.getOrPut(inv.alloc, path);
        if (!gop.found_existing) {
            try paths.append(inv.alloc, path);
        }
    }

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    // Validate every path before updating the snapshot.
    var bad = false;

    for (paths.items) |path| {
        if (std.fs.path.isAbsolute(path)) {
            try ctx.err.print(
                "error: path '{s}' must be relative to the repository root\n",
                .{path},
            );
            bad = true;
            continue;
        }

        var escapes = false;
        var it = std.mem.splitScalar(u8, path, '/');

        while (it.next()) |segment| {
            if (std.mem.eql(u8, segment, "..")) {
                escapes = true;
                break;
            }
        }

        if (escapes) {
            try ctx.err.print(
                "error: path '{s}' resolves outside the repository\n",
                .{path},
            );
            bad = true;
            continue;
        }

        const full_path = try std.fs.path.join(inv.alloc, &.{ opened.repo.root, path });
        defer inv.alloc.free(full_path);

        const stat = std.fs.cwd().statFile(full_path) catch |err| switch (err) {
            error.FileNotFound => {
                try ctx.err.print(
                    "error: path '{s}' does not exist\n",
                    .{path},
                );
                bad = true;
                continue;
            },
            else => return err,
        };

        if (stat.kind == .directory) {
            try ctx.err.print(
                "error: directories are not supported yet: '{s}'\n",
                .{path},
            );
            bad = true;
        }
    }

    if (bad)
        return error.InvalidPath;

    if (dry_run) {
        for (paths.items) |path| {
            try ctx.out.print(
                "Would update snapshot: {s}\n",
                .{path},
            );
        }
        return;
    }

    var actions = try inv.alloc.alloc(SnapshotAction, paths.items.len);
    defer inv.alloc.free(actions);

    for (paths.items, 0..) |path, i| {
        actions[i] = if (opened.repo.index.lookup(path) == null)
            .added
        else
            .updated;
    }

    if (dry_run) {
        for (paths.items, 0..) |path, i| {
            const action = switch (actions[i]) {
                .added => "Would add",
                .updated => "Would update",
            };

            try ctx.out.print(
                "{s:<12} {s}\n",
                .{ action, path },
            );
        }
        return;
    }

    try opened.repo.add(paths.items);
}

pub const command = Command{
    .name = "snapshot",
    .description = "Update the pending snapshot with one or more paths.",
    .usage = "[options] <path>...",
    .flags = &.{
        .{
            .short = 'n',
            .long = "dry-run",
            .kind = .boolean,
            .help = "Preview the snapshot update without making any changes.",
        },
    },
    .run = run,
};
