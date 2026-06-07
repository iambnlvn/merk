const std = @import("std");
const nodus = @import("nodus");
const diff = nodus.diff;
const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const flags = @import("../cli/flags.zig");

const repo_root = ".";

const Error = error{
    InvalidFormat,
    InvalidLevel,
    InvalidContext,
    InvalidGroup,
    InvalidProfile,
    InvalidColorMode,
    InvalidChangeFilter,
    UnknownOption,
    MissingValue,
};

const command_flags = [_]Flag{
    .{ .short = 'f', .long = "format", .kind = .value, .value_name = "fmt", .help = "unified, side-by-side, blocks, ops, summary" },
    .{ .short = 'l', .long = "level", .kind = .value, .value_name = "lvl", .help = "file, hunk, line, word" },
    .{ .short = 'c', .long = "context", .kind = .value, .value_name = "n", .help = "context lines (number, minimal, normal, full)" },
    .{ .short = 'g', .long = "group", .kind = .value, .value_name = "mode", .help = "none, files, dirs" },
    .{ .long = "word", .kind = .boolean, .help = "enable inline word highlighting" },
    .{ .long = "only-added", .kind = .boolean, .help = "show only added files" },
    .{ .long = "only-deleted", .kind = .boolean, .help = "show only deleted files" },
    .{ .long = "only-modified", .kind = .boolean, .help = "show only modified files" },
    .{ .long = "show", .kind = .value, .value_name = "types", .help = "comma-separated: added,deleted,modified" },
    .{ .long = "detect-moves", .kind = .boolean, .help = "heuristic move detection" },
    .{ .long = "no-color", .kind = .boolean, .help = "disable color" },
    .{ .long = "color", .kind = .value, .value_name = "when", .help = "auto, always, never" },
    .{ .long = "profile", .kind = .value, .value_name = "name", .help = "review, ci, debug" },
    .{ .long = "staged", .kind = .boolean, .help = "diff staged changes" },
    .{ .long = "working", .kind = .boolean, .help = "diff working tree changes (default)" },
};

fn printUsage() void {
    cli.printHelpToStdout(command);
}

