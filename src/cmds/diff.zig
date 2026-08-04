const std = @import("std");
const merk = @import("merk");
const diff_mod = @import("../core/diff.zig");
const diff_algorithms = diff_mod.diff_algorithms;
const diff_snapshot = diff_mod.diff_snapshot;
const diff_render = diff_mod.diff_render;
const repo_context = @import("repo_context.zig");
const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

/// CLI-only: whether to emit ANSI color codes. The core renderers are
/// colorless; if/when color support is added to rendering, it should take
/// a plain `bool` derived from this, not this enum directly
const ColorMode = enum {
    auto,
    always,
    never,
};

const Profile = enum { review, ci, debug };

fn parseFormat(s: []const u8) ?diff_render.Format {
    const map = std.StaticStringMap(diff_render.Format).initComptime(.{
        .{ "unified", .unified },
        .{ "side-by-side", .side_by_side },
        .{ "blocks", .blocks },
        .{ "ops", .ops },
        .{ "summary", .summary },
    });
    return map.get(s);
}

fn parseLevel(s: []const u8) ?diff_render.Level {
    const map = std.StaticStringMap(diff_render.Level).initComptime(.{
        .{ "file", .file },
        .{ "hunk", .hunk },
        .{ "line", .line },
        .{ "word", .word },
    });
    return map.get(s);
}

fn parseContext(s: []const u8) ?diff_render.Context {
    if (std.mem.eql(u8, s, "minimal")) return .minimal;
    if (std.mem.eql(u8, s, "normal")) return .normal;
    if (std.mem.eql(u8, s, "full")) return .full;
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    return .{ .exact = n };
}

fn parseGroupBy(s: []const u8) ?diff_render.GroupBy {
    const map = std.StaticStringMap(diff_render.GroupBy).initComptime(.{
        .{ "none", .none },
        .{ "files", .files },
        .{ "dirs", .dirs },
    });
    return map.get(s);
}

fn parseAlgorithm(s: []const u8) ?diff_algorithms.Algorithm {
    const map = std.StaticStringMap(diff_algorithms.Algorithm).initComptime(.{
        .{ "myers", .myers },
        .{ "patience", .patience },
        .{ "histogram", .histogram },
    });
    return map.get(s);
}

fn parseColorMode(raw: []const u8) ?ColorMode {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "always")) return .always;
    if (std.mem.eql(u8, raw, "never")) return .never;
    return null;
}

/// Resolves `auto` against whether stdout is a TTY. CLI-only — core has no
/// concept of a terminal.
fn resolveColor(mode: ColorMode, stdout_is_tty: bool) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => stdout_is_tty,
    };
}

fn applyProfile(p: Profile, config: *diff_render.RenderConfig) void {
    switch (p) {
        .review => {
            config.format = .side_by_side;
            config.level = .line;
            config.group_by = .files;
        },
        .ci => {
            config.format = .summary;
            config.level = .file;
        },
        .debug => {
            config.format = .ops;
            config.context = .full;
        },
    }
}

