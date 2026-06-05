const std = @import("std");
const nodus = @import("nodus");
const diff = nodus.diff;
const Command = @import("../cli/command.zig").Command;

const repo_root = ".";

const Error = error{
    InvalidFormat,
    InvalidLevel,
    InvalidContext,
    InvalidGroup,
    InvalidProfile,
    UnknownOption,
    MissingValue,
};

fn printUsage() void {
    std.debug.print(
        \\usage: nodus diff [options] [<path>...]
        \\
        \\options:
        \\  -f, --format <fmt>      unified, side-by-side, blocks, ops, summary
        \\  -l, --level <lvl>       file, hunk, line, word
        \\  -c, --context <n>       context lines (number, minimal, normal, full)
        \\  -g, --group <mode>      none, files, dirs
        \\      --word              enable inline word highlighting
        \\      --only-added        show only added files
        \\      --only-deleted      show only deleted files
        \\      --only-modified     show only modified files
        \\      --show <types>      comma-separated: added,deleted,modified
        \\      --detect-moves      heuristic move detection
        \\      --no-color          disable color
        \\      --color <when>      auto, always, never
        \\      --profile <name>    review, ci, debug
        \\      --staged            diff staged changes
        \\      --working           diff working tree changes (default)
        \\  -h, --help              show this help
        \\
    , .{});
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
            const value = args.next() orelse return Error.MissingValue;
            config.format = diff.parseFormat(value) orelse return Error.InvalidFormat;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            config.format = diff.parseFormat(arg[9..]) orelse return Error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--level") or std.mem.eql(u8, arg, "-l")) {
            const value = args.next() orelse return Error.MissingValue;
            config.level = diff.parseLevel(value) orelse return Error.InvalidLevel;
        } else if (std.mem.startsWith(u8, arg, "--level=")) {
            config.level = diff.parseLevel(arg[8..]) orelse return Error.InvalidLevel;
        } else if (std.mem.eql(u8, arg, "--context") or std.mem.eql(u8, arg, "-c")) {
            const value = args.next() orelse return Error.MissingValue;
            config.context = diff.parseContext(value) orelse return Error.InvalidContext;
        } else if (std.mem.startsWith(u8, arg, "--context=")) {
            config.context = diff.parseContext(arg[10..]) orelse return Error.InvalidContext;
        } else if (std.mem.eql(u8, arg, "--group") or std.mem.eql(u8, arg, "-g")) {
            const value = args.next() orelse return Error.MissingValue;
            config.group_by = diff.parseGroupBy(value) orelse return Error.InvalidGroup;
        } else if (std.mem.startsWith(u8, arg, "--group=")) {
            config.group_by = diff.parseGroupBy(arg[8..]) orelse return Error.InvalidGroup;
        } else if (std.mem.eql(u8, arg, "--word")) {
            config.word_mode = true;
        } else if (std.mem.eql(u8, arg, "--only-added")) {
            config.filter = .{ .show_added = true, .show_deleted = false, .show_modified = false };
        } else if (std.mem.eql(u8, arg, "--only-deleted")) {
            config.filter = .{ .show_added = false, .show_deleted = true, .show_modified = false };
        } else if (std.mem.eql(u8, arg, "--only-modified")) {
            config.filter = .{ .show_added = false, .show_deleted = false, .show_modified = true };
        } else if (std.mem.eql(u8, arg, "--show")) {
            const value = args.next() orelse return Error.MissingValue;
            config.filter = diff.ChangeFilter.parse(value);
        } else if (std.mem.startsWith(u8, arg, "--show=")) {
            config.filter = diff.ChangeFilter.parse(arg[7..]);
        } else if (std.mem.eql(u8, arg, "--detect-moves")) {
            config.detect_moves = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            config.color = .never;
        } else if (std.mem.eql(u8, arg, "--color")) {
            const value = args.next();
            if (value) |v| {
                config.color = if (std.mem.eql(u8, v, "always")) .always else if (std.mem.eql(u8, v, "never")) .never else .auto;
            } else {
                config.color = .always;
            }
        } else if (std.mem.startsWith(u8, arg, "--color=")) {
            const value = arg[8..];
            config.color = if (std.mem.eql(u8, value, "always")) .always else if (std.mem.eql(u8, value, "never")) .never else .auto;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            const value = args.next() orelse return Error.MissingValue;
            const p = std.meta.stringToEnum(diff.Profile, value) orelse return Error.InvalidProfile;
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
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            const p = std.meta.stringToEnum(diff.Profile, arg[10..]) orelse return Error.InvalidProfile;
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
    .run = run,
};
