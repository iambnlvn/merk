//  Two passes on every changed file:
//    * Line-level unified diff  (for display, `nodus show`)
//    * Word-level diff          (for precision, intent classifier)
//
//  Neither pass requires the AST to work — they operate on raw source bytes.
//  The AST delta layer lives in an intent layer  and consumes these results.
//
//  Algorithm: Myers diff (O(ND) shortest edit script)

const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

pub const Op = enum(u8) {
    eq = 0, // unchanged
    ins = 1, // inserted
    del = 2, // deleted
};

pub const LineDelta = struct {
    op: Op,
    /// Line content, NOT including the trailing newline
    content: []const u8,
    /// 1-based line number in the old file (0 = not present in old)
    old_lineno: u32,
    /// 1-based line number in the new file (0 = not present in new)
    new_lineno: u32,
};

pub const WordDelta = struct {
    op: Op,
    word: []const u8,
    /// Which line (1-based in new file, or old file for deletions) this word
    /// belongs to.  Lets the renderer re-associate words with lines
    lineno: u32,
};

pub const FileDiff = struct {
    path: []const u8,
    line_deltas: []LineDelta,
    word_deltas: []WordDelta,

    /// Count of lines added / removed / changed (for summary display)
    lines_added: u32,
    lines_removed: u32,
    /// Count of words added / removed
    words_added: u32,
    words_removed: u32,

    pub fn deinit(self: *FileDiff, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.line_deltas);
        alloc.free(self.word_deltas);
    }
};

//
//  The full diff for a commit: one FileDiff per changed file, plus hashes of
//  the serialized forms stored in the object store

pub const CommitDiff = struct {
    files: []FileDiff,
    /// Hash of the serialized unified line diff (stored as a blob)
    line_diff_hash: Hash,
    /// Hash of the serialized word diff (stored as a blob)
    word_diff_hash: Hash,

    pub fn deinit(self: *CommitDiff, alloc: std.mem.Allocator) void {
        for (self.files) |*f| f.deinit(alloc);
        alloc.free(self.files);
    }
};

/// Diff two source texts for a single file
/// Returns a FileDiff whose slices point into `old_src` and `new_src`
/// the caller must ensure those are alive while the diff is in use
/// The `path` string is duped into `alloc`
pub fn diffFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    old_src: []const u8,
    new_src: []const u8,
) !FileDiff {
    const old_lines = try splitLines(alloc, old_src);
    defer alloc.free(old_lines);
    const new_lines = try splitLines(alloc, new_src);
    defer alloc.free(new_lines);

    const line_deltas = try myersDiff(LineDelta, alloc, old_lines, new_lines, lineEq, makeLineDelta);
    errdefer alloc.free(line_deltas);

    var lines_added: u32 = 0;
    var lines_removed: u32 = 0;
    for (line_deltas) |d| switch (d.op) {
        .ins => lines_added += 1,
        .del => lines_removed += 1,
        .eq => {},
    };

    const word_deltas = try diffWords(alloc, line_deltas);
    errdefer alloc.free(word_deltas);

    var words_added: u32 = 0;
    var words_removed: u32 = 0;
    for (word_deltas) |d| switch (d.op) {
        .ins => words_added += 1,
        .del => words_removed += 1,
        .eq => {},
    };

    return .{
        .path = try alloc.dupe(u8, path),
        .line_deltas = line_deltas,
        .word_deltas = word_deltas,
        .lines_added = lines_added,
        .lines_removed = lines_removed,
        .words_added = words_added,
        .words_removed = words_removed,
    };
}

