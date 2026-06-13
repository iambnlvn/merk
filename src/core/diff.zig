//  Nodus diff engine + CLI surface
//
//  Two passes on every changed file:
//    * Line-level unified diff  (for display, `nodus show`)
//    * Word-level diff          (for precision, intent classifier)
//
//  Neither pass requires the AST to work — they operate on raw source bytes.
//  The AST delta layer lives in an intent layer and consumes these results.
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

const std = @import("std");

pub const Op = enum(u8) {
    eq = 0,
    ins = 1,
    del = 2,
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

    pub fn deinit(self: *CommitDiff, alloc: std.mem.Allocator) void {
        for (self.files) |*f| f.deinit(alloc);
        alloc.free(self.files);
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

pub fn parseAlgorithm(s: []const u8) ?Algorithm {
    const map = std.StaticStringMap(Algorithm).initComptime(.{
        .{ "myers", .myers },
        .{ "patience", .patience },
        .{ "histogram", .histogram },
    });
    return map.get(s);
}

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

pub const ColorMode = enum {
    auto,
    always,
    never,
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

pub fn parseColorMode(raw: []const u8) ?ColorMode {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "always")) return .always;
    if (std.mem.eql(u8, raw, "never")) return .never;
    return null;
}

pub const Profile = enum { review, ci, debug };

pub const ProfileOpts = struct {
    pub fn apply(p: Profile, config: *RenderConfig) void {
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
};

pub const RenderConfig = struct {
    format: Format = .unified,
    level: Level = .line,
    context: Context = .normal,
    group_by: GroupBy = .none,
    filter: ChangeFilter = .{},
    word_mode: bool = false,
    detect_moves: bool = false,
    color: ColorMode = .auto,
    max_width: u32 = 60,
    /// Which diff algorithm to use for line-level diffing
    algorithm: Algorithm = .histogram,

    pub fn contextLines(self: RenderConfig) u32 {
        return self.context.lines();
    }
};

pub const DiffArgs = struct {
    refs: [2]?[]const u8 = .{ null, null },
    paths: std.ArrayList([]const u8),
    staged: bool = false,
    working: bool = false,
    config: RenderConfig = .{},

    pub fn parse(alloc: std.mem.Allocator, args: []const []const u8) !DiffArgs {
        var da = DiffArgs{ .paths = .empty };
        errdefer da.paths.deinit(alloc);

        var i: usize = 2; // skip argv[0] and subcommand "diff"
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.format = parseFormat(args[i]) orelse return error.InvalidFormat;
            } else if (std.mem.eql(u8, arg, "--level")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.level = parseLevel(args[i]) orelse return error.InvalidLevel;
            } else if (std.mem.eql(u8, arg, "--context")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.context = parseContext(args[i]) orelse return error.InvalidContext;
            } else if (std.mem.eql(u8, arg, "--group")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.group_by = parseGroupBy(args[i]) orelse return error.InvalidGroup;
            } else if (std.mem.eql(u8, arg, "--show")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.filter = try ChangeFilter.parse(args[i]);
            } else if (std.mem.eql(u8, arg, "--only-added")) {
                da.config.filter = .{ .show_added = true, .show_deleted = false, .show_modified = false };
            } else if (std.mem.eql(u8, arg, "--only-deleted")) {
                da.config.filter = .{ .show_added = false, .show_deleted = true, .show_modified = false };
            } else if (std.mem.eql(u8, arg, "--only-modified")) {
                da.config.filter = .{ .show_added = false, .show_deleted = false, .show_modified = true };
            } else if (std.mem.eql(u8, arg, "--word")) {
                da.config.word_mode = true;
            } else if (std.mem.eql(u8, arg, "--detect-moves")) {
                da.config.detect_moves = true;
            } else if (std.mem.eql(u8, arg, "--no-color")) {
                da.config.color = .never;
            } else if (std.mem.eql(u8, arg, "--color")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.color = parseColorMode(args[i]) orelse return error.InvalidColorMode;
            } else if (std.mem.eql(u8, arg, "--algo")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.algorithm = parseAlgorithm(args[i]) orelse return error.InvalidAlgorithm;
            } else if (std.mem.eql(u8, arg, "--profile")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                const p = std.meta.stringToEnum(Profile, args[i]) orelse return error.InvalidProfile;
                ProfileOpts.apply(p, &da.config);
            } else if (std.mem.eql(u8, arg, "--staged")) {
                da.staged = true;
            } else if (std.mem.eql(u8, arg, "--working")) {
                da.working = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return error.UnknownFlag;
            } else {
                // Positional: ref or path
                if (da.refs[0] == null) {
                    da.refs[0] = arg;
                } else if (da.refs[1] == null) {
                    da.refs[1] = arg;
                } else {
                    try da.paths.append(alloc, arg);
                }
            }
        }
        return da;
    }

    pub fn deinit(self: *DiffArgs, alloc: std.mem.Allocator) void {
        self.paths.deinit(alloc);
    }
};

