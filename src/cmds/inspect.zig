const std = @import("std");
const crypto = @import("crypto");
const Hash = crypto.Hash;
const diff_mod = @import("../core/diff.zig");
const commit_mod = @import("../core/commit.zig");

const repo_context = @import("repo_context.zig");
const errors_mod = @import("../cli/errors.zig");

const CommitDiff = diff_mod.CommitDiff;
const diffCommitAgainstParent = diff_mod.diffCommitAgainstParent;
const diffCommits = diff_mod.diffCommits;
const renderFiltered = diff_mod.renderFiltered;
const fileStatus = diff_mod.fileStatus;
const summarize = diff_mod.summarize;

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

fn buildRenderConfig(inv: *Invocation) !diff_mod.RenderConfig {
    var cfg = diff_mod.RenderConfig{
        .algorithm = inv.flags.enumOr(diff_mod.Algorithm, "algorithm", .histogram),
        .format = inv.flags.enumOr(diff_mod.Format, "format", .unified),
        .group_by = inv.flags.enumOr(diff_mod.GroupBy, "group-by", .none),
        .context = .{ .exact = inv.flags.unsignedOr(u32, "context", 3) },
    };

    if (inv.flags.string("filter")) |raw| {
        cfg.filter = diff_mod.ChangeFilter.parse(raw) catch return error.InvalidFilter;
    }

    if (inv.flags.boolean("word")) {
        cfg.level = .word;
    } else if (inv.flags.boolean("stat")) {
        cfg.level = .file;
    }

    return cfg;
}

fn renderNameOnly(
    writer: *std.Io.Writer,
    cd: *const CommitDiff,
    filter: diff_mod.ChangeFilter,
    paths: []const []const u8,
) !void {
    for (cd.files) |*fd| {
        if (!filter.allows(fileStatus(fd))) continue;
        if (paths.len > 0) {
            const included = for (paths) |p| {
                if (std.mem.startsWith(u8, fd.path, p)) break true;
            } else false;
            if (!included) continue;
        }
        try writer.print("{s}\n", .{fd.path});
    }
}

fn formatTimestamp(buf: []u8, timestamp_ms: i64) []const u8 {
    const secs: u64 = @intCast(@divFloor(timestamp_ms, 1000));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch "invalid-date";
}

fn renderCommitHeader(writer: *std.Io.Writer, alloc: std.mem.Allocator, store: anytype, commit_hash: Hash) !void {
    var c = try commit_mod.read(alloc, store, commit_hash);
    defer c.deinit(alloc);

    try writer.print("commit {s}\n", .{std.fmt.bytesToHex(commit_hash, .lower)});

    if (c.parents.len > 1) {
        try writer.writeAll("Merge:");
        for (c.parents) |p| try writer.print(" {s}", .{std.fmt.bytesToHex(p.hash, .lower)[0..8]});
        try writer.writeByte('\n');
    }

    try writer.print("Author: {s} <{s}>\n", .{ c.identity.author.person.name, c.identity.author.person.email });
    if (!c.identity.isAuthorCommitter()) {
        try writer.print("Committer: {s} <{s}>\n", .{ c.identity.committer.person.name, c.identity.committer.person.email });
    }

    var date_buf: [32]u8 = undefined;
    var tz_buf: [5]u8 = undefined;
    const tz = c.identity.author.formattedTimezone(&tz_buf) orelse "?????";
    try writer.print("Date:   {s} {s}\n", .{ formatTimestamp(&date_buf, c.identity.author.timestamp_ms), tz });

    try writer.print("Intent: {s}\n", .{c.metadata.intent.name()});
    if (c.metadata.labels.len > 0) {
        try writer.writeAll("Labels:");
        for (c.metadata.labels) |l| try writer.print(" {s}", .{l});
        try writer.writeByte('\n');
    }

    try writer.writeByte('\n');
    try writer.print("    {s}\n", .{c.message.title});
    if (c.message.body.len > 0) {
        try writer.writeByte('\n');
        var lines = std.mem.splitScalar(u8, c.message.body, '\n');
        while (lines.next()) |line| try writer.print("    {s}\n", .{line});
    }
    for (c.message.trailers) |t| try writer.print("    {s}: {s}\n", .{ t.key, t.value });
    try writer.writeByte('\n');
}