/// Diff all changed files between two sets of (path, source) pairs and store
/// the serialized diffs in the object store
/// `old_files` and `new_files` are slices of (path, content) tuples,
/// sorted by path
pub fn diffCommit(
    alloc: std.mem.Allocator,
    store: *const Store,
    old_files: []const FileSnapshot,
    new_files: []const FileSnapshot,
) !CommitDiff {
    var file_diffs: std.ArrayList(FileDiff) = .empty;
    errdefer {
        for (file_diffs.items) |*f| f.deinit(alloc);
        file_diffs.deinit(alloc);
    }

    // Walk the two sorted lists together (merge-join on path)
    var oi: usize = 0;
    var ni: usize = 0;

    while (oi < old_files.len or ni < new_files.len) {
        const cmp: std.math.Order = blk: {
            if (oi >= old_files.len) break :blk .gt;
            if (ni >= new_files.len) break :blk .lt;
            break :blk std.mem.order(u8, old_files[oi].path, new_files[ni].path);
        };

        const path: []const u8 = if (cmp != .gt) old_files[oi].path else new_files[ni].path;
        const old_src: []const u8 = if (cmp != .gt) old_files[oi].content else "";
        const new_src: []const u8 = if (cmp != .lt) new_files[ni].content else "";

        if (!std.mem.eql(u8, old_src, new_src)) {
            const fd = try diffFile(alloc, path, old_src, new_src);
            try file_diffs.append(alloc, fd);
        }

        if (cmp != .gt) oi += 1;
        if (cmp != .lt) ni += 1;
    }

    const files = try file_diffs.toOwnedSlice(alloc);

    // Serialize both diff types and store them as blobs
    const line_blob = try serializeLineDiffs(alloc, files);
    defer alloc.free(line_blob);
    const line_hash = try store.put(.blob, line_blob);

    const word_blob = try serializeWordDiffs(alloc, files);
    defer alloc.free(word_blob);
    const word_hash = try store.put(.blob, word_blob);

    return .{
        .files = files,
        .line_diff_hash = line_hash,
        .word_diff_hash = word_hash,
    };
}

/// A (path, content) snapshot of a single file
pub const FileSnapshot = struct {
    path: []const u8,
    content: []const u8,
};

pub const DiffView = enum {
    sideBySide,
    grouped,
    block,
    wordHighlight,
    summary,
    operations,
    modern,
};

pub const RenderOptions = struct {
    view: DiffView = .modern,
    color: bool = false,
    context_lines: u32 = 3,
    max_column_width: u32 = 60,
};

pub const UnifiedOptions = RenderOptions;

pub fn parseView(view_name: []const u8) ?DiffView {
    const map = std.StaticStringMap(DiffView).initComptime(.{
        .{ "side-by-side", .sideBySide },
        .{ "grouped", .grouped },
        .{ "block", .block },
        .{ "word-highlight", .wordHighlight },
        .{ "summary", .summary },
        .{ "operations", .operations },
        .{ "modern", .modern },
    });

    return map.get(view_name);
}

fn fileStatus(fd: *const FileDiff) []const u8 {
    var has_ins = false;
    var has_del = false;
    for (fd.line_deltas) |d| switch (d.op) {
        .ins => has_ins = true,
        .del => has_del = true,
        .eq => {},
    };
    return if (has_ins and has_del) "M" else if (has_ins) "A" else if (has_del) "D" else "~";
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
        const pad_len = width - text.len;
        for (0..pad_len) |_| try writer.writeByte(' ');
    }
}

pub fn renderDiff(writer: anytype, fd: *const FileDiff, options: RenderOptions) !void {
    switch (options.view) {
        .sideBySide => try renderSideBySide(writer, fd, options),
        .grouped => try renderGrouped(writer, fd, options),
        .block => try renderBlockOriented(writer, fd, options),
        .wordHighlight => try renderWordHighlight(writer, fd, options),
        .summary => try renderModern(writer, fd, options),
        .operations => try renderOperations(writer, fd, options),
        .modern => try renderModern(writer, fd, options),
    }
}

pub fn renderUnified(writer: anytype, fd: *const FileDiff, options: RenderOptions) !void {
    try renderModern(writer, fd, options);
}

fn writeSectionDivider(writer: anytype, width: usize) !void {
    for (0..width) |_| try writer.writeAll("━");
    try writer.writeByte('\n');
}

