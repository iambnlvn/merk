//  Two passes on every changed file:
//    * Line-level unified diff  (for display, `nodus show`)
//    * Word-level diff          (for precision, intent classifier)
//
//  Neither pass requires the AST to work — they operate on raw source bytes.
//  The AST delta layer lives in an intent layer and consumes these results.
//
//  This file has two halves:
//
//    1. A storage-agnostic content-diff engine (Myers/Patience/Histogram,
//       FileDiff/WordDelta, all the render formats) — unchanged from
//       before, since none of it ever touched how snapshots are stored.
//
//    2. A thin merkle-tree adapter (`diffSnapshotRoots`, `diffCommits`,
//       `diffCommitAgainstParent`) that turns two snapshot-root hashes
//       into per-path `EntryChange`s via `merk.merkle.diffRoots`, then
//       runs the content-diff engine over just the paths that changed.
//       The old tree-walking/pruning logic that used to live in this
//       file (separately handling legacy `tree_mod` trees, `index_mod`
//       B-tree pages, and the "one side is legacy, one is index" mixed
//       case) is gone — `merk.merkle` is now the only snapshot
//       representation, and its `diffRoots` already does the pruning
//       (identical page hashes are never even read from disk).
//
//  Myers     — O(ND) shortest edit script.  Minimal edits, can produce noisy
//              hunks when coincidental matches exist deep in changed regions
//
//  Patience  — Anchors the LCS on unique lines first (function signatures,
//              closing braces, etc), then recurses.  Produces human-readable
//              hunks on typical source code.  Falls back to Myers for segments
//              that have no unique anchors.
//
//  Histogram — uses occurrence-frequency buckets so rarer
//              lines are preferred as anchors even when not strictly unique
//              Degrades to Myers when the histogram finds nothing useful
//

const std = @import("std");

pub const Op = enum(u8) {
    eq = 0,
    ins = 1,
    del = 2,
};

const merk = @import("merk");
const hash_mod = merk.crypto.hash;
const merkle_mod = merk.merkle;
const object_mod = @import("object/object.zig");
const commit_mod = @import("commit.zig");

const Hash = hash_mod.Hash;

/// Diff two snapshot roots — hashes of merkle B-tree pages built by
/// `merk.merkle.build` (what `Index.save`/`History.commit` produce).
/// `old_root == null` means "empty tree" (the root-commit case): every
/// entry in `new_root` shows up as added.
///
/// The tree walk itself is `merkle_mod.diffRoots`'s job — including the
/// pruning that makes it cheap: identical page hashes are skipped
/// without ever being read from disk, so an unchanged subtree costs
/// nothing regardless of its size. This function's only responsibility
/// is turning the resulting per-path `EntryChange`s into content-level
/// line/word diffs by fetching just the changed blobs.
pub fn diffSnapshotRoots(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const merkle_mod.PageStore,
    old_root: ?Hash,
    new_root: Hash,
    algo: Algorithm,
) !CommitDiff {
    const normalized_old = old_root orelse hash_mod.zero_hash;
    const changes = try merkle_mod.diffRoots(alloc, page_store, normalized_old, new_root);
    defer merkle_mod.freeChanges(alloc, changes);

    var file_diffs: std.ArrayList(FileDiff) = .empty;
    var blobs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (file_diffs.items) |*f| f.deinit(alloc);
        file_diffs.deinit(alloc);
        for (blobs.items) |b| alloc.free(b);
        blobs.deinit(alloc);
    }

    for (changes) |c| {
        const old_src = if (c.old_blob_hash) |h| blk: {
            const obj = try store.get(h);
            try blobs.append(alloc, obj.payload);
            break :blk obj.payload;
        } else "";

        const new_src = if (c.new_blob_hash) |h| blk: {
            const obj = try store.get(h);
            try blobs.append(alloc, obj.payload);
            break :blk obj.payload;
        } else "";

        try file_diffs.append(alloc, try diffFileWith(alloc, c.path, old_src, new_src, algo));
    }

    return .{
        .files = try file_diffs.toOwnedSlice(alloc),
        .line_diff_hash = .{0} ** 32,
        .word_diff_hash = .{0} ** 32,
        .blobs = try blobs.toOwnedSlice(alloc),
    };
}

/// Diff the snapshot of `new_commit` against the snapshot of `old_commit`.
/// Pass `null` for `old_commit` to diff against an empty tree, e.g. for
/// the root commit, where there is no parent to compare against.
pub fn diffCommits(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const merkle_mod.PageStore,
    old_commit: ?Hash,
    new_commit: Hash,
    algo: Algorithm,
) !CommitDiff {
    var new_c = try commit_mod.read(alloc, store, new_commit);
    defer new_c.deinit(alloc);

    var old_root: ?Hash = null;
    var old_c: ?commit_mod.Commit = null;
    defer if (old_c) |*c| c.deinit(alloc);

    if (old_commit) |oc| {
        old_c = try commit_mod.read(alloc, store, oc);
        old_root = old_c.?.snapshot;
    }

    return diffSnapshotRoots(alloc, store, page_store, old_root, new_c.snapshot, algo);
}