pub fn run(ctx: Context, inv: *Invocation) !void {
    var config = diff_render.RenderConfig{};
    var color_mode: ColorMode = .auto;

    if (inv.flags.string("format")) |v|
        config.format = parseFormat(v) orelse {
            ctx.err.print("error: invalid format '{s}'\n", .{v}) catch {};
            return error.InvalidFormat;
        };

    if (inv.flags.string("level")) |v|
        config.level = parseLevel(v) orelse {
            ctx.err.print("error: invalid level '{s}'\n", .{v}) catch {};
            return error.InvalidLevel;
        };

    if (inv.flags.string("context")) |v|
        config.context = parseContext(v) orelse {
            ctx.err.print("error: invalid context '{s}'\n", .{v}) catch {};
            return error.InvalidContext;
        };

    if (inv.flags.string("group")) |v|
        config.group_by = parseGroupBy(v) orelse {
            ctx.err.print("error: invalid group '{s}'\n", .{v}) catch {};
            return error.InvalidGroup;
        };

    if (inv.flags.string("algo")) |v|
        config.algorithm = parseAlgorithm(v) orelse {
            ctx.err.print("error: invalid algorithm '{s}'\n", .{v}) catch {};
            return error.InvalidAlgorithm;
        };

    if (inv.flags.boolean("word")) config.word_mode = true;
    if (inv.flags.boolean("detect-moves")) config.detect_moves = true;
    if (inv.flags.boolean("no-color")) color_mode = .never;

    if (inv.flags.boolean("only-added"))
        config.filter = .{ .show_added = true, .show_deleted = false, .show_modified = false };
    if (inv.flags.boolean("only-deleted"))
        config.filter = .{ .show_added = false, .show_deleted = true, .show_modified = false };
    if (inv.flags.boolean("only-modified"))
        config.filter = .{ .show_added = false, .show_deleted = false, .show_modified = true };

    if (inv.flags.string("show")) |v|
        config.filter = diff_render.ChangeFilter.parse(v) catch {
            ctx.err.print("error: invalid --show value '{s}'\n", .{v}) catch {};
            return error.InvalidChangeFilter;
        };

    // --color overrides --no-color if both are given
    if (inv.flags.string("color")) |v|
        color_mode = parseColorMode(v) orelse {
            ctx.err.print("error: invalid color mode '{s}'\n", .{v}) catch {};
            return error.InvalidColorMode;
        };

    if (inv.flags.string("profile")) |v| {
        const p = std.meta.stringToEnum(Profile, v) orelse {
            ctx.err.print("error: invalid profile '{s}'\n", .{v}) catch {};
            return error.InvalidProfile;
        };
        applyProfile(p, &config);
    }
    // --rev is repeatable, like --trailer on `commit`: 0, 1, or 2 occurrences.
    //   0 revs: working tree vs index (default, below)
    //   1 rev:  that commit vs its first parent
    //   2 revs: first rev vs second rev, in the order given
    //   Note: comma-separated hashes in a single --rev value are also supported
    //   Supports both full (64-char) and short (8+ char) hex hash prefixes
    var rev_strs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rev_strs.deinit(inv.alloc);

    var rev_it = inv.flags.getMulti("rev");
    while (rev_it.next()) |raw| {
        // Support both single hashes and comma-separated hashes
        var parts = std.mem.splitScalar(u8, raw, ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;

            merk.crypto.hash.parseHexPrefix(trimmed) catch {
                ctx.err.print("error: invalid --rev '{s}' (expected 8-64 hex chars)\n", .{trimmed}) catch {};
                return error.InvalidRev;
            };
            try rev_strs.append(inv.alloc, trimmed);
        }
    }
    if (rev_strs.items.len > 2) {
        ctx.err.print("error: --rev can be given at most twice (comparing two trees)\n", .{}) catch {};
        return error.TooManyRevs;
    }

    const staged = inv.flags.boolean("staged");
    if (staged and rev_strs.items.len > 0) {
        ctx.err.print("error: --staged and --rev are mutually exclusive\n", .{}) catch {};
        return error.ConflictingDiffMode;
    }
    if (staged) {
        ctx.err.print("error: --staged is not yet implemented\n", .{}) catch {};
        return error.NotImplemented;
    }
    // --working is the default behaviour (and currently the only one with no
    // --rev given); accepted as a no-op

    // Resolved here, in the CLI layer, since "is stdout a tty" is a CLI
    // concern the core renderers don't need to know about.
    const use_color = resolveColor(color_mode, std.fs.File.stdout().isTty());
    _ = use_color; //TODO: wire into renderers once color output is implemented

    const paths = inv.positional.items;

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    // Resolve rev strings (full or short hashes) to actual Hash objects.
    // --rev refers to *commits* (see the flag help text), so these are
    // commit hashes, not snapshot/index-tree roots — that distinction
    // matters below, since diff_snapshot's commit-level helpers resolve
    // a commit to its snapshot root themselves.
    var revs: std.ArrayListUnmanaged(merk.crypto.hash.Hash) = .empty;
    defer revs.deinit(inv.alloc);

    for (rev_strs.items) |rev_str| {
        const h = merk.crypto.hash.fromHex(rev_str) catch {
            // Not a full hash: resolve the short hash prefix against the object store
            const resolved = opened.repo.store.resolveHashPrefix(rev_str) catch |e| {
                switch (e) {
                    error.Ambiguous => ctx.err.print("error: ambiguous --rev '{s}' (matches multiple objects)\n", .{rev_str}) catch {},
                    error.NotFound => ctx.err.print("error: --rev '{s}' not found\n", .{rev_str}) catch {},
                    else => ctx.err.print("error: invalid --rev '{s}'\n", .{rev_str}) catch {},
                }
                return error.InvalidRev;
            };
            try revs.append(inv.alloc, resolved);
            continue;
        };
        try revs.append(inv.alloc, h);
    }

    const writer = ctx.out;

    if (revs.items.len > 0) {
        var cd: diff_algorithms.CommitDiff = if (revs.items.len == 1)
            try diff_snapshot.diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, revs.items[0], config.algorithm)
        else
            try diff_snapshot.diffCommits(inv.alloc, &opened.repo.store, &opened.repo.page_store, revs.items[0], revs.items[1], config.algorithm);
        defer cd.deinit(inv.alloc);

        var visible: std.ArrayListUnmanaged(*const diff_algorithms.FileDiff) = .empty;
        defer visible.deinit(inv.alloc);

        for (cd.files) |*fd| {
            if (!config.filter.allows(diff_render.fileStatus(fd))) continue;

            if (paths.len > 0) {
                const included = for (paths) |p| {
                    if (std.mem.startsWith(u8, fd.path, p)) break true;
                } else false;
                if (!included) continue;
            }

            try visible.append(inv.alloc, fd);
        }

        if (visible.items.len == 0) return;

        if (config.group_by == .dirs) {
            const groups = try diff_render.groupByDirectory(inv.alloc, visible.items);
            defer {
                for (groups) |g| inv.alloc.free(g.files);
                inv.alloc.free(groups);
            }
            for (groups) |g| {
                try writer.print("{s}/\n", .{g.dir});
                for (g.files) |fd|
                    try writer.print("  {s}\n", .{std.fs.path.basename(fd.path)});
                try writer.writeByte('\n');
            }
        } else {
            for (visible.items) |fd|
                try diff_render.renderFileDiff(writer, fd, config);
        }

        return;
    }

    // No --rev given: existing working-tree-vs-index behavior, unchanged.
    // Index was already loaded by Repository.open.
    const index = &opened.repo.index;

    const cwd = std.fs.cwd();

    var file_diffs: std.ArrayListUnmanaged(diff_algorithms.FileDiff) = .empty;
    var source_buffers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (file_diffs.items) |*fd| fd.deinit(inv.alloc);
        file_diffs.deinit(inv.alloc);
        for (source_buffers.items) |buf| inv.alloc.free(buf);
        source_buffers.deinit(inv.alloc);
    }

    for (index.entries.items) |entry| {
        const state = try index.stateOf(opened.repo.root, entry);
        if (state == .clean) continue;

        const obj = try opened.repo.store.get(entry.blob_hash);
        try source_buffers.append(inv.alloc, obj.payload);

        var fd: diff_algorithms.FileDiff = if (state == .deleted)
            try diff_algorithms.diffFileWith(inv.alloc, entry.path, obj.payload, "", config.algorithm)
        else blk: {
            var file = try cwd.openFile(entry.path, .{});
            defer file.close();
            const new_src = try file.readToEndAlloc(inv.alloc, 64 * 1024 * 1024);
            try source_buffers.append(inv.alloc, new_src);
            break :blk try diff_algorithms.diffFileWith(inv.alloc, entry.path, obj.payload, new_src, config.algorithm);
        };

        if (fd.line_deltas.len != 0) {
            try file_diffs.append(inv.alloc, fd);
        } else {
            fd.deinit(inv.alloc);
        }
    }

    if (file_diffs.items.len == 0) return;

    var visible: std.ArrayListUnmanaged(*const diff_algorithms.FileDiff) = .empty;
    defer visible.deinit(inv.alloc);

    for (file_diffs.items) |*fd| {
        if (!config.filter.allows(diff_render.fileStatus(fd))) continue;

        if (paths.len > 0) {
            const included = for (paths) |p| {
                if (std.mem.startsWith(u8, fd.path, p)) break true;
            } else false;
            if (!included) continue;
        }

        try visible.append(inv.alloc, fd);
    }

    if (visible.items.len == 0) return;

    if (config.group_by == .dirs) {
        const groups = try diff_render.groupByDirectory(inv.alloc, visible.items);
        defer {
            for (groups) |g| inv.alloc.free(g.files);
            inv.alloc.free(groups);
        }
        for (groups) |g| {
            try writer.print("{s}/\n", .{g.dir});
            for (g.files) |fd|
                try writer.print("  {s}\n", .{std.fs.path.basename(fd.path)});
            try writer.writeByte('\n');
        }
    } else {
        for (visible.items) |fd|
            try diff_render.renderFileDiff(writer, fd, config);
    }
}