fn renderSideBySide(writer: anytype, fd: *const FileDiff, options: RenderOptions) !void {
    const col_width = maxLineWidth(fd.line_deltas, @as(usize, @intCast(options.max_column_width)));
    const sep = " │ ";

    try writer.print("FILE  {s}\n", .{fd.path});
    try writer.writeAll("│ Before");
    if (col_width > 6) for (0..col_width - 6) |_| try writer.writeByte(' ');
    try writer.writeAll(sep);
    try writer.writeAll("After");
    if (col_width > 5) for (0..col_width - 5) |_| try writer.writeByte(' ');
    try writer.writeByte('\n');

    const total_width = 1 + col_width + sep.len + col_width + 1;
    for (0..total_width) |_| try writer.writeAll("─");
    try writer.writeByte('\n');

    for (fd.line_deltas) |d| {
        const left = switch (d.op) {
            .ins => "",
            .del => d.content,
            .eq => d.content,
        };
        const right = switch (d.op) {
            .del => "",
            .ins => d.content,
            .eq => d.content,
        };

        try writer.writeAll("│");
        try writePadded(writer, left, col_width);
        try writer.writeAll(sep);
        try writePadded(writer, right, col_width);
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
}

fn renderGrouped(writer: anytype, fd: *const FileDiff, options: RenderOptions) !void {
    try writer.print("FILE: {s}\n", .{fd.path});

    const deltas = fd.line_deltas;
    if (deltas.len == 0) return;

    var i: usize = 0;
    while (i < deltas.len) {
        while (i < deltas.len and deltas[i].op == .eq) i += 1;
        if (i >= deltas.len) break;

        const start = if (i >= options.context_lines) i - options.context_lines else 0;
        var hunk_end: usize = i;
        while (hunk_end < deltas.len) {
            if (deltas[hunk_end].op != .eq) {
                hunk_end = @min(hunk_end + @as(usize, @intCast(options.context_lines)) + 1, deltas.len);
            } else {
                var lookahead = hunk_end;
                var eq_run: u32 = 0;
                while (lookahead < deltas.len and deltas[lookahead].op == .eq) {
                    lookahead += 1;
                    eq_run += 1;
                }
                if (eq_run > options.context_lines * 2 or lookahead >= deltas.len) {
                    hunk_end = @min(hunk_end + @as(usize, @intCast(options.context_lines)), deltas.len);
                    break;
                }
                hunk_end = lookahead;
            }
        }

        var old_start: u32 = 0;
        var old_count: u32 = 0;
        var new_start: u32 = 0;
        var new_count: u32 = 0;
        for (deltas[start..hunk_end]) |d| {
            switch (d.op) {
                .eq => {
                    if (old_start == 0) old_start = d.old_lineno;
                    if (new_start == 0) new_start = d.new_lineno;
                    old_count += 1;
                    new_count += 1;
                },
                .del => {
                    if (old_start == 0) old_start = d.old_lineno;
                    old_count += 1;
                },
                .ins => {
                    if (new_start == 0) new_start = d.new_lineno;
                    new_count += 1;
                },
            }
        }

        const title = if (old_count == 0) "Added Lines" else if (new_count == 0) "Removed Lines" else "Modified Lines";
        const begin_line = if (old_count == 0) new_start else old_start;
        const end_line = if (old_count != 0) old_start + old_count - 1 else new_start + new_count - 1;
        try writer.print("{s} {d}-{d}\n", .{ title, begin_line, end_line });
        try writeSectionDivider(writer, 40);
        for (deltas[start..hunk_end]) |d| {
            if (d.op == .eq) continue;
            const prefix = if (d.op == .ins) "+" else "-";
            try writer.print("{s} {s}\n", .{ prefix, d.content });
        }
        try writer.writeByte('\n');
        i = hunk_end;
    }
}

fn renderBlockOriented(writer: anytype, fd: *const FileDiff, options: RenderOptions) !void {
    try writer.print("FILE: {s}\n", .{fd.path});

    const deltas = fd.line_deltas;
    if (deltas.len == 0) return;

    var i: usize = 0;
    var change_number: usize = 1;
    while (i < deltas.len) {
        while (i < deltas.len and deltas[i].op == .eq) i += 1;
        if (i >= deltas.len) break;

        const start = if (i >= options.context_lines) i - options.context_lines else 0;
        var hunk_end: usize = i;
        while (hunk_end < deltas.len) {
            if (deltas[hunk_end].op != .eq) {
                hunk_end = @min(hunk_end + @as(usize, @intCast(options.context_lines)) + 1, deltas.len);
            } else {
                var lookahead = hunk_end;
                var eq_run: u32 = 0;
                while (lookahead < deltas.len and deltas[lookahead].op == .eq) {
                    lookahead += 1;
                    eq_run += 1;
                }
                if (eq_run > options.context_lines * 2 or lookahead >= deltas.len) {
                    hunk_end = @min(hunk_end + @as(usize, @intCast(options.context_lines)), deltas.len);
                    break;
                }
                hunk_end = lookahead;
            }
        }

        try writer.print("CHANGE #{d}\n", .{change_number});
        try writeSectionDivider(writer, 32);
        try writer.print("BEFORE\n", .{});
        for (deltas[start..hunk_end]) |d| if (d.op != .ins) try writer.print("{s}\n", .{d.content});
        try writer.print("AFTER\n", .{});
        for (deltas[start..hunk_end]) |d| if (d.op != .del) try writer.print("{s}\n", .{d.content});
        try writer.writeByte('\n');
        change_number += 1;
        i = hunk_end;
    }
}

fn renderWordHighlight(writer: anytype, fd: *const FileDiff, options: RenderOptions) !void {
    try writer.print("WORD HIGHLIGHT: {s}\n", .{fd.path});
    _ = options;
    var current_line: u32 = 0;
    for (fd.word_deltas) |d| {
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
    try writer.writeByte('\n');
}

fn renderOperations(writer: anytype, fd: *const FileDiff, options: RenderOptions) !void {
    const status = fileStatus(fd);
    try writer.print("FILE  {s}\n", .{fd.path});
    try writer.print("STATUS: {s}\n\n", .{status});

    const deltas = fd.line_deltas;
    if (deltas.len == 0) return;

    var i: usize = 0;
    while (i < deltas.len) {
        while (i < deltas.len and deltas[i].op == .eq) i += 1;
        if (i >= deltas.len) break;

        const start = if (i >= options.context_lines) i - options.context_lines else 0;
        var hunk_end: usize = i;
        while (hunk_end < deltas.len) {
            if (deltas[hunk_end].op != .eq) {
                hunk_end = @min(hunk_end + @as(usize, @intCast(options.context_lines)) + 1, deltas.len);
            } else {
                var lookahead = hunk_end;
                var eq_run: u32 = 0;
                while (lookahead < deltas.len and deltas[lookahead].op == .eq) {
                    lookahead += 1;
                    eq_run += 1;
                }
                if (eq_run > options.context_lines * 2 or lookahead >= deltas.len) {
                    hunk_end = @min(hunk_end + @as(usize, @intCast(options.context_lines)), deltas.len);
                    break;
                }
                hunk_end = lookahead;
            }
        }

        var line_num: u32 = 0;
        for (deltas[start..hunk_end]) |d| {
            if (d.op != .ins) line_num = d.old_lineno;
        }
        if (line_num == 0) line_num = deltas[start].new_lineno;

        try writer.print("FROM line {d}\n", .{line_num});
        for (deltas[start..hunk_end]) |d| if (d.op != .ins) try writer.print("  {s}\n", .{d.content});
        try writer.print("\nTO line {d}\n", .{line_num});
        for (deltas[start..hunk_end]) |d| if (d.op != .del) try writer.print("  {s}\n", .{d.content});
        try writer.writeByte('\n');
        i = hunk_end;
    }
}

pub fn renderSummaryView(writer: anytype, fds: []const FileDiff, options: RenderOptions) !void {
    try writer.writeAll("Changes\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    for (fds) |fd| {
        const status = fileStatus(&fd);
        try writer.print("{s} {s} (+{d} -{d})\n", .{ status, fd.path, fd.lines_added, fd.lines_removed });
    }
    try writer.writeAll("\n");
    for (fds) |fd| {
        try renderModern(writer, &fd, options);
    }
}

pub fn renderModern(writer: anytype, fd: *const FileDiff, options: RenderOptions) !void {
    try writer.print("FILE  {s}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{fd.path});
    const deltas = fd.line_deltas;
    if (deltas.len == 0) return;

    var i: usize = 0;
    while (i < deltas.len) {
        while (i < deltas.len and deltas[i].op == .eq) i += 1;
        if (i >= deltas.len) break;

        const start = if (i >= options.context_lines) i - options.context_lines else 0;
        var hunk_end: usize = i;
        while (hunk_end < deltas.len) {
            if (deltas[hunk_end].op != .eq) {
                hunk_end = @min(hunk_end + @as(usize, @intCast(options.context_lines)) + 1, deltas.len);
            } else {
                var lookahead = hunk_end;
                var eq_run: u32 = 0;
                while (lookahead < deltas.len and deltas[lookahead].op == .eq) {
                    lookahead += 1;
                    eq_run += 1;
                }
                if (eq_run > options.context_lines * 2 or lookahead >= deltas.len) {
                    hunk_end = @min(hunk_end + @as(usize, @intCast(options.context_lines)), deltas.len);
                    break;
                }
                hunk_end = lookahead;
            }
        }

        var line_num: u32 = 0;
        for (deltas[start..hunk_end]) |d| {
            if (d.op != .ins) line_num = d.old_lineno;
        }
        if (line_num == 0) line_num = deltas[start].new_lineno;
        try writer.print("~ Line {d}\n", .{line_num});

        for (deltas[start..hunk_end]) |d| {
            switch (d.op) {
                .eq => try writer.print("  {s}\n", .{d.content}),
                .del => try writer.print("- {s}\n", .{d.content}),
                .ins => try writer.print("+ {s}\n", .{d.content}),
            }
        }
        try writer.writeByte('\n');
        i = hunk_end;
    }
}

/// Write a word-level diff for a single FileDiff to `writer`
/// Changed words are wrapped in [+word+] / [-word-] markers
pub fn renderWordDiff(writer: anytype, fd: *const FileDiff) !void {
    try writer.print("WORD HIGHLIGHT: {s}\n", .{fd.path});

    var current_line: u32 = 0;
    for (fd.word_deltas) |d| {
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

//  Classic O(ND) Myers shortest edit script
//  Generic over the element type so we can reuse for both lines and words

fn myersDiff(
    comptime T: type,
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    eqFn: fn ([]const u8, []const u8) bool,
    makeDelta: fn (Op, []const u8, u32, u32) T,
) ![]T {
    const N = old.len;
    const M = new.len;
    const max_d = N + M;

    if (max_d == 0) return &.{};

    // v[k] = furthest x reached on diagonal k
    // We allocate 2*max_d+1 so we can index with offset = max_d
    const v_len = 2 * max_d + 1;
    const v = try alloc.alloc(isize, v_len);
    defer alloc.free(v);
    @memset(v, 0);

    // Record the full trace for backtracking
    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |snap| alloc.free(snap);
        trace.deinit(alloc);
    }

    const offset: isize = @intCast(max_d);

    outer: for (0..max_d + 1) |d| {
        // Snapshot v before this round for backtracking
        const snap = try alloc.dupe(isize, v);
        errdefer alloc.free(snap);
        try trace.append(alloc, snap);

        var k: isize = -@as(isize, @intCast(d));
        while (k <= @as(isize, @intCast(d))) : (k += 2) {
            const ki: usize = @intCast(k + offset);
            var x: isize = if (k == -@as(isize, @intCast(d)) or
                (k != @as(isize, @intCast(d)) and
                    v[ki - 1] < v[ki + 1]))
                v[ki + 1]
            else
                v[ki - 1] + 1;

            var y: isize = x - k;

            // Extend along matching diagonal (snake)
            while (x < @as(isize, @intCast(N)) and y < @as(isize, @intCast(M)) and
                eqFn(old[@intCast(x)], new[@intCast(y)]))
            {
                x += 1;
                y += 1;
            }

            v[ki] = x;

            if (x >= @as(isize, @intCast(N)) and y >= @as(isize, @intCast(M))) break :outer;
        }
    }

    // Backtrack through the trace to reconstruct the edit script
    var ops: std.ArrayList(T) = .empty;
    errdefer ops.deinit(alloc);

    var x: isize = @intCast(N);
    var y: isize = @intCast(M);

    var d: isize = @intCast(trace.items.len - 1);
    while (d >= 0) : (d -= 1) {
        const snap = trace.items[@intCast(d)];
        const k = x - y;
        const ki: usize = @intCast(k + offset);

        const prev_k: isize = if (k == -d or (k != d and snap[ki - 1] < snap[ki + 1]))
            k + 1
        else
            k - 1;

        const prev_x = snap[@intCast(prev_k + offset)];
        const prev_y = prev_x - prev_k;

        // Walk back the snake (eq operations)
        while (x > prev_x + 1 and y > prev_y + 1) {
            x -= 1;
            y -= 1;
            try ops.append(alloc, makeDelta(.eq, old[@intCast(x)], @intCast(x + 1), @intCast(y + 1)));
        }

        if (d > 0) {
            if (x == prev_x) {
                // Insertion
                y -= 1;
                try ops.append(alloc, makeDelta(.ins, new[@intCast(y)], 0, @intCast(y + 1)));
            } else {
                // Deletion
                x -= 1;
                try ops.append(alloc, makeDelta(.del, old[@intCast(x)], @intCast(x + 1), 0));
            }
        }

        // Remaining snake at start
        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
            try ops.append(alloc, makeDelta(.eq, old[@intCast(x)], @intCast(x + 1), @intCast(y + 1)));
        }
    }

    // Reverse
    std.mem.reverse(T, ops.items);
    return ops.toOwnedSlice(alloc);
}

fn diffWords(alloc: std.mem.Allocator, line_deltas: []const LineDelta) ![]WordDelta {
    var out: std.ArrayList(WordDelta) = .empty;
    errdefer out.deinit(alloc);

    // Group consecutive ins/del pairs by scanning changed runs
    // For each changed run, diff the old words vs new words
    var i: usize = 0;
    while (i < line_deltas.len) {
        const d = line_deltas[i];
        if (d.op == .eq) {
            i += 1;
            continue;
        }

        // Collect a run of del then ins (or mixed)
        var del_words: std.ArrayList([]const u8) = .empty;
        defer del_words.deinit(alloc);
        var ins_words: std.ArrayList([]const u8) = .empty;
        defer ins_words.deinit(alloc);
        var del_lineno: u32 = d.old_lineno;
        var ins_lineno: u32 = d.new_lineno;

        var j = i;
        while (j < line_deltas.len and line_deltas[j].op != .eq) : (j += 1) {
            const ld = line_deltas[j];
            if (ld.op == .del) {
                if (del_lineno == 0) del_lineno = ld.old_lineno;
                const words = try tokenizeWords(alloc, ld.content);
                defer alloc.free(words);
                try del_words.appendSlice(alloc, words);
            } else {
                if (ins_lineno == 0) ins_lineno = ld.new_lineno;
                const words = try tokenizeWords(alloc, ld.content);
                defer alloc.free(words);
                try ins_words.appendSlice(alloc, words);
            }
        }

        // Myers diff on the word sequences
        const lineno = if (ins_lineno != 0) ins_lineno else del_lineno;
        const word_ops = try myersDiff(
            WordDelta,
            alloc,
            del_words.items,
            ins_words.items,
            wordEq,
            makeWordDelta,
        );
        defer alloc.free(word_ops);

        for (word_ops) |wd| {
            try out.append(alloc, .{
                .op = wd.op,
                .word = wd.word,
                .lineno = lineno,
            });
        }

        i = j;
    }

    return out.toOwnedSlice(alloc);
}

fn splitLines(alloc: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(alloc);

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        // Skip the phantom empty line that splitScalar adds after a trailing \n
        if (it.rest().len == 0 and line.len == 0) break;
        try lines.append(alloc, line);
    }

    return lines.toOwnedSlice(alloc);
}

/// Split a line into words (runs of non-whitespace + individual punctuation)
fn tokenizeWords(alloc: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    errdefer words.deinit(alloc);

    var i: usize = 0;
    while (i < line.len) {
        // Skip whitespace.
        if (std.ascii.isWhitespace(line[i])) {
            i += 1;
            continue;
        }

        // Identifier / number run
        if (std.ascii.isAlphanumeric(line[i]) or line[i] == '_') {
            const start = i;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
            try words.append(alloc, line[start..i]);
        } else {
            // Single punctuation token
            try words.append(alloc, line[i .. i + 1]);
            i += 1;
        }
    }

    return words.toOwnedSlice(alloc);
}

fn lineEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn makeLineDelta(op: Op, content: []const u8, old_lineno: u32, new_lineno: u32) LineDelta {
    return .{
        .op = op,
        .content = content,
        .old_lineno = old_lineno,
        .new_lineno = new_lineno,
    };
}

fn wordEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn makeWordDelta(op: Op, word: []const u8, _: u32, _: u32) WordDelta {
    return .{ .op = op, .word = word, .lineno = 0 };
}

//  Stored as a compact binary blob in the object store.
//  Line diff format:
//    [4]  file_count (u32)
//    per file:
//      [2]  path_len (u16)
//      [n]  path bytes
//      [4]  delta_count (u32)
//      per delta:
//        [1]  op
//        [4]  old_lineno
//        [4]  new_lineno
//        [2]  content_len
//        [n]  content bytes
//

fn serializeLineDiffs(alloc: std.mem.Allocator, files: []const FileDiff) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeInt(u32, @intCast(files.len), .little);
    for (files) |f| {
        try w.writeInt(u16, @intCast(f.path.len), .little);
        try w.writeAll(f.path);
        try w.writeInt(u32, @intCast(f.line_deltas.len), .little);
        for (f.line_deltas) |d| {
            try w.writeByte(@intFromEnum(d.op));
            try w.writeInt(u32, d.old_lineno, .little);
            try w.writeInt(u32, d.new_lineno, .little);
            try w.writeInt(u16, @intCast(d.content.len), .little);
            try w.writeAll(d.content);
        }
    }

    return buf.toOwnedSlice(alloc);
}

fn serializeWordDiffs(alloc: std.mem.Allocator, files: []const FileDiff) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeInt(u32, @intCast(files.len), .little);
    for (files) |f| {
        try w.writeInt(u16, @intCast(f.path.len), .little);
        try w.writeAll(f.path);
        try w.writeInt(u32, @intCast(f.word_deltas.len), .little);
        for (f.word_deltas) |d| {
            try w.writeByte(@intFromEnum(d.op));
            try w.writeInt(u32, d.lineno, .little);
            try w.writeInt(u16, @intCast(d.word.len), .little);
            try w.writeAll(d.word);
        }
    }

    return buf.toOwnedSlice(alloc);
}