pub fn run(ctx: Context, inv: *Invocation) !void {
    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const cfg = buildRenderConfig(inv) catch |err| return errors_mod.report(ctx, err);

    var focal_commit: ?Hash = null;

    var cd: CommitDiff = switch (inv.positional.items.len) {
        0 => blk: {
            const head = (try opened.repo.current()) orelse {
                try ctx.err.print("error: no commits yet\n", .{});
                return error.NoCommits;
            };
            focal_commit = head;
            break :blk try diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, head, cfg.algorithm);
        },
        1 => blk: {
            // `resolveRev` accepts both a full 64-char hash and an 8+ char
            // prefix, resolved the same way `diff --rev` resolves one —
            // see `Repository.resolveRev`'s doc comment.
            const target = opened.repo.resolveRev(inv.positional.items[0]) catch |err| return errors_mod.report(ctx, err);
            focal_commit = target;
            break :blk try diffCommitAgainstParent(inv.alloc, &opened.repo.store, &opened.repo.page_store, target, cfg.algorithm);
        },
        else => blk: {
            const old_hash = opened.repo.resolveRev(inv.positional.items[0]) catch |err| return errors_mod.report(ctx, err);
            const new_hash = opened.repo.resolveRev(inv.positional.items[1]) catch |err| return errors_mod.report(ctx, err);
            break :blk try diffCommits(inv.alloc, &opened.repo.store, &opened.repo.page_store, old_hash, new_hash, cfg.algorithm);
        },
    };
    defer cd.deinit(inv.alloc);

    if (focal_commit) |fc| {
        if (!inv.flags.boolean("no-header")) {
            try renderCommitHeader(ctx.out, inv.alloc, &opened.repo.store, fc);
        }
    }

    if (cd.files.len == 0) {
        try ctx.out.print("No changes.\n", .{});
        return;
    }

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(inv.alloc);
    var path_it = inv.flags.getMulti("path");
    while (path_it.next()) |p| try paths.append(inv.alloc, p);

    if (inv.flags.boolean("name-only")) {
        try renderNameOnly(ctx.out, &cd, cfg.filter, paths.items);
        return;
    }

    try renderFiltered(ctx.out, cd.files, cfg, inv.alloc, paths.items);

    if (inv.flags.boolean("stat")) {
        const s = summarize(&cd);
        try ctx.out.print(
            "\n{d} file(s) changed, +{d} -{d} lines, +{d} -{d} words\n",
            .{ s.files_changed, s.lines_added, s.lines_removed, s.words_added, s.words_removed },
        );
    }
}

pub const command = Command{
    .name = "inspect",
    .description = "Show the changes between two commits, or a commit and its parent.",
    .usage = "[<commit-hash>] [<commit-hash>] [flags]",
    .category = .history,
    .flags = &.{
        .{ .short = 's', .long = "stat", .kind = .boolean, .help = "Per-file change summary with totals, instead of a full diff" },
        .{ .long = "name-only", .kind = .boolean, .help = "List only changed file paths" },
        .{ .short = 'w', .long = "word", .kind = .boolean, .help = "Word-level highlighted diff" },
        .{ .long = "format", .kind = .value, .value_name = "fmt", .help = "unified|side_by_side|blocks|ops|summary", .default = "unified" },
        .{ .short = 'a', .long = "algorithm", .kind = .value, .value_name = "algo", .help = "myers|patience|histogram", .default = "histogram" },
        .{ .short = 'U', .long = "context", .kind = .value, .value_name = "n", .help = "Lines of context around changes", .default = "3" },
        .{ .long = "group-by", .kind = .value, .value_name = "mode", .help = "none|files|dirs", .default = "none" },
        .{ .long = "filter", .kind = .value, .value_name = "list", .help = "Comma list: added,deleted,modified (default: all)" },
        .{ .long = "path", .kind = .value, .value_name = "prefix", .help = "Limit to paths starting with this prefix (repeatable)" },
        .{ .long = "no-header", .kind = .boolean, .help = "Suppress the commit metadata header (0-/1-arg forms only)" },
    },
    .run = run,
};