/// Diff `new_commit` against its first parent. If `new_commit` has no
/// parents (a root commit), diffs against an empty tree. For a merge
/// commit (more than one `ParentInfo`), this is a first-parent diff —
/// same convention `git show` uses by default — not a diff against
/// every parent.
pub fn diffCommitAgainstParent(
    alloc: std.mem.Allocator,
    store: *const object_mod.Store,
    page_store: *const merkle_mod.PageStore,
    new_commit: Hash,
    algo: Algorithm,
) !CommitDiff {
    var new_c = try commit_mod.read(alloc, store, new_commit);
    defer new_c.deinit(alloc);

    const old_root: ?Hash = if (new_c.parents.len > 0) blk: {
        var parent_c = try commit_mod.read(alloc, store, new_c.parents[0].hash);
        defer parent_c.deinit(alloc);
        break :blk parent_c.snapshot;
    } else null;

    return diffSnapshotRoots(alloc, store, page_store, old_root, new_c.snapshot, algo);
}

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

    lines_added: u32,
    lines_removed: u32,
    words_added: u32,
    words_removed: u32,

    pub fn deinit(self: *FileDiff, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.line_deltas);
        alloc.free(self.word_deltas);
    }
};

pub const CommitDiff = struct {
    files: []FileDiff,
    /// Hash of the serialized unified line diff (stored as a blob)
    line_diff_hash: [32]u8,
    /// Hash of the serialized word diff (stored as a blob)
    word_diff_hash: [32]u8,
    /// Backing blob buffers that FileDiff.line_deltas[].content slices
    /// point into. Owned by the CommitDiff for its whole lifetime —
    /// freeing these before deinit() dangles every content slice.
    blobs: [][]u8 = &.{},

    pub fn deinit(self: *CommitDiff, alloc: std.mem.Allocator) void {
        for (self.files) |*f| f.deinit(alloc);
        alloc.free(self.files);
        for (self.blobs) |b| alloc.free(b);
        alloc.free(self.blobs);
    }
};
/// A (path, content) snapshot of a single file
pub const FileSnapshot = struct {
    path: []const u8,
    content: []const u8,
};

pub const Algorithm = enum {
    myers,
    patience,
    histogram,
};

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
    algorithm: Algorithm = .histogram,

    pub fn contextLines(self: RenderConfig) u32 {
        return self.context.lines();
    }
};

pub fn diffFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    old_src: []const u8,
    new_src: []const u8,
) !FileDiff {
    return diffFileWith(alloc, path, old_src, new_src, .histogram);
}