test "splitLines basic" {
    const alloc = std.testing.allocator;
    const lines = try splitLines(alloc, "a\nb\nc");
    defer alloc.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("c", lines[2]);
}

test "splitLines trailing newline does not add phantom line" {
    const alloc = std.testing.allocator;
    const lines = try splitLines(alloc, "a\nb\n");
    defer alloc.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
}

test "diffFile identical sources produces no deltas" {
    const alloc = std.testing.allocator;
    const src = "fn main() void {}\n";
    var fd = try diffFile(alloc, "main.zig", src, src);
    defer fd.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 0), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
}

test "diffFile single line added" {
    const alloc = std.testing.allocator;
    const old = "fn a() void {}\n";
    const new = "fn a() void {}\nfn b() void {}\n";
    var fd = try diffFile(alloc, "x.zig", old, new);
    defer fd.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
}

test "diffFile single line removed" {
    const alloc = std.testing.allocator;
    const old = "fn a() void {}\nfn b() void {}\n";
    const new = "fn a() void {}\n";
    var fd = try diffFile(alloc, "x.zig", old, new);
    defer fd.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 0), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_removed);
}

//TODO: inspect
// test "diffFile word-level detects in-line change" {
//     const alloc = std.testing.allocator;
//     const old = "const x: u32 = 10;\n";
//     const new = "const x: u64 = 10;\n";
//     var fd = try diffFile(alloc, "x.zig", old, new);
//     defer fd.deinit(alloc);
//     // One line changed → 1 removed + 1 added at line level.
//     try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
//     try std.testing.expectEqual(@as(u32, 1), fd.lines_removed);
//     // Word diff should capture "u32" removed and "u64" added.
//     var found_del = false;
//     var found_ins = false;
//     for (fd.word_deltas) |wd| {
//         if (wd.op == .del and std.mem.eql(u8, wd.word, "u32")) found_del = true;
//         if (wd.op == .ins and std.mem.eql(u8, wd.word, "u64")) found_ins = true;
//     }
//     try std.testing.expect(found_del);
//     try std.testing.expect(found_ins);
// }

