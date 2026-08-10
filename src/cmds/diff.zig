const std = @import("std");
const crypto = @import("crypto");
const merkle_mod = @import("merkle");

const cli = @import("../cli/command.zig");
const errors_mod = @import("../cli/errors.zig");
const diff_mod = @import("../core/diff.zig");
const repo_context = @import("repo_context.zig");

const Command = cli.Command;
const Context = cli.Context;
const Flag = cli.Flag;
const Invocation = cli.Invocation;

const Algorithm = diff_mod.Algorithm;
const ChangeFilter = diff_mod.ChangeFilter;
const CommitDiff = diff_mod.CommitDiff;
const DiffContext = diff_mod.Context;
const FileDiff = diff_mod.FileDiff;
const Format = diff_mod.Format;
const GroupBy = diff_mod.GroupBy;
const Level = diff_mod.Level;
const RenderConfig = diff_mod.RenderConfig;

const diffCommitAgainstParent = diff_mod.diffCommitAgainstParent;
const diffCommits = diff_mod.diffCommits;
const diffFileWith = diff_mod.diffFileWith;
const fileStatus = diff_mod.fileStatus;
const groupByDirectory = diff_mod.groupByDirectory;
const renderFileDiff = diff_mod.renderFileDiff;
const renderFiltered = diff_mod.renderFiltered;
/// CLI-only: whether to emit ANSI color codes. The core renderers are
/// colorless; if/when color support is added to rendering, it should take
/// a plain `bool` derived from this, not this enum directly
const ColorMode = enum {
    auto,
    always,
    never,
};

const Profile = enum { review, ci, debug };

fn parseFormat(s: []const u8) ?Format {
    // Can't use std.meta.stringToEnum here: "side-by-side" (the CLI
    // spelling) isn't a legal Zig identifier, so it can't be the tag name
    // (side_by_side) that maps to. Every other flag below whose CLI
    // strings match their enum's tag names verbatim uses stringToEnum
    // instead of a hand-written table like this one.
    const map = std.StaticStringMap(Format).initComptime(.{
        .{ "unified", .unified },
        .{ "side-by-side", .side_by_side },
        .{ "blocks", .blocks },
        .{ "ops", .ops },
        .{ "summary", .summary },
    });
    return map.get(s);
}

fn parseContext(s: []const u8) ?DiffContext {
    if (std.mem.eql(u8, s, "minimal")) return .minimal;
    if (std.mem.eql(u8, s, "normal")) return .normal;
    if (std.mem.eql(u8, s, "full")) return .full;
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    return .{ .exact = n };
}

fn applyProfile(p: Profile, config: *RenderConfig) void {
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

/// Resolves `auto` against whether stdout is a TTY. CLI-only — core has no
/// concept of a terminal.
fn resolveColor(mode: ColorMode, stdout_is_tty: bool) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => stdout_is_tty,
    };
}

