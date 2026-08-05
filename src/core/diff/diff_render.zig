const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const diff_algorithms = @import("./diff_algorithms.zig");

const LineDelta = diff_algorithms.LineDelta;
const FileDiff = diff_algorithms.FileDiff;
const CommitDiff = diff_algorithms.CommitDiff;

pub const Format = enum {
    unified,
    side_by_side,
    blocks,
    ops,
    summary,
};

pub const Level = enum {
    file,
    hunk,
    line,
    word,
};

pub const Context = union(enum) {
    exact: u32,
    minimal,
    normal,
    full,

    pub fn lines(self: Context) u32 {
        return switch (self) {
            .exact => |n| n,
            .minimal => 0,
            .normal => 3,
            .full => std.math.maxInt(u32),
        };
    }
};

pub const GroupBy = enum {
    none,
    files,
    dirs,
};

pub const FileStatus = enum { added, deleted, modified, unchanged };

pub const ChangeFilter = struct {
    show_added: bool = true,
    show_deleted: bool = true,
    show_modified: bool = true,

    pub fn allows(self: ChangeFilter, status: FileStatus) bool {
        return switch (status) {
            .added => self.show_added,
            .deleted => self.show_deleted,
            .modified => self.show_modified,
            .unchanged => false,
        };
    }

    pub fn parse(raw: []const u8) !ChangeFilter {
        var f = ChangeFilter{ .show_added = false, .show_deleted = false, .show_modified = false };
        var it = std.mem.splitScalar(u8, raw, ',');
        var seen = false;
        while (it.next()) |part| {
            seen = true;
            if (std.mem.eql(u8, part, "added")) {
                f.show_added = true;
            } else if (std.mem.eql(u8, part, "deleted")) {
                f.show_deleted = true;
            } else if (std.mem.eql(u8, part, "modified")) {
                f.show_modified = true;
            } else {
                return error.InvalidChangeFilter;
            }
        }
        if (!seen) return error.InvalidChangeFilter;
        return f;
    }
};

pub const RenderConfig = struct {
    format: Format = .unified,
    level: Level = .line,
    context: Context = .normal,
    group_by: GroupBy = .none,
    filter: ChangeFilter = .{},
    word_mode: bool = false,
    detect_moves: bool = false,
    max_width: u32 = 60,
    /// Which diff algorithm to use for line-level diffing
    algorithm: diff_algorithms.Algorithm = .histogram,

    pub fn contextLines(self: RenderConfig) u32 {
        return self.context.lines();
    }
};

pub fn renderCommit(writer: anytype, cd: *const CommitDiff, config: RenderConfig, alloc: Allocator) !void {
    var filtered: ArrayList(*const FileDiff) = .empty;
    defer filtered.deinit(alloc);

    for (cd.files) |*fd| {
        const status = fileStatus(fd);
        if (!config.filter.allows(status)) continue;
        try filtered.append(alloc, fd);
    }

    if (config.group_by == .dirs) {
        const groups = try groupByDirectory(alloc, filtered.items);
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
        return;
    }

    for (filtered.items) |fd| {
        try renderFileDiff(writer, fd, config);
    }
}

pub fn renderFileDiff(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    if (config.level == .file) {
        try writeFileHeaderLine(writer, fd, fileStatus(fd));
        return;
    }

    if (config.level == .word) {
        try renderWordDiff(writer, fd);
        return;
    }

    switch (config.format) {
        .unified => try renderUnified(writer, fd, config),
        .side_by_side => try renderSideBySide(writer, fd, config),
        .blocks => try renderBlockOriented(writer, fd, config),
        .ops => try renderOperations(writer, fd, config),
        .summary => try renderSummary(writer, fd),
    }
}