pub fn diffFileWith(
    alloc: std.mem.Allocator,
    path: []const u8,
    old_src: []const u8,
    new_src: []const u8,
    algo: Algorithm,
) !FileDiff {
    const old_lines = try splitLines(alloc, old_src);
    defer alloc.free(old_lines);
    const new_lines = try splitLines(alloc, new_src);
    defer alloc.free(new_lines);

    const line_deltas = try runLineDiff(alloc, old_lines, new_lines, algo);
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

pub fn diffCommit(
    alloc: std.mem.Allocator,
    old_files: []const FileSnapshot,
    new_files: []const FileSnapshot,
) !CommitDiff {
    return diffCommitWith(alloc, old_files, new_files, .histogram);
}

/// Diff two already-in-memory (path, content) snapshots directly, without
/// touching any store — for callers that have both full file sets on hand
/// already (e.g. comparing a worktree scan to the index) rather than two
/// stored merkle roots. For diffing stored snapshots/commits, prefer
/// `diffSnapshotRoots`/`diffCommits`, which only fetch the blobs that
/// actually changed instead of every file on both sides.
pub fn diffCommitWith(
    alloc: std.mem.Allocator,
    old_files: []const FileSnapshot,
    new_files: []const FileSnapshot,
    algo: Algorithm,
) !CommitDiff {
    var file_diffs: std.ArrayList(FileDiff) = .empty;
    errdefer {
        for (file_diffs.items) |*f| f.deinit(alloc);
        file_diffs.deinit(alloc);
    }

    var oi: usize = 0;
    var ni: usize = 0;
    while (oi < old_files.len or ni < new_files.len) {
        const cmp: std.math.Order = blk: {
            if (oi >= old_files.len) break :blk .gt;
            if (ni >= new_files.len) break :blk .lt;
            break :blk std.mem.order(u8, old_files[oi].path, new_files[ni].path);
        };

        const path = if (cmp != .gt) old_files[oi].path else new_files[ni].path;
        const old_src = if (cmp != .gt) old_files[oi].content else "";
        const new_src = if (cmp != .lt) new_files[ni].content else "";

        if (!std.mem.eql(u8, old_src, new_src)) {
            const fd = try diffFileWith(alloc, path, old_src, new_src, algo);
            try file_diffs.append(alloc, fd);
        }

        if (cmp != .gt) oi += 1;
        if (cmp != .lt) ni += 1;
    }

    const files = try file_diffs.toOwnedSlice(alloc);
    return .{
        .files = files,
        .line_diff_hash = .{0} ** 32,
        .word_diff_hash = .{0} ** 32,
    };
}

pub fn renderCommit(writer: anytype, cd: *const CommitDiff, config: RenderConfig, alloc: std.mem.Allocator) !void {
    var filtered: std.ArrayList(*const FileDiff) = .empty;
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
        const status = fileStatus(fd);
        const sc = switch (status) {
            .added => "A",
            .deleted => "D",
            .modified => "M",
            .unchanged => "~",
        };
        try writer.print("{s} {s} (+{d} -{d})\n", .{ sc, fd.path, fd.lines_added, fd.lines_removed });
        return;
    }

    if (config.level == .word) {
        try renderWordHighlight(writer, fd);
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
    const status = fileStatus(fd);
    const sc = switch (status) {
        .added => "A",
        .deleted => "D",
        .modified => "M",
        .unchanged => "~",
    };
    try writer.print("{s} {s} (+{d} -{d})\n", .{ sc, fd.path, fd.lines_added, fd.lines_removed });
}

fn renderWordHighlight(writer: anytype, fd: *const FileDiff) !void {
    try writer.print("WORD HIGHLIGHT: {s}\n", .{fd.path});
    try renderWordDeltas(writer, fd.word_deltas);
}

pub fn renderWordDiff(writer: anytype, fd: *const FileDiff) !void {
    try writer.print("WORD HIGHLIGHT: {s}\n", .{fd.path});
    try renderWordDeltas(writer, fd.word_deltas);
}

fn renderWordDeltas(writer: anytype, word_deltas: []const WordDelta) !void {
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

pub fn groupByDirectory(alloc: std.mem.Allocator, files: []*const FileDiff) ![]DirGroup {
    var map = std.StringHashMap(std.ArrayList(*const FileDiff)).init(alloc);
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

    var groups: std.ArrayList(DirGroup) = .empty;
    var it = map.iterator();
    while (it.next()) |entry| {
        try groups.append(alloc, .{
            .dir = entry.key_ptr.*,
            .files = try entry.value_ptr.toOwnedSlice(alloc),
        });
    }
    return groups.toOwnedSlice(alloc);
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
    for (fd.line_deltas) |d| switch (d.op) {
        .ins => has_ins = true,
        .del => has_del = true,
        .eq => {},
    };
    if (has_ins and has_del) return .modified;
    if (has_ins) return .added;
    if (has_del) return .deleted;
    return .unchanged;
}

fn runLineDiff(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    algo: Algorithm,
) ![]LineDelta {
    return switch (algo) {
        .myers => myersDiff(LineDelta, alloc, old, new, 0, old.len, 0, new.len, lineEq, makeLineDelta),
        .patience => patienceDiff(alloc, old, new),
        .histogram => histogramDiff(alloc, old, new),
    };
}

// Operates on a sub-range [old_lo, old_hi) × [new_lo, new_hi) so that
// Patience and Histogram can recurse into it without copying slices.

fn myersDiff(
    comptime T: type,
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
    eqFn: fn ([]const u8, []const u8) bool,
    makeDelta: fn (Op, []const u8, u32, u32) T,
) ![]T {
    const N = old_hi - old_lo;
    const M = new_hi - new_lo;

    if (N == 0 and M == 0) return &.{};

    if (N == 0) {
        var ops = try alloc.alloc(T, M);
        for (0..M) |i| {
            ops[i] = makeDelta(.ins, new[new_lo + i], 0, @intCast(new_lo + i + 1));
        }
        return ops;
    }
    if (M == 0) {
        var ops = try alloc.alloc(T, N);
        for (0..N) |i| {
            ops[i] = makeDelta(.del, old[old_lo + i], @intCast(old_lo + i + 1), 0);
        }
        return ops;
    }

    const max_d = N + M;
    const v_len = 2 * max_d + 1;
    const v = try alloc.alloc(isize, v_len);
    defer alloc.free(v);
    @memset(v, 0);

    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |snap| alloc.free(snap);
        trace.deinit(alloc);
    }

    const offset: isize = @intCast(max_d);

    outer: for (0..max_d + 1) |d_usize| {
        const d: isize = @intCast(d_usize);
        const snap = try alloc.dupe(isize, v);
        errdefer alloc.free(snap);
        try trace.append(alloc, snap);

        var k: isize = -d;
        while (k <= d) : (k += 2) {
            const ki: usize = @intCast(k + offset);
            const move_down = k == -d or (k != d and v[ki - 1] < v[ki + 1]);
            var x: isize = if (move_down) v[ki + 1] else v[ki - 1] + 1;
            var y: isize = x - k;

            while (x < N and y < M and eqFn(old[old_lo + @as(usize, @intCast(x))], new[new_lo + @as(usize, @intCast(y))])) {
                x += 1;
                y += 1;
            }
            v[ki] = x;

            if (x >= N and y >= M) break :outer;
        }
    }

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

        // Walk back the snake: any number of matching steps, bounded by
        // actual line equality AND the prev_x/prev_y target.
        //  A single d-step's snake can be longer than
        // one line, and the gap to prev_x/prev_y is not guaranteed to be
        // diagonal once the snake is peeled off, so we check content here
        // rather than assuming geometry
        while (x > prev_x and y > prev_y and
            eqFn(old[old_lo + @as(usize, @intCast(x - 1))], new[new_lo + @as(usize, @intCast(y - 1))]))
        {
            x -= 1;
            y -= 1;
            try ops.append(alloc, makeDelta(
                .eq,
                old[old_lo + @as(usize, @intCast(x))],
                @intCast(old_lo + @as(usize, @intCast(x)) + 1),
                @intCast(new_lo + @as(usize, @intCast(y)) + 1),
            ));
        }

        if (d > 0) {
            if (x == prev_x) {
                y -= 1;
                try ops.append(alloc, makeDelta(
                    .ins,
                    new[new_lo + @as(usize, @intCast(y))],
                    0,
                    @intCast(new_lo + @as(usize, @intCast(y)) + 1),
                ));
            } else {
                x -= 1;
                try ops.append(alloc, makeDelta(
                    .del,
                    old[old_lo + @as(usize, @intCast(x))],
                    @intCast(old_lo + @as(usize, @intCast(x)) + 1),
                    0,
                ));
            }
        }
    }

    std.mem.reverse(T, ops.items);
    return ops.toOwnedSlice(alloc);
}