pub fn run(ctx: Context, inv: *Invocation) !void {
    var config = RenderConfig{};
    var color_mode: ColorMode = .auto;

    if (inv.flags.string("format")) |v|
        config.format = parseFormat(v) orelse {
            ctx.err.print("error: invalid format '{s}'\n", .{v}) catch {};
            return error.InvalidFormat;
        };

    if (inv.flags.string("level")) |v|
        config.level = std.meta.stringToEnum(Level, v) orelse {
            ctx.err.print("error: invalid level '{s}'\n", .{v}) catch {};
            return error.InvalidLevel;
        };

    if (inv.flags.string("context")) |v|
        config.context = parseContext(v) orelse {
            ctx.err.print("error: invalid context '{s}'\n", .{v}) catch {};
            return error.InvalidContext;
        };

    if (inv.flags.string("group")) |v|
        config.group_by = std.meta.stringToEnum(GroupBy, v) orelse {
            ctx.err.print("error: invalid group '{s}'\n", .{v}) catch {};
            return error.InvalidGroup;
        };

    if (inv.flags.string("algo")) |v|
        config.algorithm = std.meta.stringToEnum(Algorithm, v) orelse {
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
        config.filter = ChangeFilter.parse(v) catch {
            ctx.err.print("error: invalid --show value '{s}'\n", .{v}) catch {};
            return error.InvalidChangeFilter;
        };

    // --color overrides --no-color if both are given
    if (inv.flags.string("color")) |v|
        color_mode = std.meta.stringToEnum(ColorMode, v) orelse {
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

            crypto.parseHexPrefix(trimmed) catch {
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

    // Resolved here, in the CLI layer, since "is stdout a tty" is a CLI
    // concern the core renderers don't need to know about.
    const use_color = resolveColor(color_mode, std.fs.File.stdout().isTty());
    _ = use_color; //TODO: wire into renderers once color output is implemented

    const paths = inv.positional.items;

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    if (staged) {
        // Structural (Merkle-tree) diff between HEAD's snapshot and the
        // staged tree — same data `status` shows under "staged". This is
        // deliberately a summary, not the full line-level render the
        // working-tree and --rev paths below produce: EntryChange only
        // carries the "what changed" shape, not old/new blob content to
        // diff line-by-line.
        const changes = opened.repo.diffStaged() catch |err| return errors_mod.report(ctx, err);
        defer merkle_mod.freeChanges(inv.alloc, changes);

        if (changes.len == 0) return;

        try ctx.out.print("{d} path{s} staged\n", .{ changes.len, if (changes.len == 1) "" else "s" });
        return;
    }
    // --working is the default behaviour (and currently the only one with no
    // --rev given); accepted as a no-op

    // --rev refers to *commits* (see the flag help text), so these are
    // commit hashes, not snapshot/staging-tree roots — that distinction
    // matters below, since diff_snapshot's commit-level helpers resolve
    // a commit to its snapshot root themselves.
    var revs: std.ArrayListUnmanaged(crypto.Hash) = .empty;
    defer revs.deinit(inv.alloc);

    // `Repository.resolveRev` accepts both a full 64-char hash and an 8+
    // char prefix — the same resolution `show` uses, so a hash that works
    // in one command works in the other.
    for (rev_strs.items) |rev_str| {
        const resolved = opened.repo.resolveRev(rev_str) catch |e| {
            switch (e) {
                error.AmbiguousRev => ctx.err.print("error: ambiguous --rev '{s}' (matches multiple objects)\n", .{rev_str}) catch {},
                error.RevNotFound => ctx.err.print("error: --rev '{s}' not found\n", .{rev_str}) catch {},
                else => ctx.err.print("error: invalid --rev '{s}'\n", .{rev_str}) catch {},
            }
            return error.InvalidRev;
        };
        try revs.append(inv.alloc, resolved);
    }

    const writer = ctx.out;

    if (revs.items.len > 0) {
        var cd: CommitDiff = if (revs.items.len == 1)
            try diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, revs.items[0], config.algorithm)
        else
            try diffCommits(inv.alloc, &opened.repo.store, &opened.repo.page_store, revs.items[0], revs.items[1], config.algorithm);
        defer cd.deinit(inv.alloc);

        // Filtering by `config.filter`, restricting to `paths`, grouping
        // by directory or not, and rendering each visible file all lives
        // in `renderFiltered` now — the same routine `merk show` (via
        // `renderCommit`) uses. This and the working-tree branch below
        // used to each carry their own copy of that logic.
        try renderFiltered(writer, cd.files, config, inv.alloc, paths);
        return;
    }

    // No --rev given: default working-tree-vs-staging behavior, unchanged.
    // Staging was already loaded by Repository.open.
    const staging = &opened.repo.staging;

    const cwd = std.fs.cwd();

    var file_diffs: std.ArrayListUnmanaged(FileDiff) = .empty;
    var source_buffers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (file_diffs.items) |*fd| fd.deinit(inv.alloc);
        file_diffs.deinit(inv.alloc);
        for (source_buffers.items) |buf| inv.alloc.free(buf);
        source_buffers.deinit(inv.alloc);
    }

    for (staging.allEntries()) |entry| {
        const state = try staging.stateOf(opened.repo.root, entry);
        if (state == .clean) continue;

        const obj = try opened.repo.store.get(entry.blob_hash);
        try source_buffers.append(inv.alloc, obj.payload);

        var fd: FileDiff = if (state == .deleted)
            try diffFileWith(inv.alloc, entry.path, obj.payload, "", config.algorithm)
        else blk: {
            var file = try cwd.openFile(entry.path, .{});
            defer file.close();
            const new_src = try file.readToEndAlloc(inv.alloc, 64 * 1024 * 1024);
            try source_buffers.append(inv.alloc, new_src);
            break :blk try diffFileWith(inv.alloc, entry.path, obj.payload, new_src, config.algorithm);
        };

        if (fd.line_deltas.len != 0) {
            try file_diffs.append(inv.alloc, fd);
        } else {
            fd.deinit(inv.alloc);
        }
    }

    if (file_diffs.items.len == 0) return;

    try renderFiltered(writer, file_diffs.items, config, inv.alloc, paths);
}

pub const command = Command{
    .name = "diff",
    .description = "Show changes between staging and the working tree, or between commits with --rev.",
    .usage = "[options] [<path>...]",
    .category = .history,
    .flags = &[_]Flag{
        .{ .short = 'f', .long = "format", .kind = .value, .value_name = "fmt", .help = "unified, side-by-side, blocks, ops, summary" },
        .{ .short = 'l', .long = "level", .kind = .value, .value_name = "lvl", .help = "file, hunk, line, word" },
        .{ .short = 'c', .long = "context", .kind = .value, .value_name = "n", .help = "context lines (number, minimal, normal, full)" },
        .{ .short = 'g', .long = "group", .kind = .value, .value_name = "mode", .help = "none, files, dirs" },
        .{ .long = "algo", .kind = .value, .value_name = "name", .help = "myers, patience, histogram (default: histogram)" },
        .{ .long = "rev", .kind = .value, .value_name = "hash", .help = "commit hash to compare; repeat for two commits (default: working tree vs staging)" },
        .{ .long = "word", .kind = .boolean, .help = "enable inline word highlighting" },
        .{ .long = "only-added", .kind = .boolean, .help = "show only added files" },
        .{ .long = "only-deleted", .kind = .boolean, .help = "show only deleted files" },
        .{ .long = "only-modified", .kind = .boolean, .help = "show only modified files" },
        .{ .long = "show", .kind = .value, .value_name = "types", .help = "comma-separated: added,deleted,modified" },
        .{ .long = "detect-moves", .kind = .boolean, .help = "heuristic move detection" },
        .{ .long = "no-color", .kind = .boolean, .help = "disable color" },
        .{ .long = "color", .kind = .value, .value_name = "when", .help = "auto, always, never" },
        .{ .long = "profile", .kind = .value, .value_name = "name", .help = "review, ci, debug" },
        .{ .long = "staged", .kind = .boolean, .help = "summarize staged changes (structural only; mutually exclusive with --rev)" },
        .{ .long = "working", .kind = .boolean, .help = "diff working tree changes (default)" },
    },
    .run = run,
};
