const std = @import("std");

const repo_context = @import("repo_context.zig");
const errors_mod = @import("../cli/errors.zig");
const Repository = @import("../core/repository.zig").Repository;
const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

const StageAction = enum {
    added,
    updated,

    fn label(self: StageAction) []const u8 {
        return switch (self) {
            .added => "stage",
            .updated => "update",
        };
    }
};

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len == 0) {
        try ctx.err.writeAll("error: expected at least one path\n\n");
        command.printHelp(ctx.err) catch {};
        return error.MissingPath;
    }

    const dry_run = inv.flags.boolean("dry-run");
    const patch = inv.flags.boolean("patch");
    const context_lines = inv.flags.unsignedOr(u32, "context", 3);

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

    // Validate every path exists and isn't a directory before touching
    // staging at all, so a bad path later in the list doesn't leave
    // earlier paths half-applied.
    //
    // NOTE: abs-path / path-escape validation is handled by
    // Repository.add/addPatch themselves.
    var bad = false;

    for (paths.items) |path| {
        const full_path = try std.fs.path.join(
            inv.alloc,
            &.{ opened.repo.root, path },
        );
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

    if (bad) return error.InvalidPath;

    if (patch) {
        if (dry_run) {
            try ctx.err.writeAll(
                "error: --dry-run and --patch are mutually exclusive\n",
            );
            return error.ConflictingFlags;
        }

        return runPatch(
            ctx,
            opened.repo,
            paths.items,
            context_lines,
        );
    }

    // Determine the staging action up front so dry-run and the real
    // operation report the same result.
    var actions = try inv.alloc.alloc(
        StageAction,
        paths.items.len,
    );
    defer inv.alloc.free(actions);

    for (paths.items, 0..) |path, i| {
        actions[i] = if (opened.repo.staging.lookup(path) == null)
            .added
        else
            .updated;
    }

    if (dry_run) {
        for (paths.items, 0..) |path, i| {
            try ctx.out.print(
                "would {s:<8} {s}\n",
                .{ actions[i].label(), path },
            );
        }
        return;
    }

    opened.repo.add(paths.items) catch |err|
        return errors_mod.report(ctx, err);
}

/// Interactive hunk staging.
///
/// Walks `paths` in order and prompts hunk-by-hunk on stdin/stdout via
/// `Repository.addPatch`. Stops early when the user quits (`q`).
fn runPatch(
    ctx: Context,
    repo: *Repository,
    paths: []const []const u8,
    context_lines: u32,
) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const reader = &stdin_reader.interface;

    for (paths) |path| {
        const outcome = repo.addPatch(
            path,
            context_lines,
            ctx.out,
            reader,
        ) catch |err| return errors_mod.report(ctx, err);

        if (outcome.hunk_count == 0) {
            try ctx.out.print(
                "{s}: no changes to stage\n",
                .{path},
            );
            continue;
        }

        try ctx.out.print(
            "{s}: staged {d}/{d} hunk{s}\n",
            .{
                path,
                outcome.staged_count,
                outcome.hunk_count,
                if (outcome.hunk_count == 1) "" else "s",
            },
        );

        if (outcome.quit_early) break;
    }
}

pub const command = Command{
    .name = "stage",
    .description = "Stage changes from one or more paths.",
    .usage = "[options] ...",
    .category = .staging,
    .flags = &.{
        .{
            .short = 'n',
            .long = "dry-run",
            .kind = .boolean,
            .help = "Preview what would be staged without making changes.",
        },
        .{
            .short = 'p',
            .long = "patch",
            .kind = .boolean,
            .help = "Interactively choose hunks to stage.",
        },
        .{
            .long = "context",
            .kind = .value,
            .value_name = "c",
            .help = "Context lines shown around each hunk in --patch mode.",
            .default = "3",
        },
    },
    .run = run,
};