pub fn renderUnified(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    try writer.print("FILE  {s}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{fd.path});
    if (fd.line_deltas.len == 0) return;

    var it = HunkIterator.init(fd.line_deltas, config.contextLines());
    while (it.next()) |hunk| {
        const line_num = hunk.displayLineNum();
        try writer.print("~ Line {d}\n", .{line_num});
        for (fd.line_deltas[hunk.start..hunk.end]) |d| {
            const prefix: []const u8 = switch (d.op) {
                .eq => "  ",
                .del => "- ",
                .ins => "+ ",
            };
            try writer.print("{s}{s}\n", .{ prefix, d.content });
        }
        try writer.writeByte('\n');
    }
}

fn renderSideBySide(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    const col_width = maxLineWidth(fd.line_deltas, @as(usize, @intCast(config.max_width)));
    const sep = " │ ";

    try writer.print("FILE  {s}\n", .{fd.path});
    try writer.writeAll("│ Before");
    padTo(writer, col_width, 6);
    try writer.writeAll(sep);
    try writer.writeAll("After");
    padTo(writer, col_width, 5);
    try writer.writeByte('\n');

    const total_width = 1 + col_width + sep.len + col_width + 1;
    for (0..total_width) |_| try writer.writeAll("─");
    try writer.writeByte('\n');

    for (fd.line_deltas) |d| {
        const left = if (d.op == .ins) "" else d.content;
        const right = if (d.op == .del) "" else d.content;
        try writer.writeAll("│");
        try writePadded(writer, left, col_width);
        try writer.writeAll(sep);
        try writePadded(writer, right, col_width);
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
}

fn renderBlockOriented(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    try writer.print("FILE: {s}\n", .{fd.path});
    if (fd.line_deltas.len == 0) return;

    var it = HunkIterator.init(fd.line_deltas, config.contextLines());
    var change_number: usize = 1;
    while (it.next()) |hunk| {
        try writer.print("CHANGE #{d}\n", .{change_number});
        try writeSectionDivider(writer, 32);
        try writer.writeAll("BEFORE\n");
        for (fd.line_deltas[hunk.start..hunk.end]) |d| if (d.op != .ins) try writer.print("{s}\n", .{d.content});
        try writer.writeAll("AFTER\n");
        for (fd.line_deltas[hunk.start..hunk.end]) |d| if (d.op != .del) try writer.print("{s}\n", .{d.content});
        try writer.writeByte('\n');
        change_number += 1;
    }
}

fn renderOperations(writer: anytype, fd: *const FileDiff, config: RenderConfig) !void {
    try writer.print("FILE  {s}\n", .{fd.path});
    try writer.print("STATUS: {s}\n\n", .{statusString(fileStatus(fd))});
    if (fd.line_deltas.len == 0) return;

    var it = HunkIterator.init(fd.line_deltas, config.contextLines());
    while (it.next()) |hunk| {
        const line_num = hunk.displayLineNum();
        try writer.print("FROM line {d}\n", .{line_num});
        for (fd.line_deltas[hunk.start..hunk.end]) |d| if (d.op != .ins) try writer.print("  {s}\n", .{d.content});
        try writer.print("\nTO line {d}\n", .{line_num});
        for (fd.line_deltas[hunk.start..hunk.end]) |d| if (d.op != .del) try writer.print("  {s}\n", .{d.content});
        try writer.writeByte('\n');
    }
}

fn renderSummary(writer: anytype, fd: *const FileDiff) !void {
    try writeFileHeaderLine(writer, fd, fileStatus(fd));
}

fn writeFileHeaderLine(writer: anytype, fd: *const FileDiff, status: FileStatus) !void {
    try writer.print("{s} {s} (+{d} -{d})\n", .{ statusString(status), fd.path, fd.lines_added, fd.lines_removed });
}

fn renderWordHighlight(writer: anytype, fd: *const FileDiff) !void {
    try renderWordDiff(writer, fd);
}

pub fn renderWordDiff(writer: anytype, fd: *const FileDiff) !void {
    try writer.print("WORD HIGHLIGHT: {s}\n", .{fd.path});
    try renderWordDeltas(writer, fd.word_deltas);
}

fn renderWordDeltas(writer: anytype, word_deltas: []const diff_algorithms.WordDelta) !void {
    var current_line: u32 = 0;
    for (word_deltas) |d| {
        if (d.lineno != current_line) {
            if (current_line != 0) try writer.writeByte('\n');
            try writer.print("Line {d}: ", .{d.lineno});
            current_line = d.lineno;
        }
        switch (d.op) {
            .eq => try writer.print("{s}", .{d.word}),
            .ins => try writer.print("[+{s}+]", .{d.word}),
            .del => try writer.print("[-{s}-]", .{d.word}),
        }
    }
    if (current_line != 0) try writer.writeByte('\n');
}

const Hunk = struct {
    start: usize,
    end: usize,
    deltas: []const LineDelta,

    fn displayLineNum(self: Hunk) u32 {
        for (self.deltas[self.start..self.end]) |d| {
            if (d.op != .ins) return d.old_lineno;
        }
        return self.deltas[self.start].new_lineno;
    }
};

const HunkIterator = struct {
    deltas: []const LineDelta,
    context: u32,
    i: usize,

    fn init(deltas: []const LineDelta, context: u32) HunkIterator {
        return .{ .deltas = deltas, .context = context, .i = 0 };
    }

    fn next(self: *HunkIterator) ?Hunk {
        while (self.i < self.deltas.len and self.deltas[self.i].op == .eq) self.i += 1;
        if (self.i >= self.deltas.len) return null;

        const start = if (self.i >= self.context) self.i - self.context else 0;
        var hunk_end: usize = self.i;

        while (hunk_end < self.deltas.len) {
            if (self.deltas[hunk_end].op != .eq) {
                hunk_end = @min(hunk_end + @as(usize, @intCast(self.context)) + 1, self.deltas.len);
            } else {
                var lookahead = hunk_end;
                var eq_run: u32 = 0;
                while (lookahead < self.deltas.len and self.deltas[lookahead].op == .eq) {
                    lookahead += 1;
                    eq_run += 1;
                }
                if (eq_run > self.context * 2 or lookahead >= self.deltas.len) {
                    hunk_end = @min(hunk_end + @as(usize, @intCast(self.context)), self.deltas.len);
                    break;
                }
                hunk_end = lookahead;
            }
        }

        const result = Hunk{ .start = start, .end = hunk_end, .deltas = self.deltas };
        self.i = hunk_end;
        return result;
    }
};

pub const DirGroup = struct {
    dir: []const u8,
    files: []*const FileDiff,
};

pub fn groupByDirectory(alloc: Allocator, files: []*const FileDiff) ![]DirGroup {
    var map = std.StringHashMap(ArrayList(*const FileDiff)).init(alloc);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(alloc);
        map.deinit();
    }

    for (files) |fd| {
        const dir = std.fs.path.dirname(fd.path) orelse ".";
        const gop = try map.getOrPut(dir);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(alloc, fd);
    }

    var groups: ArrayList(DirGroup) = .empty;
    var it = map.iterator();
    while (it.next()) |entry| {
        try groups.append(alloc, .{
            .dir = entry.key_ptr.*,
            .files = try entry.value_ptr.toOwnedSlice(alloc),
        });
    }

    const owned = try groups.toOwnedSlice(alloc);
    // StringHashMap iteration order is unspecified — without this sort,
    // `renderCommit`'s grouped output would vary from run to run for the
    // exact same diff, which is a bad property for anything piping this
    // through a pager, a diff-of-diffs, or a test snapshot.
    std.mem.sort(DirGroup, owned, {}, struct {
        fn lt(_: void, a: DirGroup, b: DirGroup) bool {
            return std.mem.lessThan(u8, a.dir, b.dir);
        }
    }.lt);
    return owned;
}

pub const DiffSummary = struct {
    files_changed: u32,
    lines_added: u32,
    lines_removed: u32,
    words_added: u32,
    words_removed: u32,
};

pub fn summarize(cd: *const CommitDiff) DiffSummary {
    var s = DiffSummary{
        .files_changed = @intCast(cd.files.len),
        .lines_added = 0,
        .lines_removed = 0,
        .words_added = 0,
        .words_removed = 0,
    };
    for (cd.files) |f| {
        s.lines_added += f.lines_added;
        s.lines_removed += f.lines_removed;
        s.words_added += f.words_added;
        s.words_removed += f.words_removed;
    }
    return s;
}

pub fn fileStatus(fd: *const FileDiff) FileStatus {
    var has_ins = false;
    var has_del = false;
    for (fd.line_deltas) |d| {
        switch (d.op) {
            .ins => has_ins = true,
            .del => has_del = true,
            .eq => {},
        }
        // Once both are seen the answer is settled (.modified) — no need
        // to keep scanning the rest of what can be a long delta list.
        if (has_ins and has_del) break;
    }
    if (has_ins and has_del) return .modified;
    if (has_ins) return .added;
    if (has_del) return .deleted;
    return .unchanged;
}

fn statusString(s: FileStatus) []const u8 {
    return switch (s) {
        .added => "A",
        .deleted => "D",
        .modified => "M",
        .unchanged => "~",
    };
}

fn maxLineWidth(deltas: []const LineDelta, max_width: usize) usize {
    var max: usize = 0;
    for (deltas) |d| {
        if (d.content.len > max) max = d.content.len;
    }
    return if (max < max_width) max else max_width;
}

fn writePadded(writer: anytype, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) {
        for (0..width - text.len) |_| try writer.writeByte(' ');
    }
}