pub fn parseFormat(s: []const u8) ?Format {
    const map = std.StaticStringMap(Format).initComptime(.{
        .{ "unified", .unified },
        .{ "side-by-side", .side_by_side },
        .{ "blocks", .blocks },
        .{ "ops", .ops },
        .{ "summary", .summary },
    });
    return map.get(s);
}

pub fn parseLevel(s: []const u8) ?Level {
    const map = std.StaticStringMap(Level).initComptime(.{
        .{ "file", .file },
        .{ "hunk", .hunk },
        .{ "line", .line },
        .{ "word", .word },
    });
    return map.get(s);
}

pub fn parseContext(s: []const u8) ?Context {
    if (std.mem.eql(u8, s, "minimal")) return .minimal;
    if (std.mem.eql(u8, s, "normal")) return .normal;
    if (std.mem.eql(u8, s, "full")) return .full;
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    return .{ .exact = n };
}

pub fn parseGroupBy(s: []const u8) ?GroupBy {
    const map = std.StaticStringMap(GroupBy).initComptime(.{
        .{ "none", .none },
        .{ "files", .files },
        .{ "dirs", .dirs },
    });
    return map.get(s);
}

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
    // Strip matching prefix
    var alo = old_lo;
    var nlo = new_lo;
    while (alo < old_hi and nlo < new_hi and lineEq(old[alo], new[nlo])) {
        alo += 1;
        nlo += 1;
    }

    // Strip matching suffix
    var ahi = old_hi;
    var nhi = new_hi;
    while (ahi > alo and nhi > nlo and lineEq(old[ahi - 1], new[nhi - 1])) {
        ahi -= 1;
        nhi -= 1;
    }

    var out: std.ArrayList(LineDelta) = .empty;
    errdefer out.deinit(alloc);

    // Emit prefix equalities
    for (old_lo..alo) |i| {
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_lo + (i - old_lo) + 1)));
    }

    if (alo == ahi and nlo == nhi) {
        // Nothing left after stripping common prefix/suffix
    } else {
        // Find unique-line anchors inside the trimmed region
        const anchors = try patienceAnchors(alloc, old, new, alo, ahi, nlo, nhi);
        defer alloc.free(anchors);

        if (anchors.len == 0) {
            // No unique anchors — fall back to Myers for this segment
            const sub = try myersDiff(LineDelta, alloc, old, new, alo, ahi, nlo, nhi, lineEq, makeLineDelta);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        } else {
            var prev_oi = alo;
            var prev_ni = nlo;

            for (anchors) |anc| {
                // Recurse into the gap before this anchor
                const sub = try patienceDiffRange(alloc, old, new, prev_oi, anc.old_idx, prev_ni, anc.new_idx);
                defer alloc.free(sub);
                try out.appendSlice(alloc, sub);

                // Emit the anchor itself as an equality
                try out.append(alloc, makeLineDelta(
                    .eq,
                    old[anc.old_idx],
                    @intCast(anc.old_idx + 1),
                    @intCast(anc.new_idx + 1),
                ));
                prev_oi = anc.old_idx + 1;
                prev_ni = anc.new_idx + 1;
            }

            // Recurse into the tail after the last anchor
            const sub = try patienceDiffRange(alloc, old, new, prev_oi, ahi, prev_ni, nhi);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        }
    }

    // Emit suffix equalities
    for (ahi..old_hi) |i| {
        const new_i = nhi + (i - ahi);
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_i + 1)));
    }

    return out.toOwnedSlice(alloc);
}

/// An (old_idx, new_idx) pair representing a matched unique line
const Anchor = struct { old_idx: usize, new_idx: usize };