pub fn run(
    alloc: std.mem.Allocator,
    args: *std.process.ArgIterator,
) !void {
    var config = diff.RenderConfig{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(alloc);

    while (true) {
        const arg = args.next() orelse break;

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            const value = try flags.nextValue(args);
            config.format = diff.parseFormat(value) orelse return Error.InvalidFormat;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            const value = flags.inlineValue(arg, "--format") orelse return Error.InvalidFormat;
            config.format = diff.parseFormat(value) orelse return Error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--level") or std.mem.eql(u8, arg, "-l")) {
            const value = try flags.nextValue(args);
            config.level = diff.parseLevel(value) orelse return Error.InvalidLevel;
        } else if (std.mem.startsWith(u8, arg, "--level=")) {
            const value = flags.inlineValue(arg, "--level") orelse return Error.InvalidLevel;
            config.level = diff.parseLevel(value) orelse return Error.InvalidLevel;
        } else if (std.mem.eql(u8, arg, "--context") or std.mem.eql(u8, arg, "-c")) {
            const value = try flags.nextValue(args);
            config.context = diff.parseContext(value) orelse return Error.InvalidContext;
        } else if (std.mem.startsWith(u8, arg, "--context=")) {
            const value = flags.inlineValue(arg, "--context") orelse return Error.InvalidContext;
            config.context = diff.parseContext(value) orelse return Error.InvalidContext;
        } else if (std.mem.eql(u8, arg, "--group") or std.mem.eql(u8, arg, "-g")) {
            const value = try flags.nextValue(args);
            config.group_by = diff.parseGroupBy(value) orelse return Error.InvalidGroup;
        } else if (std.mem.startsWith(u8, arg, "--group=")) {
            const value = flags.inlineValue(arg, "--group") orelse return Error.InvalidGroup;
            config.group_by = diff.parseGroupBy(value) orelse return Error.InvalidGroup;
        } else if (std.mem.eql(u8, arg, "--word")) {
            config.word_mode = true;
        } else if (std.mem.eql(u8, arg, "--only-added")) {
            config.filter = .{ .show_added = true, .show_deleted = false, .show_modified = false };
        } else if (std.mem.eql(u8, arg, "--only-deleted")) {
            config.filter = .{ .show_added = false, .show_deleted = true, .show_modified = false };
        } else if (std.mem.eql(u8, arg, "--only-modified")) {
            config.filter = .{ .show_added = false, .show_deleted = false, .show_modified = true };
        } else if (std.mem.eql(u8, arg, "--show")) {
            const value = try flags.nextValue(args);
            config.filter = try diff.ChangeFilter.parse(value);
        } else if (std.mem.startsWith(u8, arg, "--show=")) {
            const value = flags.inlineValue(arg, "--show") orelse return Error.InvalidChangeFilter;
            config.filter = try diff.ChangeFilter.parse(value);
        } else if (std.mem.eql(u8, arg, "--detect-moves")) {
            config.detect_moves = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            config.color = .never;
        } else if (std.mem.eql(u8, arg, "--color")) {
            const value = args.next();
            if (value) |v| {
                config.color = diff.parseColorMode(v) orelse return Error.InvalidColorMode;
            } else {
                config.color = .always;
            }
        } else if (std.mem.startsWith(u8, arg, "--color=")) {
            const value = flags.inlineValue(arg, "--color") orelse return Error.InvalidColorMode;
            config.color = diff.parseColorMode(value) orelse return Error.InvalidColorMode;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            const value = try flags.nextValue(args);
            const p = flags.parseEnum(diff.Profile, value) orelse return Error.InvalidProfile;
            diff.ProfileOpts.apply(p, &config);
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            const value = flags.inlineValue(arg, "--profile") orelse return Error.InvalidProfile;
            const p = flags.parseEnum(diff.Profile, value) orelse return Error.InvalidProfile;
            diff.ProfileOpts.apply(p, &config);
        } else if (std.mem.eql(u8, arg, "--staged")) {
            // TODO: diff index against HEAD instead of working tree
        } else if (std.mem.eql(u8, arg, "--working")) {
            // explicit no-op; default behavior
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("unknown diff option: {s}\n", .{arg});
            printUsage();
            return Error.UnknownOption;
        } else {
            try paths.append(alloc, arg);
        }
    }

    // Resolve auto color
    if (config.color == .auto) {
        config.color = if (std.fs.File.stdout().isTty()) .always else .never;
    }

    var store = try nodus.object.Store.init(alloc, repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(alloc, repo_root);
    defer index.deinit();
    try index.load();

    const cwd = std.fs.cwd();

    var file_diffs: std.ArrayList(diff.FileDiff) = .empty;
    var source_buffers: std.ArrayList([]const u8) = .empty;
    defer {
        for (file_diffs.items) |*fd| fd.deinit(alloc);
        file_diffs.deinit(alloc);
        for (source_buffers.items) |buf| alloc.free(buf);
        source_buffers.deinit(alloc);
    }

    for (index.entries.items) |entry| {
        const state = try index.stateOf(repo_root, entry);
        if (state == .clean) continue;

        const obj = try store.get(entry.blob_hash);
        const old_src = obj.payload;
        try source_buffers.append(alloc, old_src);

        var fd: diff.FileDiff = if (state == .deleted)
            try diff.diffFile(alloc, entry.path, old_src, "")
        else blk: {
            var file = try cwd.openFile(entry.path, .{});
            defer file.close();
            const new_src = try file.readToEndAlloc(alloc, 64 * 1024 * 1024);
            try source_buffers.append(alloc, new_src);
            break :blk try diff.diffFile(alloc, entry.path, old_src, new_src);
        };

        if (fd.line_deltas.len != 0) {
            try file_diffs.append(alloc, fd);
        } else {
            fd.deinit(alloc);
        }
    }

    if (file_diffs.items.len == 0) return;

    var visible: std.ArrayList(*const diff.FileDiff) = .empty;
    defer visible.deinit(alloc);

    for (file_diffs.items) |*fd| {
        const status = diff.fileStatus(fd);
        if (!config.filter.allows(status)) continue;

        if (paths.items.len > 0) {
            var included = false;
            for (paths.items) |p| {
                if (std.mem.startsWith(u8, fd.path, p)) {
                    included = true;
                    break;
                }
            }
            if (!included) continue;
        }

        try visible.append(alloc, fd);
    }

    if (visible.items.len == 0) return;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;

    if (config.group_by == .dirs) {
        const groups = try diff.groupByDirectory(alloc, visible.items);
        defer {
            for (groups) |g| alloc.free(g.files);
            alloc.free(groups);
        }
        for (groups) |g| {
            try writer.print("{s}/\n", .{g.dir});
            for (g.files) |fd| {
                try writer.print("  {s}\n", .{std.fs.path.basename(fd.path)});
            }
            try writer.writeByte('\n');
        }
    } else {
        for (visible.items) |fd| {
            try diff.renderFileDiff(writer, fd, config);
        }
    }

    try writer.flush();
}

pub const command = Command{
    .name = "diff",
    .description = "Show changes between the index and working tree.",
    .usage = "[options] [<path>...]",
    .flags = &command_flags,
    .run = run,
};
