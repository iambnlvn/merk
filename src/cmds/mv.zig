const std = @import("std");
const merkle_mod = @import("merkle");

const repo_context = @import("repo_context.zig");
const errors_mod = @import("../cli/errors.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

/// Last path component: everything after the final '/', or the whole
/// string if there isn't one.
fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

/// Join a directory and a name with '/'. Empty `dir` means "root", so the
/// name is returned as-is (no leading slash). Caller owns the result.
fn joinPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return alloc.dupe(u8, name);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
}

/// True if `path` is a tracked *directory* — i.e. some staged entry lives
/// under it. Root ("") always counts as a directory.
fn isTrackedDirectory(entries: []const merkle_mod.Entry, path: []const u8) bool {
    if (path.len == 0) return true;
    for (entries) |e| {
        if (e.isUnder(path)) return true;
    }
    return false;
}

const Move = struct { from: []u8, to: []u8 };

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len < 2) {
        try ctx.err.print("error: 'mv' takes at least two paths: <from>... <to>\n", .{});
        command.printHelp(ctx.err) catch {};
        return error.MissingPath;
    }

    const force = inv.flags.boolean("force");

    const sources = inv.positional.items[0 .. inv.positional.items.len - 1];
    const dest_raw = inv.positional.items[inv.positional.items.len - 1];
    const dest = std.mem.trimRight(u8, dest_raw, "/");

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    // Snapshot of what's tracked *before* any move runs. Used only for
    // planning (directory detection, expanding a directory source into its
    // member files) — never held onto past that, since `movePath` mutates
    // this same underlying storage as the execution loop below runs. Each
    // `Move` we build from it copies its own `from`/`to` strings rather
    // than borrowing pointers into it, for exactly that reason.
    const entries = opened.repo.staging.allEntries();
    const dest_is_dir = isTrackedDirectory(entries, dest);

    // With more than one source, there's no sensible "rename to an exact
    // path" reading — every source has to land inside an existing tracked
    // directory, same as GNU `mv a b c dir/`.
    if (sources.len > 1 and !dest_is_dir) {
        try ctx.err.print(
            "error: '{s}' is not a tracked directory — with multiple sources the destination must be one\n",
            .{dest_raw},
        );
        return error.DestinationNotDirectory;
    }

    // Build the full list of (from, to) pairs before moving anything, so a
    // bad source later in the list is caught before any earlier one has
    // actually moved. A source is either:
    //   - a plain tracked file: one (from, to) pair, or
    //   - a tracked directory: one pair per file underneath it, each
    //     re-rooted from the old prefix to the new one.
    // "Land inside the destination" (append the source's basename) applies
    // whenever there's more than one source, or whenever the destination
    // is itself an existing directory — matching GNU `mv`'s "rename vs.
    // move-into" rule. Otherwise the destination is the exact new path,
    // which for a directory source means renaming the directory itself.
    var plan = std.ArrayListUnmanaged(Move){};
    defer {
        for (plan.items) |m| {
            ctx.alloc.free(m.from);
            ctx.alloc.free(m.to);
        }
        plan.deinit(ctx.alloc);
    }

    for (sources) |src_raw| {
        const src = std.mem.trimRight(u8, src_raw, "/");
        const land_inside = sources.len > 1 or dest_is_dir;

        const target_root = if (land_inside)
            try joinPath(ctx.alloc, dest, basename(src))
        else
            try ctx.alloc.dupe(u8, dest);

        if (isTrackedDirectory(entries, src)) {
            defer ctx.alloc.free(target_root);

            const prefix_len = src.len + 1; // skip the '/' after the prefix
            var found_any = false;
            for (entries) |e| {
                if (!e.isUnder(src)) continue;

                found_any = true;
                const new_path = try joinPath(ctx.alloc, target_root, e.path[prefix_len..]);
                errdefer ctx.alloc.free(new_path);
                const from_copy = try ctx.alloc.dupe(u8, e.path);
                try plan.append(ctx.alloc, .{ .from = from_copy, .to = new_path });
            }

            if (!found_any) {
                try ctx.err.print("error: '{s}' is not a tracked file or directory\n", .{src_raw});
                return error.NotTracked;
            }
        } else {
            const from_copy = try ctx.alloc.dupe(u8, src_raw);
            errdefer ctx.alloc.free(from_copy);
            try plan.append(ctx.alloc, .{ .from = from_copy, .to = target_root });
        }
    }

    // Execute in order. This isn't transactional — `Repository.movePath`
    // commits each move to the staging area and working tree as it goes —
    // so on failure partway through, everything printed so far already
    // moved and the rest didn't.
    //
    // Per-pair validation (absolute paths, path escape, same-path,
    // not-tracked, destination-already-tracked) still lives entirely in
    // `Repository.movePath` — see `errors_mod.report` for how its
    // `RepositoryError` variants become user-facing messages. That
    // includes cross-move collisions within one `mv` invocation: if two
    // sources compute the same destination, the second call sees it as
    // already tracked (from the first) and fails with that same error.
    for (plan.items) |m| {
        opened.repo.movePath(m.from, m.to, .{ .force = force }) catch |err| return errors_mod.report(ctx, err);
        try ctx.out.print("renamed  {s} -> {s}\n", .{ m.from, m.to });
    }
}

pub const command = Command{
    .name = "mv",
    .description = "Move or rename tracked files or directories, updating both the staging area and working tree.",
    .usage = "<from>... <to>",
    .category = .snapshot,
    .flags = &.{
        .{ .long = "force", .kind = .boolean, .help = "overwrite an already-tracked destination path" },
    },
    .run = run,
};