fn patienceDiff(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
) ![]LineDelta {
    return patienceDiffRange(alloc, old, new, 0, old.len, 0, new.len);
}

fn patienceDiffRange(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) ![]LineDelta {
    var alo = old_lo;
    var nlo = new_lo;
    while (alo < old_hi and nlo < new_hi and lineEq(old[alo], new[nlo])) {
        alo += 1;
        nlo += 1;
    }

    var ahi = old_hi;
    var nhi = new_hi;
    while (ahi > alo and nhi > nlo and lineEq(old[ahi - 1], new[nhi - 1])) {
        ahi -= 1;
        nhi -= 1;
    }

    var out: std.ArrayList(LineDelta) = .empty;
    errdefer out.deinit(alloc);

    for (old_lo..alo) |i| {
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_lo + (i - old_lo) + 1)));
    }

    if (alo == ahi and nlo == nhi) {
        // Nothing left after stripping common prefix/suffix
    } else {
        const anchors = try patienceAnchors(alloc, old, new, alo, ahi, nlo, nhi);
        defer alloc.free(anchors);

        if (anchors.len == 0) {
            const sub = try myersDiff(LineDelta, alloc, old, new, alo, ahi, nlo, nhi, lineEq, makeLineDelta);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        } else {
            var prev_oi = alo;
            var prev_ni = nlo;

            for (anchors) |anc| {
                const sub = try patienceDiffRange(alloc, old, new, prev_oi, anc.old_idx, prev_ni, anc.new_idx);
                defer alloc.free(sub);
                try out.appendSlice(alloc, sub);

                try out.append(alloc, makeLineDelta(
                    .eq,
                    old[anc.old_idx],
                    @intCast(anc.old_idx + 1),
                    @intCast(anc.new_idx + 1),
                ));
                prev_oi = anc.old_idx + 1;
                prev_ni = anc.new_idx + 1;
            }

            const sub = try patienceDiffRange(alloc, old, new, prev_oi, ahi, prev_ni, nhi);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        }
    }

    for (ahi..old_hi) |i| {
        const new_i = nhi + (i - ahi);
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_i + 1)));
    }

    return out.toOwnedSlice(alloc);
}

const Anchor = struct { old_idx: usize, new_idx: usize };

fn patienceAnchors(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) ![]Anchor {
    var old_map = std.StringHashMap(u32).init(alloc);
    defer old_map.deinit();
    var new_map = std.StringHashMap(u32).init(alloc);
    defer new_map.deinit();

    const MULTI: u32 = std.math.maxInt(u32);

    for (old_lo..old_hi) |i| {
        const gop = try old_map.getOrPut(old[i]);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(i);
        } else {
            gop.value_ptr.* = MULTI;
        }
    }

    for (new_lo..new_hi) |j| {
        const gop = try new_map.getOrPut(new[j]);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(j);
        } else {
            gop.value_ptr.* = MULTI;
        }
    }

    var pairs: std.ArrayList(Anchor) = .empty;
    defer pairs.deinit(alloc);

    for (new_lo..new_hi) |j| {
        const nv = new_map.get(new[j]) orelse continue;
        if (nv == MULTI) continue;
        const ov = old_map.get(new[j]) orelse continue;
        if (ov == MULTI) continue;
        try pairs.append(alloc, .{ .old_idx = ov, .new_idx = @intCast(j) });
    }

    if (pairs.items.len == 0) return &.{};

    std.sort.insertion(Anchor, pairs.items, {}, struct {
        fn lt(_: void, a: Anchor, b: Anchor) bool {
            return a.old_idx < b.old_idx;
        }
    }.lt);

    var prev = try alloc.alloc(usize, pairs.items.len);
    defer alloc.free(prev);
    var pile_top_src = try alloc.alloc(usize, pairs.items.len);
    defer alloc.free(pile_top_src);
    @memset(prev, std.math.maxInt(usize));
    var pile_count: usize = 0;

    for (pairs.items, 0..) |pair, pi| {
        var lo2: usize = 0;
        var hi2: usize = pile_count;
        while (lo2 < hi2) {
            const mid = lo2 + (hi2 - lo2) / 2;
            if (pairs.items[pile_top_src[mid]].new_idx < pair.new_idx) {
                lo2 = mid + 1;
            } else {
                hi2 = mid;
            }
        }
        if (lo2 > 0) prev[pi] = pile_top_src[lo2 - 1];
        pile_top_src[lo2] = pi;
        if (lo2 == pile_count) pile_count += 1;
    }

    var lis: std.ArrayList(Anchor) = .empty;
    defer lis.deinit(alloc);

    if (pile_count > 0) {
        var idx = pile_top_src[pile_count - 1];
        while (true) {
            try lis.append(alloc, pairs.items[idx]);
            if (prev[idx] == std.math.maxInt(usize)) break;
            idx = prev[idx];
        }
        std.mem.reverse(Anchor, lis.items);
    }

    return lis.toOwnedSlice(alloc);
}