/// Compute the LCS of unique lines in [old_lo,old_hi) × [new_lo,new_hi)
/// using the patience sorting algo
fn patienceAnchors(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) ![]Anchor {
    // Build occurrence maps: line -> list of indices in old/new
    var old_map = std.StringHashMap(u32).init(alloc); // line → old index; maxInt = non-unique
    defer old_map.deinit();
    var new_map = std.StringHashMap(u32).init(alloc);
    defer new_map.deinit();

    const MULTI: u32 = std.math.maxInt(u32);

    for (old_lo..old_hi) |i| {
        const gop = try old_map.getOrPut(old[i]);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(i);
        } else {
            gop.value_ptr.* = MULTI; // seen more than once
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

    // Collect matching unique pairs in new-file order
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

    // Sort by old_idx to enable the patience LCS
    std.sort.insertion(Anchor, pairs.items, {}, struct {
        fn lt(_: void, a: Anchor, b: Anchor) bool {
            return a.old_idx < b.old_idx;
        }
    }.lt);

    // find longest increasing subsequence (LIS) on new_idx
    // Each pile's top is the smallest new_idx for a run of that length
    var piles: std.ArrayList(Anchor) = .empty;
    defer piles.deinit(alloc);
    // prev[i] = index into `pairs` of the predecessor of pairs[i] in the LIS
    var prev = try alloc.alloc(usize, pairs.items.len);
    defer alloc.free(prev);
    var pile_top_src = try alloc.alloc(usize, pairs.items.len); // pair index at each pile top
    defer alloc.free(pile_top_src);
    @memset(prev, std.math.maxInt(usize));
    var pile_count: usize = 0;

    for (pairs.items, 0..) |pair, pi| {
        // Binary search for leftmost pile whose top has new_idx >= pair.new_idx
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

    // Backtrack to recover the LIS
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
    // Strip common prefix
    var alo = old_lo;
    var nlo = new_lo;
    while (alo < old_hi and nlo < new_hi and lineEq(old[alo], new[nlo])) {
        alo += 1;
        nlo += 1;
    }
    // Strip common suffix
    var ahi = old_hi;
    var nhi = new_hi;
    while (ahi > alo and nhi > nlo and lineEq(old[ahi - 1], new[nhi - 1])) {
        ahi -= 1;
        nhi -= 1;
    }

    var out: std.ArrayList(LineDelta) = .empty;
    errdefer out.deinit(alloc);

    // Emit prefix equalities
    for (old_lo..alo) |i| {
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_lo + (i - old_lo) + 1)));
    }

    if (alo < ahi or nlo < nhi) {
        const region = try histogramFindRegion(alloc, old, new, alo, ahi, nlo, nhi);

        if (region == null) {
            // No anchor found — fall back to Myers
            const sub = try myersDiff(LineDelta, alloc, old, new, alo, ahi, nlo, nhi, lineEq, makeLineDelta);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        } else {
            const reg = region.?;

            // Recurse on the part before the anchor region
            const left = try histogramDiffRange(alloc, old, new, alo, reg.old_start, nlo, reg.new_start);
            defer alloc.free(left);
            try out.appendSlice(alloc, left);

            // Emit the anchor region as equalities
            for (0..reg.len) |k| {
                try out.append(alloc, makeLineDelta(
                    .eq,
                    old[reg.old_start + k],
                    @intCast(reg.old_start + k + 1),
                    @intCast(reg.new_start + k + 1),
                ));
            }

            // Recurse on the part after the anchor region
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

    // Emit suffix equalities
    for (ahi..old_hi) |i| {
        const new_i = nhi + (i - ahi);
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_i + 1)));
    }

    return out.toOwnedSlice(alloc);
}

/// An equal region (snake) used as an anchor by histogram diff
const Region = struct {
    old_start: usize,
    new_start: usize,
    len: usize,
};