pub const command = Command{
    .name = "diff",
    .description = "Show changes between the index and working tree, or between commits with --rev.",
    .usage = "[options] [<path>...]",
    .category = .history,
    .flags = &[_]Flag{
        .{ .short = 'f', .long = "format", .kind = .value, .value_name = "fmt", .help = "unified, side-by-side, blocks, ops, summary" },
        .{ .short = 'l', .long = "level", .kind = .value, .value_name = "lvl", .help = "file, hunk, line, word" },
        .{ .short = 'c', .long = "context", .kind = .value, .value_name = "n", .help = "context lines (number, minimal, normal, full)" },
        .{ .short = 'g', .long = "group", .kind = .value, .value_name = "mode", .help = "none, files, dirs" },
        .{ .long = "algo", .kind = .value, .value_name = "name", .help = "myers, patience, histogram (default: histogram)" },
        .{ .long = "rev", .kind = .value, .value_name = "hash", .help = "commit hash to compare; repeat for two commits (default: working tree vs index)" },
        .{ .long = "word", .kind = .boolean, .help = "enable inline word highlighting" },
        .{ .long = "only-added", .kind = .boolean, .help = "show only added files" },
        .{ .long = "only-deleted", .kind = .boolean, .help = "show only deleted files" },
        .{ .long = "only-modified", .kind = .boolean, .help = "show only modified files" },
        .{ .long = "show", .kind = .value, .value_name = "types", .help = "comma-separated: added,deleted,modified" },
        .{ .long = "detect-moves", .kind = .boolean, .help = "heuristic move detection" },
        .{ .long = "no-color", .kind = .boolean, .help = "disable color" },
        .{ .long = "color", .kind = .value, .value_name = "when", .help = "auto, always, never" },
        .{ .long = "profile", .kind = .value, .value_name = "name", .help = "review, ci, debug" },
        .{ .long = "staged", .kind = .boolean, .help = "diff staged changes (not yet implemented; mutually exclusive with --rev)" },
        .{ .long = "working", .kind = .boolean, .help = "diff working tree changes (default)" },
    },
    .run = run,
};