test "tokenizeWords splits identifiers and punctuation" {
    const alloc = std.testing.allocator;
    const words = try tokenizeWords(alloc, "fn foo(x: u32)");
    defer alloc.free(words);
    // fn foo ( x : u32 )
    try std.testing.expectEqual(@as(usize, 7), words.len);
    try std.testing.expectEqualStrings("fn", words[0]);
    try std.testing.expectEqualStrings("foo", words[1]);
    try std.testing.expectEqualStrings("(", words[2]);
}
//TODO: inspect
// test "renderUnified produces valid output" {
//     const alloc = std.testing.allocator;
//     const old = "line one\nline two\nline three\n";
//     const new = "line one\nline TWO\nline three\n";
//     var fd = try diffFile(alloc, "test.txt", old, new);
//     defer fd.deinit(alloc);

//     var out: std.ArrayList(u8) = .empty;
//     defer out.deinit(alloc);
//     try renderUnified(out.writer(alloc), &fd, .{});

//     const rendered = out.items;
//     try std.testing.expect(std.mem.indexOf(u8, rendered, "---") != null);
//     try std.testing.expect(std.mem.indexOf(u8, rendered, "+++") != null);
//     try std.testing.expect(std.mem.indexOf(u8, rendered, "-line two") != null);
//     try std.testing.expect(std.mem.indexOf(u8, rendered, "+line TWO") != null);
// }

test "summarize aggregates across files" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = object.Store{ .dir = objects_dir, .alloc = alloc };

    const old_files = [_]FileSnapshot{
        .{ .path = "a.txt", .content = "hello\nworld\n" },
        .{ .path = "b.txt", .content = "foo\n" },
    };
    const new_files = [_]FileSnapshot{
        .{ .path = "a.txt", .content = "hello\nearth\n" },
        .{ .path = "b.txt", .content = "foo\nbar\n" },
    };

    var cd = try diffCommit(alloc, &store, &old_files, &new_files);
    defer cd.deinit(alloc);

    const s = summarize(&cd);
    try std.testing.expectEqual(@as(u32, 2), s.files_changed);
    try std.testing.expectEqual(@as(u32, 2), s.lines_added);
    try std.testing.expectEqual(@as(u32, 1), s.lines_removed);
}