/// Find the best anchor region in old[old_lo..old_hi] × new[new_lo..new_hi]
///
/// "Best" = the equal-line region whose anchor line has the lowest frequency
/// in old, breaking ties by preferring longer regions
fn histogramFindRegion(
    alloc: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) !?Region {
    // Build frequency table for lines in old[lo..hi]
    // freq_map: line content -> count in old segment
    var freq_map = std.StringHashMap(u32).init(alloc);
    defer freq_map.deinit();

    for (old_lo..old_hi) |i| {
        const gop = try freq_map.getOrPut(old[i]);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    // For each line in new, if it also appears in old, record a candidate
    // (old_occurrence, new_occurrence) pair and its frequency score
    // We want the pair with the lowest frequency (rarest line)
    var best: ?Region = null;
    var best_freq: u32 = std.math.maxInt(u32);
    var best_len: usize = 0;

    for (new_lo..new_hi) |nj| {
        const freq = freq_map.get(new[nj]) orelse continue;
        // Only consider if this line is at least as rare as the current best
        if (freq > best_freq) continue;

        // Find every occurrence of new[nj] in old[old_lo..old_hi]
        for (old_lo..old_hi) |oi| {
            if (!lineEq(old[oi], new[nj])) continue;

            // Extend the snake backward from (oi, nj)
            var back: usize = 0;
            while (oi >= old_lo + back + 1 and
                nj >= new_lo + back + 1 and
                lineEq(old[oi - back - 1], new[nj - back - 1]))
            {
                back += 1;
            }
            // Extend forward
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

        // Word diff always uses Myers; the inputs are already small
        // Patience/histogram on single-line word tokens rarely helps and adds cost
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

pub fn renderCommit(writer: anytype, cd: *const CommitDiff, config: RenderConfig, alloc: std.mem.Allocator) !void {
    var filtered = std.ArrayList(*const FileDiff).init(alloc);
    defer filtered.deinit(alloc);

    for (cd.files) |*fd| {
        const status = fileStatus(fd);
        if (!config.filter.allows(status)) continue;
        try filtered.append(fd);
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
    // This is the canonical patience diff example.
    // Myers would match `}` lines greedily; patience anchors on the unique
    // function signatures and produces a cleaner diff.
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

    // Both algorithms should find exactly 2 added lines.
    try std.testing.expectEqual(@as(u32, 2), fd_patience.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd_patience.lines_removed);
    try std.testing.expectEqual(@as(u32, 2), fd_histogram.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd_histogram.lines_removed);
}

test "histogram handles repeated lines gracefully" {
    // When lines repeat (e.g. closing braces), histogram falls back to rarest
    // lines and still produces a valid diff.
    const alloc = std.testing.allocator;
    const old = "}\n}\n}\n";
    const new = "}\n}\n}\n}\n";
    var fd = try diffFileWith(alloc, "b.c", old, new, .histogram);
    defer fd.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 0), fd.lines_removed);
}

test "all algos agree on line counts" {
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

    // All three should produce net +4 lines (added - removed may differ in how
    // they attribute the rewrite of `return x + 1`, but totals must be sane)
    const net_m: i32 = @as(i32, @intCast(fd_m.lines_added)) - @as(i32, @intCast(fd_m.lines_removed));
    const net_p: i32 = @as(i32, @intCast(fd_p.lines_added)) - @as(i32, @intCast(fd_p.lines_removed));
    const net_h: i32 = @as(i32, @intCast(fd_h.lines_added)) - @as(i32, @intCast(fd_h.lines_removed));
    try std.testing.expectEqual(net_m, net_p);
    try std.testing.expectEqual(net_m, net_h);
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

test "DiffArgs parse format and level" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "nodus", "diff", "--format", "side-by-side", "--level", "word" };
    var da = try DiffArgs.parse(alloc, &args);
    defer da.deinit(alloc);
    try std.testing.expectEqual(Format.side_by_side, da.config.format);
    try std.testing.expectEqual(Level.word, da.config.level);
}

test "DiffArgs parse --algo flag" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "nodus", "diff", "--algo", "patience" };
    var da = try DiffArgs.parse(alloc, &args);
    defer da.deinit(alloc);
    try std.testing.expectEqual(Algorithm.patience, da.config.algorithm);
}

test "DiffArgs parse profile review" {
    const alloc = std.testing.allocator;
    const args = [_][:0]const u8{
        @as([:0]const u8, "nodus"),
        @as([:0]const u8, "diff"),
        @as([:0]const u8, "--profile"),
        @as([:0]const u8, "review"),
    };
    var da = try DiffArgs.parse(alloc, &args);
    defer da.deinit(alloc);
    try std.testing.expectEqual(Format.side_by_side, da.config.format);
    try std.testing.expectEqual(Level.line, da.config.level);
    try std.testing.expectEqual(GroupBy.files, da.config.group_by);
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
