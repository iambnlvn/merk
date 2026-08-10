const std = @import("std");
const merkle = @import("merkle");

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

    fn pastLabel(self: StageAction) []const u8 {
        return switch (self) {
            .added => "staged",
            .updated => "updated",
        };
    }
};

/// Last path component, or the whole string if there's no '/'.
fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// Prints up to 3 tracked paths that look like they might be what the
/// caller meant by `missing` — same basename, or `missing` appears
/// somewhere inside the tracked path. Catches the common "typed the
/// filename without its directory prefix" typo (e.g. `stage main.zig`
/// when the tracked path is `src/main.zig`).
fn printDidYouMean(ctx: Context, entries: []const merkle.Entry, missing: []const u8) !void {
    const wanted = basenameOf(missing);
    var header_printed = false;
    var count: usize = 0;

    for (entries) |e| {
        if (count >= 3) break;
        const matches = std.mem.eql(u8, basenameOf(e.path), wanted) or
            std.mem.indexOf(u8, e.path, missing) != null;
        if (!matches) continue;

        if (!header_printed) {
            try ctx.err.writeAll("  did you mean:\n");
            header_printed = true;
        }
        try ctx.err.print("    {s}\n", .{e.path});
        count += 1;
    }
}

/// Recursively walks `repo_root/rel_dir` (rel_dir == "" means repo root),
/// appending every regular file found — as a path relative to repo
/// root — into `out`. Skips the `.merk` control directory. Every
/// resulting string is freshly allocated and also pushed onto `owned`
/// so the caller can free it later; `seen` is shared with the caller's
/// dedup pass so a file reachable both explicitly and via a directory
/// only gets staged once.
fn expandDirectory(
    alloc: std.mem.Allocator,
    repo_root: []const u8,
    rel_dir: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
    owned: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const full_dir = try std.fs.path.join(alloc, &.{ repo_root, rel_dir });
    defer alloc.free(full_dir);

    var dir = std.fs.cwd().openDir(full_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // dir vanished between stat and open; nothing to stage
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, ".merk/") or std.mem.eql(u8, entry.path, ".merk")) continue;

        const rel_path = if (rel_dir.len == 0)
            try alloc.dupe(u8, entry.path)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel_dir, entry.path });

        const gop = try seen.getOrPut(alloc, rel_path);
        if (gop.found_existing) {
            alloc.free(rel_path);
            continue;
        }

        try owned.append(alloc, rel_path);
        try out.append(alloc, rel_path);
    }
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn run(ctx: Context, inv: *Invocation) !void {
    const all = inv.flags.boolean("all");

    if (inv.positional.items.len == 0 and !all) {
        try ctx.err.writeAll("error: expected at least one path (or --all)\n\n");
        command.printHelp(ctx.err) catch {};
        return error.MissingPath;
    }

    const dry_run = inv.flags.boolean("dry-run");
    const patch = inv.flags.boolean("patch");
    const context_lines = inv.flags.unsignedOr(u32, "context", 3);

    // Remove duplicate paths while preserving the original order. This
    // same map is reused below when expanding directories, so a file
    // reachable both explicitly and through a directory argument (or
    // through --all) only ever gets staged once.
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

    // --all restages every already-tracked path with a pending
    // modification (i.e. everything `status` would list as Modified).
    // It does NOT discover files that have never been staged — for
    // that, pass a directory (or `.`) as a path instead; see below.
    // It also skips Deleted entries: the exists-check further down
    // rejects any path missing on disk, and `stage` currently has no
    // way to record a deletion at all (explicit or via --all).
    if (all) {
        const status_result = opened.repo.status() catch |err| return errors_mod.report(ctx, err);
        defer merkle.freeChanges(inv.alloc, status_result.staged);
        defer inv.alloc.free(status_result.unstaged);

        for (status_result.unstaged) |entry| {
            if (entry.state != .modified) continue;

            const gop = try seen.getOrPut(inv.alloc, entry.path);
            if (!gop.found_existing) {
                try paths.append(inv.alloc, entry.path);
            }
        }
    }

    if (paths.items.len == 0) {
        try ctx.out.writeAll("nothing to stage\n");
        return;
    }

    // Resolve `paths` into `expanded`: plain files pass through as-is;
    // directories (including `.`) are walked recursively, picking up
    // every file underneath — tracked or not — which is what makes
    // `merk stage .` behave like `git add .` rather than being limited
    // to already-tracked paths the way `--all` is.
    var expanded = std.ArrayListUnmanaged([]const u8){};
    defer expanded.deinit(inv.alloc);

    var owned = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (owned.items) |p| inv.alloc.free(p);
        owned.deinit(inv.alloc);
    }

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
                printDidYouMean(ctx, opened.repo.staging.allEntries(), path) catch {};
                bad = true;
                continue;
            },
            else => return err,
        };

        if (stat.kind == .directory) {
            const trimmed = std.mem.trimRight(u8, path, "/");
            const rel_dir = if (std.mem.eql(u8, trimmed, ".")) "" else trimmed;
            expandDirectory(inv.alloc, opened.repo.root, rel_dir, &expanded, &owned, &seen) catch |err| {
                try ctx.err.print("error: could not read directory '{s}': {s}\n", .{ path, @errorName(err) });
                bad = true;
            };
            continue;
        }

        try expanded.append(inv.alloc, path);
    }

    if (bad) return error.InvalidPath;

    if (expanded.items.len == 0) {
        try ctx.out.writeAll("nothing to stage\n");
        return;
    }

    // Stable, predictable ordering regardless of directory-walk order.
    std.mem.sort([]const u8, expanded.items, {}, lessThanPath);

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
            expanded.items,
            context_lines,
        );
    }

    // Determine the staging action up front so dry-run, the success
    // output, and the real operation all agree on what happened.
    var actions = try inv.alloc.alloc(
        StageAction,
        expanded.items.len,
    );
    defer inv.alloc.free(actions);

    for (expanded.items, 0..) |path, i| {
        actions[i] = if (opened.repo.staging.lookup(path) == null)
            .added
        else
            .updated;
    }

    if (dry_run) {
        for (expanded.items, 0..) |path, i| {
            try ctx.out.print(
                "would {s:<8} {s}\n",
                .{ actions[i].label(), path },
            );
        }
        return;
    }

    opened.repo.add(expanded.items) catch |err|
        return errors_mod.report(ctx, err);

    // Real, non-dry-run staging used to exit silently on success —
    // confirm what actually happened instead of leaving the caller to
    // go run `status` to find out.
    for (expanded.items, 0..) |path, i| {
        try ctx.out.print(
            "{s:<8} {s}\n",
            .{ actions[i].pastLabel(), path },
        );
    }
    try ctx.out.print(
        "\n{d} path{s} staged\n",
        .{ expanded.items.len, if (expanded.items.len == 1) "" else "s" },
    );
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
    .usage = "[options] [<path>|<dir>...]",
    .category = .staging,
    .flags = &.{
        .{
            .short = 'A',
            .long = "all",
            .kind = .boolean,
            .help = "Restage every already-tracked path with a pending modification. Use a directory path (or '.') to also pick up new, never-staged files.",
        },
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