fn histogramDiff(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
) ![]LineDelta {
    return histogramDiffRange(alloc, old, new, 0, old.len, 0, new.len);
}

fn histogramDiffRange(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) ![]LineDelta {
    var alo = old_lo;
    var nlo = new_lo;
    while (alo < old_hi and nlo < new_hi and lineEq(old[alo], new[nlo])) {
        alo += 1;
        nlo += 1;
    }
    var ahi = old_hi;
    var nhi = new_hi;
    while (ahi > alo and nhi > nlo and lineEq(old[ahi - 1], new[nhi - 1])) {
        ahi -= 1;
        nhi -= 1;
    }

    var out: std.ArrayList(LineDelta) = .empty;
    errdefer out.deinit(alloc);

    for (old_lo..alo) |i| {
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_lo + (i - old_lo) + 1)));
    }

    if (alo < ahi or nlo < nhi) {
        const region = try histogramFindRegion(alloc, old, new, alo, ahi, nlo, nhi);

        if (region == null) {
            const sub = try myersDiff(LineDelta, alloc, old, new, alo, ahi, nlo, nhi, lineEq, makeLineDelta);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        } else {
            const reg = region.?;

            const left = try histogramDiffRange(alloc, old, new, alo, reg.old_start, nlo, reg.new_start);
            defer alloc.free(left);
            try out.appendSlice(alloc, left);

            for (0..reg.len) |k| {
                try out.append(alloc, makeLineDelta(
                    .eq,
                    old[reg.old_start + k],
                    @intCast(reg.old_start + k + 1),
                    @intCast(reg.new_start + k + 1),
                ));
            }

            const right = try histogramDiffRange(
                alloc,
                old,
                new,
                reg.old_start + reg.len,
                ahi,
                reg.new_start + reg.len,
                nhi,
            );
            defer alloc.free(right);
            try out.appendSlice(alloc, right);
        }
    }

    for (ahi..old_hi) |i| {
        const new_i = nhi + (i - ahi);
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_i + 1)));
    }

    return out.toOwnedSlice(alloc);
}

const Region = struct {
    old_start: usize,
    new_start: usize,
    len: usize,
};

const HISTOGRAM_MAX_CHAIN: usize = 64;

fn histogramFindRegion(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) !?Region {
    // A line whose chain exceeds HISTOGRAM_MAX_CHAIN is capped: we still
    // count occurrences (so it's correctly deprioritized/skipped below)
    // but we stop recording positions for it, since a line that common
    // is never going to win as an anchor and walking its full position
    // list would reintroduce the O(N·M) blowup this replaces
    var positions = std.StringHashMap(std.ArrayList(usize)).init(alloc);
    defer {
        var it = positions.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        positions.deinit();
    }
    var overflowed = std.StringHashMap(void).init(alloc);
    defer overflowed.deinit();

    for (old_lo..old_hi) |i| {
        if (overflowed.contains(old[i])) continue;
        const gop = try positions.getOrPut(old[i]);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (gop.value_ptr.items.len >= HISTOGRAM_MAX_CHAIN) {
            gop.value_ptr.deinit(alloc);
            _ = positions.remove(old[i]);
            try overflowed.put(old[i], {});
            continue;
        }
        try gop.value_ptr.append(alloc, i);
    }

    var best: ?Region = null;
    var best_freq: usize = std.math.maxInt(usize);
    var best_len: usize = 0;

    for (new_lo..new_hi) |nj| {
        if (overflowed.contains(new[nj])) continue;
        const list = positions.getPtr(new[nj]) orelse continue;
        const freq = list.items.len;
        if (freq > best_freq) continue;

        for (list.items) |oi| {
            var back: usize = 0;
            while (oi >= old_lo + back + 1 and
                nj >= new_lo + back + 1 and
                lineEq(old[oi - back - 1], new[nj - back - 1]))
            {
                back += 1;
            }
            var fwd: usize = 1;
            while (oi + fwd < old_hi and
                nj + fwd < new_hi and
                lineEq(old[oi + fwd], new[nj + fwd]))
            {
                fwd += 1;
            }

            const region_len = back + fwd;
            const region_old_start = oi - back;
            const region_new_start = nj - back;

            const is_better = freq < best_freq or (freq == best_freq and region_len > best_len);
            if (is_better) {
                best_freq = freq;
                best_len = region_len;
                best = Region{
                    .old_start = region_old_start,
                    .new_start = region_new_start,
                    .len = region_len,
                };
            }
        }
    }

    return best;
}

fn diffWords(alloc: std.mem.Allocator, line_deltas: []const LineDelta) ![]WordDelta {
    var out: std.ArrayList(WordDelta) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < line_deltas.len) {
        if (line_deltas[i].op == .eq) {
            i += 1;
            continue;
        }

        var del_words: std.ArrayList([]const u8) = .empty;
        defer del_words.deinit(alloc);
        var ins_words: std.ArrayList([]const u8) = .empty;
        defer ins_words.deinit(alloc);
        var del_lineno: u32 = 0;
        var ins_lineno: u32 = 0;

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

        const lineno = if (ins_lineno != 0) ins_lineno else del_lineno;

        const word_ops = try myersDiff(
            WordDelta,
            alloc,
            del_words.items,
            ins_words.items,
            0,
            del_words.items.len,
            0,
            ins_words.items.len,
            wordEq,
            makeWordDelta,
        );
        defer alloc.free(word_ops);

        for (word_ops) |wd| {
            try out.append(alloc, .{ .op = wd.op, .word = wd.word, .lineno = lineno });
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
        if (it.rest().len == 0 and line.len == 0) break;
        try lines.append(alloc, line);
    }
    return lines.toOwnedSlice(alloc);
}