fn padTo(writer: anytype, width: usize, already_written: usize) void {
    if (width > already_written) {
        for (0..width - already_written) |_| writer.writeByte(' ') catch {};
    }
}

fn writeSectionDivider(writer: anytype, width: usize) !void {
    for (0..width) |_| try writer.writeAll("━");
    try writer.writeByte('\n');
}

test "summarize aggregates across files" {
    const alloc = std.testing.allocator;
    const old_files = [_]diff_algorithms.FileSnapshot{
        .{ .path = "a.txt", .content = "hello\nworld\n" },
        .{ .path = "b.txt", .content = "foo\n" },
    };
    const new_files = [_]diff_algorithms.FileSnapshot{
        .{ .path = "a.txt", .content = "hello\nearth\n" },
        .{ .path = "b.txt", .content = "foo\nbar\n" },
    };

    var cd = try diff_algorithms.diffCommit(alloc, &old_files, &new_files);
    defer cd.deinit(alloc);

    const s = summarize(&cd);
    try std.testing.expectEqual(@as(u32, 2), s.files_changed);
    try std.testing.expectEqual(@as(u32, 2), s.lines_added);
    try std.testing.expectEqual(@as(u32, 1), s.lines_removed);
}

test "ChangeFilter parse comma list" {
    const f = try ChangeFilter.parse("added,modified");
    try std.testing.expect(f.show_added);
    try std.testing.expect(f.show_modified);
    try std.testing.expect(!f.show_deleted);
}

