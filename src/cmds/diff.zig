const std = @import("std");
const nodus = @import("nodus");
const diff = nodus.diff;
const Command = @import("../cli/command.zig").Command;
const repo_root = ".";

const Error = error{
    InvalidFormat,
    UnknownOption,
    MissingFormatValue,
};
fn printUsage() void {
    std.debug.print(
        "usage: nodus diff [--format=<side-by-side|grouped|block|word-highlight|summary|operations|modern>] [--color] [--no-color]\n",
        .{},
    );
}

pub fn run(
    alloc: std.mem.Allocator,
    args: *std.process.ArgIterator,
) !void {
    var options = diff.RenderOptions{
        .view = .modern,
        .color = false,
        .context_lines = 3,
        .max_column_width = 60,
    };

    while (true) {
        const arg = args.next() orelse break;
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const value = arg[9..];
            options.view = diff.parseView(value) orelse return Error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--format")) {
            const value = args.next() orelse return Error.MissingFormatValue;
            options.view = diff.parseView(value) orelse return Error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--color")) {
            options.color = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            options.color = false;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else {
            std.debug.print("unknown diff option: {s}\n", .{arg});
            printUsage();
            return Error.UnknownOption;
        }
    }

    var store = try nodus.object.Store.init(alloc, repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(alloc, repo_root);
    defer index.deinit();

    try index.load();

    const cwd = std.fs.cwd();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;

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

        var fd: diff.FileDiff = if (state == .deleted) try diff.diffFile(alloc, entry.path, old_src, "") else blk: {
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

    if (options.view == .summary) {
        try diff.renderSummaryView(writer, file_diffs.items, options);
    } else {
        for (file_diffs.items) |fd| {
            try diff.renderDiff(writer, &fd, options);
        }
    }

    try writer.flush();
}

pub const command = Command{
    .name = "diff",
    .run = run,
};