fn tokenizeWords(alloc: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    errdefer words.deinit(alloc);

    var i: usize = 0;
    while (i < line.len) {
        if (std.ascii.isWhitespace(line[i])) {
            i += 1;
            continue;
        }
        if (std.ascii.isAlphanumeric(line[i]) or line[i] == '_') {
            const start = i;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
            try words.append(alloc, line[start..i]);
        } else {
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
    return .{ .op = op, .content = content, .old_lineno = old_lineno, .new_lineno = new_lineno };
}

fn wordEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn makeWordDelta(op: Op, word: []const u8, _: u32, _: u32) WordDelta {
    return .{ .op = op, .word = word, .lineno = 0 };
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
    inline for (.{ Algorithm.myers, .patience, .histogram }) |algo| {
        var fd = try diffFileWith(alloc, "main.zig", src, src, algo);
        defer fd.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 0), fd.lines_added);
        try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
    }
}

test "diffFile single line added — all algos" {
    const alloc = std.testing.allocator;
    const old = "fn a() void {}\n";
    const new = "fn a() void {}\nfn b() void {}\n";
    inline for (.{ Algorithm.myers, .patience, .histogram }) |algo| {
        var fd = try diffFileWith(alloc, "x.zig", old, new, algo);
        defer fd.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
        try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
    }
}

test "diffFile single line removed — all algos" {
    const alloc = std.testing.allocator;
    const old = "fn a() void {}\nfn b() void {}\n";
    const new = "fn a() void {}\n";
    inline for (.{ Algorithm.myers, .patience, .histogram }) |algo| {
        var fd = try diffFileWith(alloc, "x.zig", old, new, algo);
        defer fd.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 0), fd.lines_added);
        try std.testing.expectEqual(@as(u32, 1), fd.lines_removed);
    }
}

test "patience prefers unique anchors over ambiguous matches" {
    const alloc = std.testing.allocator;
    const old =
        \\void func1() {
        \\    x += 1
        \\}
        \\
        \\void func2() {
        \\    y += 2
        \\}
    ;
    const new =
        \\void func1() {
        \\    x += 1
        \\    x += 2
        \\}
        \\
        \\void func2() {
        \\    y += 2
        \\    y += 3
        \\}
    ;
    var fd_patience = try diffFileWith(alloc, "f.c", old, new, .patience);
    defer fd_patience.deinit(alloc);
    var fd_histogram = try diffFileWith(alloc, "f.c", old, new, .histogram);
    defer fd_histogram.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 2), fd_patience.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd_patience.lines_removed);
    try std.testing.expectEqual(@as(u32, 2), fd_histogram.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd_histogram.lines_removed);
}

test "histogram handles repeated lines gracefully" {
    const alloc = std.testing.allocator;
    const old = "}\n}\n}\n";
    const new = "}\n}\n}\n}\n";
    var fd = try diffFileWith(alloc, "b.c", old, new, .histogram);
    defer fd.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
}

test "histogram stays fast and correct on files dominated by repeated lines" {
    const alloc = std.testing.allocator;

    // Pathological input for the old O(N*M) scan: thousands of identical
    // "}" and blank lines, which used to force a full old-range walk for
    // every single new-range line. With position lists this should stay
    // close to O(N+M) and still find the one real change.
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    const repeat_count = 8000;
    for (0..repeat_count) |i| {
        if (i % 2 == 0) {
            try old_buf.appendSlice(alloc, "}\n");
            try new_buf.appendSlice(alloc, "}\n");
        } else {
            try old_buf.appendSlice(alloc, "\n");
            try new_buf.appendSlice(alloc, "\n");
        }
    }
    // One unique, unambiguous change in the middle of all that noise.
    try old_buf.appendSlice(alloc, "pub fn untouched() void {}\n");
    try new_buf.appendSlice(alloc, "pub fn untouched() void {}\n");
    try old_buf.appendSlice(alloc, "const old_value = 1;\n");
    try new_buf.appendSlice(alloc, "const new_value = 2;\n");
    for (0..repeat_count) |i| {
        if (i % 2 == 0) {
            try old_buf.appendSlice(alloc, "}\n");
            try new_buf.appendSlice(alloc, "}\n");
        } else {
            try old_buf.appendSlice(alloc, "\n");
            try new_buf.appendSlice(alloc, "\n");
        }
    }

    var fd = try diffFileWith(alloc, "noisy.zig", old_buf.items, new_buf.items, .histogram);
    defer fd.deinit(alloc);

    // The only real change is the one line swap; everything else should
    // have been matched away as context despite the massive repeat noise.
    try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_removed);
}