test "groupByDirectory groups files" {
    const alloc = std.testing.allocator;
    const files = &[_]FileDiff{
        .{ .path = "src/main.zig", .line_deltas = &.{}, .word_deltas = &.{}, .lines_added = 0, .lines_removed = 0, .words_added = 0, .words_removed = 0 },
        .{ .path = "src/lib.zig", .line_deltas = &.{}, .word_deltas = &.{}, .lines_added = 0, .lines_removed = 0, .words_added = 0, .words_removed = 0 },
        .{ .path = "test/foo.zig", .line_deltas = &.{}, .word_deltas = &.{}, .lines_added = 0, .lines_removed = 0, .words_added = 0, .words_removed = 0 },
    };
    var ptrs = [_]*const FileDiff{ &files[0], &files[1], &files[2] };
    const groups = try groupByDirectory(alloc, &ptrs);
    defer {
        for (groups) |g| alloc.free(g.files);
        alloc.free(groups);
    }
    try std.testing.expectEqual(@as(usize, 2), groups.len);
}

test "groupByDirectory returns directories in sorted order regardless of insertion order" {
    const alloc = std.testing.allocator;
    const files = &[_]FileDiff{
        .{ .path = "zzz/a.zig", .line_deltas = &.{}, .word_deltas = &.{}, .lines_added = 0, .lines_removed = 0, .words_added = 0, .words_removed = 0 },
        .{ .path = "aaa/b.zig", .line_deltas = &.{}, .word_deltas = &.{}, .lines_added = 0, .lines_removed = 0, .words_added = 0, .words_removed = 0 },
        .{ .path = "mmm/c.zig", .line_deltas = &.{}, .word_deltas = &.{}, .lines_added = 0, .lines_removed = 0, .words_added = 0, .words_removed = 0 },
    };
    var ptrs = [_]*const FileDiff{ &files[0], &files[1], &files[2] };
    const groups = try groupByDirectory(alloc, &ptrs);
    defer {
        for (groups) |g| alloc.free(g.files);
        alloc.free(groups);
    }
    try std.testing.expectEqual(@as(usize, 3), groups.len);
    try std.testing.expectEqualStrings("aaa", groups[0].dir);
    try std.testing.expectEqualStrings("mmm", groups[1].dir);
    try std.testing.expectEqualStrings("zzz", groups[2].dir);
}

test {
    std.testing.refAllDecls(@This());
}
