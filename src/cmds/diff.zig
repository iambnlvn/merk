const std = @import("std");
const nodus = @import("nodus");
const diff = nodus.diff;
const diff_args = @import("../cli/diff_args.zig");
const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;

const repo_root = ".";

pub fn run(inv: *Invocation) !void {
    var config = diff.RenderConfig{};
    var color_mode: diff_args.ColorMode = .auto;

    if (inv.flags.string("format")) |v|
        config.format = diff_args.parseFormat(v) orelse {
            std.debug.print("error: invalid format '{s}'\n", .{v});
            command.printHelpToStderr();
            return error.InvalidFormat;
        };

    if (inv.flags.string("level")) |v|
        config.level = diff_args.parseLevel(v) orelse {
            std.debug.print("error: invalid level '{s}'\n", .{v});
            command.printHelpToStderr();
            return error.InvalidLevel;
        };

    if (inv.flags.string("context")) |v|
        config.context = diff_args.parseContext(v) orelse {
            std.debug.print("error: invalid context '{s}'\n", .{v});
            command.printHelpToStderr();
            return error.InvalidContext;
        };

    if (inv.flags.string("group")) |v|
        config.group_by = diff_args.parseGroupBy(v) orelse {
            std.debug.print("error: invalid group '{s}'\n", .{v});
            command.printHelpToStderr();
            return error.InvalidGroup;
        };

    if (inv.flags.string("algo")) |v|
        config.algorithm = diff_args.parseAlgorithm(v) orelse {
            std.debug.print("error: invalid algorithm '{s}'\n", .{v});
            command.printHelpToStderr();
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
        config.filter = diff.ChangeFilter.parse(v) catch {
            std.debug.print("error: invalid --show value '{s}'\n", .{v});
            command.printHelpToStderr();
            return error.InvalidChangeFilter;
        };

    // --color overrides --no-color if both are given
    if (inv.flags.string("color")) |v|
        color_mode = diff_args.parseColorMode(v) orelse {
            std.debug.print("error: invalid color mode '{s}'\n", .{v});
            command.printHelpToStderr();
            return error.InvalidColorMode;
        };

    if (inv.flags.string("profile")) |v| {
        const p = std.meta.stringToEnum(diff_args.Profile, v) orelse {
            std.debug.print("error: invalid profile '{s}'\n", .{v});
            command.printHelpToStderr();
            return error.InvalidProfile;
        };
        diff_args.ProfileOpts.apply(p, &config);
    }

    if (inv.flags.boolean("staged")) {
        std.debug.print("error: --staged is not yet implemented\n", .{});
        return error.NotImplemented;
    }
    // --working is the default behaviour (and currently the only one); accepted as a no-op

    // Resolved here, in the CLI layer, since "is stdout a tty" is a CLI
    // concern the core renderers don't need to know about.
    const use_color = diff_args.resolveColor(color_mode, std.fs.File.stdout().isTty());
    _ = use_color; //TODO: wire into renderers once color output is implemented

    const paths = inv.positional.items;

    var store = try nodus.object.Store.init(inv.alloc, repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(inv.alloc, repo_root);
    defer index.deinit();
    try index.load();

    const cwd = std.fs.cwd();

    var file_diffs: std.ArrayListUnmanaged(diff.FileDiff) = .empty;
    var source_buffers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (file_diffs.items) |*fd| fd.deinit(inv.alloc);
        file_diffs.deinit(inv.alloc);
        for (source_buffers.items) |buf| inv.alloc.free(buf);
        source_buffers.deinit(inv.alloc);
    }

    for (index.entries.items) |entry| {
        const state = try index.stateOf(repo_root, entry);
        if (state == .clean) continue;

        const obj = try store.get(entry.blob_hash);
        try source_buffers.append(inv.alloc, obj.payload);

        var fd: diff.FileDiff = if (state == .deleted)
            try diff.diffFileWith(inv.alloc, entry.path, obj.payload, "", config.algorithm)
        else blk: {
            var file = try cwd.openFile(entry.path, .{});
            defer file.close();
            const new_src = try file.readToEndAlloc(inv.alloc, 64 * 1024 * 1024);
            try source_buffers.append(inv.alloc, new_src);
            break :blk try diff.diffFileWith(inv.alloc, entry.path, obj.payload, new_src, config.algorithm);
        };

        if (fd.line_deltas.len != 0) {
            try file_diffs.append(inv.alloc, fd);
        } else {
            fd.deinit(inv.alloc);
        }
    }

    if (file_diffs.items.len == 0) return;

    var visible: std.ArrayListUnmanaged(*const diff.FileDiff) = .empty;
    defer visible.deinit(inv.alloc);

    for (file_diffs.items) |*fd| {
        if (!config.filter.allows(diff.fileStatus(fd))) continue;

        if (paths.len > 0) {
            const included = for (paths) |p| {
                if (std.mem.startsWith(u8, fd.path, p)) break true;
            } else false;
            if (!included) continue;
        }

        try visible.append(inv.alloc, fd);
    }

    if (visible.items.len == 0) return;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    if (config.group_by == .dirs) {
        const groups = try diff.groupByDirectory(inv.alloc, visible.items);
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
            try diff.renderFileDiff(writer, fd, config);
    }

    try writer.flush();
}

pub const command = Command{
    .name = "diff",
    .description = "Show changes between the index and working tree.",
    .usage = "[options] [<path>...]",
    .flags = &[_]Flag{
        .{ .short = 'f', .long = "format", .kind = .value, .value_name = "fmt", .help = "unified, side-by-side, blocks, ops, summary" },
        .{ .short = 'l', .long = "level", .kind = .value, .value_name = "lvl", .help = "file, hunk, line, word" },
        .{ .short = 'c', .long = "context", .kind = .value, .value_name = "n", .help = "context lines (number, minimal, normal, full)" },
        .{ .short = 'g', .long = "group", .kind = .value, .value_name = "mode", .help = "none, files, dirs" },
        .{ .long = "algo", .kind = .value, .value_name = "name", .help = "myers, patience, histogram (default: histogram)" },
        .{ .long = "word", .kind = .boolean, .help = "enable inline word highlighting" },
        .{ .long = "only-added", .kind = .boolean, .help = "show only added files" },
        .{ .long = "only-deleted", .kind = .boolean, .help = "show only deleted files" },
        .{ .long = "only-modified", .kind = .boolean, .help = "show only modified files" },
        .{ .long = "show", .kind = .value, .value_name = "types", .help = "comma-separated: added,deleted,modified" },
        .{ .long = "detect-moves", .kind = .boolean, .help = "heuristic move detection" },
        .{ .long = "no-color", .kind = .boolean, .help = "disable color" },
        .{ .long = "color", .kind = .value, .value_name = "when", .help = "auto, always, never" },
        .{ .long = "profile", .kind = .value, .value_name = "name", .help = "review, ci, debug" },
        .{ .long = "staged", .kind = .boolean, .help = "diff staged changes (not yet implemented)" },
        .{ .long = "working", .kind = .boolean, .help = "diff working tree changes (default)" },
    },
    .run = run,
};