test "histogram chain cap still falls back correctly when a line is maximally common" {
    const alloc = std.testing.allocator;

    // More occurrences of "}" than HISTOGRAM_MAX_CHAIN, with no other
    // repeated lines to anchor on — exercises the overflow/skip path
    // rather than the position-list path.
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    for (0..100) |_| {
        try old_buf.appendSlice(alloc, "}\n");
        try new_buf.appendSlice(alloc, "}\n");
    }
    try old_buf.appendSlice(alloc, "removed_only_line\n");
    try new_buf.appendSlice(alloc, "added_only_line\n");
    for (0..100) |_| {
        try old_buf.appendSlice(alloc, "}\n");
        try new_buf.appendSlice(alloc, "}\n");
    }

    var fd = try diffFileWith(alloc, "cap.zig", old_buf.items, new_buf.items, .histogram);
    defer fd.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_removed);
}

test "all algos agree on net line delta" {
    const alloc = std.testing.allocator;
    const old =
        \\pub fn foo(x: u32) u32 {
        \\    return x + 1;
        \\}
        \\
        \\pub fn bar(y: u32) u32 {
        \\    return y * 2;
        \\}
    ;
    const new =
        \\pub fn foo(x: u32) u32 {
        \\    const z = x + 1;
        \\    return z;
        \\}
        \\
        \\pub fn bar(y: u32) u32 {
        \\    return y * 2;
        \\}
        \\
        \\pub fn baz(z: u32) u32 {
        \\    return z - 1;
        \\}
    ;
    var fd_m = try diffFileWith(alloc, "f.zig", old, new, .myers);
    defer fd_m.deinit(alloc);
    var fd_p = try diffFileWith(alloc, "f.zig", old, new, .patience);
    defer fd_p.deinit(alloc);
    var fd_h = try diffFileWith(alloc, "f.zig", old, new, .histogram);
    defer fd_h.deinit(alloc);

    // Net added-removed must equal new.len - old.len for ANY correct edit
    // script, regardless of algorithm — this is an algorithm-independent
    // invariant, not a property specific to one diff strategy
    const net_m: i32 = @as(i32, @intCast(fd_m.lines_added)) - @as(i32, @intCast(fd_m.lines_removed));
    const net_p: i32 = @as(i32, @intCast(fd_p.lines_added)) - @as(i32, @intCast(fd_p.lines_removed));
    const net_h: i32 = @as(i32, @intCast(fd_h.lines_added)) - @as(i32, @intCast(fd_h.lines_removed));
    try std.testing.expectEqual(@as(i32, 5), net_m);
    try std.testing.expectEqual(@as(i32, 5), net_p);
    try std.testing.expectEqual(@as(i32, 5), net_h);
}

test "tokenizeWords splits identifiers and punctuation" {
    const alloc = std.testing.allocator;
    const words = try tokenizeWords(alloc, "fn foo(x: u32)");
    defer alloc.free(words);
    try std.testing.expectEqual(@as(usize, 7), words.len);
    try std.testing.expectEqualStrings("fn", words[0]);
    try std.testing.expectEqualStrings("foo", words[1]);
    try std.testing.expectEqualStrings("(", words[2]);
}

test "summarize aggregates across files" {
    const alloc = std.testing.allocator;
    const old_files = [_]FileSnapshot{
        .{ .path = "a.txt", .content = "hello\nworld\n" },
        .{ .path = "b.txt", .content = "foo\n" },
    };
    const new_files = [_]FileSnapshot{
        .{ .path = "a.txt", .content = "hello\nearth\n" },
        .{ .path = "b.txt", .content = "foo\nbar\n" },
    };

    var cd = try diffCommit(alloc, &old_files, &new_files);
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

// ---------------------------------------------------------------------------
// Merkle-root/commit diffing tests
// ---------------------------------------------------------------------------

const io = merk.io;
const object_test_mod = object_mod;

const FileSeed = struct { path: []const u8, content: []const u8 };

fn buildRoot(
    alloc: std.mem.Allocator,
    page_store: *const merkle_mod.PageStore,
    store: *const object_mod.Store,
    seeds: []const FileSeed,
) !Hash {
    var entries: std.ArrayList(merkle_mod.Entry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(alloc);
        entries.deinit(alloc);
    }
    for (seeds) |seed| {
        const blob_hash = try store.put(.blob, seed.content);
        try entries.append(alloc, .{
            .path = try alloc.dupe(u8, seed.path),
            .blob_hash = blob_hash,
            .size = seed.content.len,
            .mode = 0o100644,
            .mtime = 1,
        });
    }
    return merkle_mod.build(alloc, page_store, entries.items);
}

fn findFileDiff(cd: *const CommitDiff, path: []const u8) ?*const FileDiff {
    for (cd.files) |*fd| {
        if (std.mem.eql(u8, fd.path, path)) return fd;
    }
    return null;
}

test "diffSnapshotRoots reports modified, added, and removed files via merkle pruning" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = object_test_mod.Store.init(alloc, tfs.fs(), "objects");
    const page_store = merkle_mod.PageStore.init(alloc, tfs.fs(), "index/pages");

    const old_root = try buildRoot(alloc, &page_store, &store, &.{
        .{ .path = "a.txt", .content = "hello\nworld\n" },
        .{ .path = "b.txt", .content = "keep me\n" },
        .{ .path = "gone.txt", .content = "bye\n" },
    });
    const new_root = try buildRoot(alloc, &page_store, &store, &.{
        .{ .path = "a.txt", .content = "hello\nearth\n" },
        .{ .path = "b.txt", .content = "keep me\n" },
        .{ .path = "new.txt", .content = "fresh\n" },
    });

    var cd = try diffSnapshotRoots(alloc, &store, &page_store, old_root, new_root, .histogram);
    defer cd.deinit(alloc);

    // b.txt is unchanged and never shows up at all — diffRoots pruned it
    // without either side even being read.
    try std.testing.expectEqual(@as(usize, 3), cd.files.len);

    const a = findFileDiff(&cd, "a.txt") orelse return error.MissingFile;
    try std.testing.expectEqual(@as(u32, 1), a.lines_added);
    try std.testing.expectEqual(@as(u32, 1), a.lines_removed);

    const gone = findFileDiff(&cd, "gone.txt") orelse return error.MissingFile;
    try std.testing.expectEqual(@as(u32, 0), gone.lines_added);
    try std.testing.expectEqual(@as(u32, 1), gone.lines_removed);

    const new_file = findFileDiff(&cd, "new.txt") orelse return error.MissingFile;
    try std.testing.expectEqual(@as(u32, 1), new_file.lines_added);
    try std.testing.expectEqual(@as(u32, 0), new_file.lines_removed);
}

test "diffSnapshotRoots against a null old_root reports every entry as added" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = object_test_mod.Store.init(alloc, tfs.fs(), "objects");
    const page_store = merkle_mod.PageStore.init(alloc, tfs.fs(), "index/pages");

    const new_root = try buildRoot(alloc, &page_store, &store, &.{
        .{ .path = "a.txt", .content = "one\n" },
        .{ .path = "b.txt", .content = "two\n" },
    });

    var cd = try diffSnapshotRoots(alloc, &store, &page_store, null, new_root, .histogram);
    defer cd.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), cd.files.len);
    for (cd.files) |fd| {
        try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
        try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
    }
}

test "diffCommits resolves commit hashes to snapshot roots before diffing" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = object_test_mod.Store.init(alloc, tfs.fs(), "objects");
    const page_store = merkle_mod.PageStore.init(alloc, tfs.fs(), "index/pages");

    const root1 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "v1\n" }});
    var b1 = commit_mod.CommitBuilder.init(alloc, root1);
    defer b1.deinit();
    _ = b1.author("Dev", "dev@nodus.dev", 1);
    _ = b1.intent(.feature);
    _ = b1.title("first");
    const c1 = try b1.write(&store);

    const root2 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "v2\n" }});
    var b2 = commit_mod.CommitBuilder.init(alloc, root2);
    defer b2.deinit();
    _ = try b2.parent(c1);
    _ = b2.author("Dev", "dev@nodus.dev", 2);
    _ = b2.intent(.feature);
    _ = b2.title("second");
    const c2 = try b2.write(&store);

    var cd = try diffCommits(alloc, &store, &page_store, c1, c2, .histogram);
    defer cd.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), cd.files.len);
    try std.testing.expectEqualStrings("a.txt", cd.files[0].path);
    try std.testing.expectEqual(@as(u32, 1), cd.files[0].lines_added);
    try std.testing.expectEqual(@as(u32, 1), cd.files[0].lines_removed);
}

test "diffCommitAgainstParent treats a root commit as a diff against the empty tree" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = object_test_mod.Store.init(alloc, tfs.fs(), "objects");
    const page_store = merkle_mod.PageStore.init(alloc, tfs.fs(), "index/pages");

    const root1 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "hello\n" }});
    var b1 = commit_mod.CommitBuilder.init(alloc, root1);
    defer b1.deinit();
    _ = b1.author("Dev", "dev@nodus.dev", 1);
    _ = b1.intent(.feature);
    _ = b1.title("root");
    const c1 = try b1.write(&store);

    var cd = try diffCommitAgainstParent(alloc, &store, &page_store, c1, .histogram);
    defer cd.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), cd.files.len);
    try std.testing.expectEqualStrings("a.txt", cd.files[0].path);
    try std.testing.expectEqual(@as(u32, 1), cd.files[0].lines_added);
    try std.testing.expectEqual(@as(u32, 0), cd.files[0].lines_removed);
}

test "diffCommitAgainstParent uses the first (mainline) parent's snapshot" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = object_test_mod.Store.init(alloc, tfs.fs(), "objects");
    const page_store = merkle_mod.PageStore.init(alloc, tfs.fs(), "index/pages");

    const root1 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "v1\n" }});
    var b1 = commit_mod.CommitBuilder.init(alloc, root1);
    defer b1.deinit();
    _ = b1.author("Dev", "dev@nodus.dev", 1);
    _ = b1.intent(.feature);
    _ = b1.title("first");
    const c1 = try b1.write(&store);

    const root2 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "v2\n" }});
    var b2 = commit_mod.CommitBuilder.init(alloc, root2);
    defer b2.deinit();
    _ = try b2.parent(c1);
    _ = b2.author("Dev", "dev@nodus.dev", 2);
    _ = b2.intent(.feature);
    _ = b2.title("second");
    const c2 = try b2.write(&store);

    var cd = try diffCommitAgainstParent(alloc, &store, &page_store, c2, .histogram);
    defer cd.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), cd.files.len);
    try std.testing.expectEqualStrings("a.txt", cd.files[0].path);
    try std.testing.expectEqual(@as(u32, 1), cd.files[0].lines_added);
    try std.testing.expectEqual(@as(u32, 1), cd.files[0].lines_removed);
}

test {
    std.testing.refAllDecls(@This());
}
