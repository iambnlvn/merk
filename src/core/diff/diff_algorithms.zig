//  Storage-agnostic content-diff engine (Myers/Patience/Histogram,
//  FileDiff/WordDelta, CommitDiff). Operates on raw source bytes only —
//  no dependency on how snapshots are stored on disk. See diff_snapshot.zig
//  for the merkle-tree adapter that turns stored commits into the
//  FileSnapshot pairs this engine consumes, and diff_render.zig for the
//  output formatters that consume this engine's FileDiff/CommitDiff output.
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
//              lines are preferred as anchors even when not strictly unique.
//              Degrades to Myers when the histogram finds nothing useful.
//

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
    /// Backing blob buffers that FileDiff.line_deltas[].content slices
    /// point into. Owned by the CommitDiff for its whole lifetime —
    /// freeing these before deinit() dangles every content slice.
    /// Populated by diff_snapshot.zig's diffSnapshotRoots; empty for
    /// diffCommit/diffCommitWith, which diff already-in-memory content
    /// the caller owns.
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
/// diff_snapshot.zig's diffSnapshotRoots/diffCommits, which only fetch the
/// blobs that actually changed instead of every file on both sides.
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

    // Snapshot for round d is taken BEFORE round d writes to v, i.e. it
    // captures the frontier as of round d-1. Backtracking from round d
    // reads prev_k = k ± 1 where |k| <= d, so |prev_k| can reach d+1 —
    // one slot past a [-d, d] window. Window each snapshot as
    // [-(d+1), d+1] instead: the extra boundary entries at ±(d+1) are
    // provably always 0 (round d only ever writes entries with |k| <= d,
    // so nothing before round d touched k = ±(d+1)) — this is Myers' own
    // v[1]=0 bootstrap convention, made explicit here instead of relying
    // on v's oversized allocation to supply it implicitly. Total trace
    // memory is still O(D²), just +2 slots per step, not O(D·(N+M)).
    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |snap| alloc.free(snap);
        trace.deinit(alloc);
    }

    const offset: isize = @intCast(max_d);

    outer: for (0..max_d + 1) |d_usize| {
        const d: isize = @intCast(d_usize);

        const snap_len = 2 * d_usize + 3;
        const local_offset = d + 1;
        const snap = try alloc.alloc(isize, snap_len);
        errdefer alloc.free(snap);
        for (0..snap_len) |i| {
            const k_local: isize = @as(isize, @intCast(i)) - local_offset;
            const vi = k_local + offset;
            snap[i] = if (vi >= 0 and vi < @as(isize, @intCast(v_len)))
                v[@intCast(vi)]
            else
                0;
        }
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
        // This snapshot's local offset is d+1 (size 2d+3, indices
        // k ∈ [-(d+1), d+1] map to snap[k + d + 1]) — NOT the global
        // `offset` used to index the live v array above.
        const local_offset = d + 1;
        const k = x - y;
        const ki: usize = @intCast(k + local_offset);

        const prev_k: isize = if (k == -d or (k != d and snap[ki - 1] < snap[ki + 1]))
            k + 1
        else
            k - 1;

        const prev_x = snap[@intCast(prev_k + local_offset)];
        const prev_y = prev_x - prev_k;

        // Walk back the snake: any number of matching steps, bounded by
        // actual line equality AND the prev_x/prev_y target.
        // A single d-step's snake can be longer than one line, and the
        // gap to prev_x/prev_y is not guaranteed to be diagonal once the
        // snake is peeled off, so we check content here rather than
        // assuming geometry
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

/// Bounds shared between Patience and Histogram after stripping the
/// common leading/trailing run — extracted because both algorithms
/// need this exact strip before doing their own anchor search.
const StrippedEnds = struct {
    alo: usize,
    ahi: usize,
    nlo: usize,
    nhi: usize,
};

fn stripCommonEnds(
    old: []const []const u8,
    new: []const []const u8,
    old_lo: usize,
    old_hi: usize,
    new_lo: usize,
    new_hi: usize,
) StrippedEnds {
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
    return .{ .alo = alo, .ahi = ahi, .nlo = nlo, .nhi = nhi };
}

/// Emit `.eq` deltas for old[old_start..old_end], paired against the
/// parallel new-side range starting at new_start. Shared by both
/// Patience's and Histogram's prefix/suffix emission — previously four
/// near-identical copies of this loop across the two functions.
fn appendEqRun(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(LineDelta),
    old: []const []const u8,
    old_start: usize,
    old_end: usize,
    new_start: usize,
) !void {
    for (old_start..old_end) |i| {
        const new_i = new_start + (i - old_start);
        try out.append(alloc, makeLineDelta(.eq, old[i], @intCast(i + 1), @intCast(new_i + 1)));
    }
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
    const ends = stripCommonEnds(old, new, old_lo, old_hi, new_lo, new_hi);

    var out: std.ArrayList(LineDelta) = .empty;
    errdefer out.deinit(alloc);

    try appendEqRun(alloc, &out, old, old_lo, ends.alo, new_lo);

    if (ends.alo == ends.ahi and ends.nlo == ends.nhi) {
        // Nothing left after stripping common prefix/suffix
    } else {
        const anchors = try patienceAnchors(alloc, old, new, ends.alo, ends.ahi, ends.nlo, ends.nhi);
        defer alloc.free(anchors);

        if (anchors.len == 0) {
            const sub = try myersDiff(LineDelta, alloc, old, new, ends.alo, ends.ahi, ends.nlo, ends.nhi, lineEq, makeLineDelta);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        } else {
            var prev_oi = ends.alo;
            var prev_ni = ends.nlo;

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

            const sub = try patienceDiffRange(alloc, old, new, prev_oi, ends.ahi, prev_ni, ends.nhi);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        }
    }

    try appendEqRun(alloc, &out, old, ends.ahi, old_hi, ends.nhi);

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
    const ends = stripCommonEnds(old, new, old_lo, old_hi, new_lo, new_hi);

    var out: std.ArrayList(LineDelta) = .empty;
    errdefer out.deinit(alloc);

    try appendEqRun(alloc, &out, old, old_lo, ends.alo, new_lo);

    if (ends.alo < ends.ahi or ends.nlo < ends.nhi) {
        const region = try histogramFindRegion(alloc, old, new, ends.alo, ends.ahi, ends.nlo, ends.nhi);

        if (region == null) {
            const sub = try myersDiff(LineDelta, alloc, old, new, ends.alo, ends.ahi, ends.nlo, ends.nhi, lineEq, makeLineDelta);
            defer alloc.free(sub);
            try out.appendSlice(alloc, sub);
        } else {
            const reg = region.?;

            const left = try histogramDiffRange(alloc, old, new, ends.alo, reg.old_start, ends.nlo, reg.new_start);
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
                ends.ahi,
                reg.new_start + reg.len,
                ends.nhi,
            );
            defer alloc.free(right);
            try out.appendSlice(alloc, right);
        }
    }

    try appendEqRun(alloc, &out, old, ends.ahi, old_hi, ends.nhi);

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
    // line content -> positions within the old range, built once (O(N)).
    // A line whose chain exceeds HISTOGRAM_MAX_CHAIN is capped: we stop
    // recording positions for it (it's never going to win as an anchor
    // anyway, and walking its full position list would reintroduce the
    // O(N·M) blowup this replaces) and remember it in `overflowed` so
    // it's skipped outright on the new-side scan too.
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
                try tokenizeWordsInto(&del_words, alloc, ld.content);
            } else {
                if (ins_lineno == 0) ins_lineno = ld.new_lineno;
                try tokenizeWordsInto(&ins_words, alloc, ld.content);
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

/// Tokenizes `line` directly into `out`, appending each word slice.
/// Previously `diffWords` called a standalone `tokenizeWords` that
/// allocated its own temporary slice per line, appended it into
/// del_words/ins_words, then freed the temporary — an alloc+copy+free
/// per line where writing straight into the caller's growable list does.
fn tokenizeWordsInto(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (std.ascii.isWhitespace(line[i])) {
            i += 1;
            continue;
        }
        if (std.ascii.isAlphanumeric(line[i]) or line[i] == '_') {
            const start = i;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
            try out.append(alloc, line[start..i]);
        } else {
            try out.append(alloc, line[i .. i + 1]);
            i += 1;
        }
    }
}

/// Standalone tokenizer kept for direct callers/tests that just want a
/// word list back rather than appending into an existing ArrayList.
fn tokenizeWords(alloc: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    errdefer words.deinit(alloc);
    try tokenizeWordsInto(&words, alloc, line);
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

    try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_removed);
}

test "histogram chain cap still falls back correctly when a line is maximally common" {
    const alloc = std.testing.allocator;

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

    const net_m: i32 = @as(i32, @intCast(fd_m.lines_added)) - @as(i32, @intCast(fd_m.lines_removed));
    const net_p: i32 = @as(i32, @intCast(fd_p.lines_added)) - @as(i32, @intCast(fd_p.lines_removed));
    const net_h: i32 = @as(i32, @intCast(fd_h.lines_added)) - @as(i32, @intCast(fd_h.lines_removed));
    try std.testing.expectEqual(@as(i32, 5), net_m);
    try std.testing.expectEqual(@as(i32, 5), net_p);
    try std.testing.expectEqual(@as(i32, 5), net_h);
}

test "myers backtrack bootstrap: single-line total replacement (forces d=0 boundary read)" {
    const alloc = std.testing.allocator;
    var fd = try diffFileWith(alloc, "one.txt", "old line\n", "new line\n", .myers);
    defer fd.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_removed);
}

test "myers backtrack bootstrap: pure insertion and pure deletion at d=1" {
    const alloc = std.testing.allocator;
    inline for (.{
        .{ .old = "a\n", .new = "a\nb\n", .added = 1, .removed = 0 },
        .{ .old = "a\nb\n", .new = "a\n", .added = 0, .removed = 1 },
    }) |case| {
        var fd = try diffFileWith(alloc, "x.txt", case.old, case.new, .myers);
        defer fd.deinit(alloc);
        try std.testing.expectEqual(@as(u32, case.added), fd.lines_added);
        try std.testing.expectEqual(@as(u32, case.removed), fd.lines_removed);
    }
}

test "myers windowed trace stays correct on large file with small edit distance" {
    const alloc = std.testing.allocator;
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    for (0..3000) |i| {
        try old_buf.writer(alloc).print("line {d}\n", .{i});
        try new_buf.writer(alloc).print("line {d}\n", .{i});
    }
    try old_buf.appendSlice(alloc, "const old_only_a = 1;\n");
    try old_buf.appendSlice(alloc, "const old_only_b = 2;\n");
    try new_buf.appendSlice(alloc, "const new_only_a = 1;\n");
    for (3000..6000) |i| {
        try old_buf.writer(alloc).print("tail {d}\n", .{i});
        try new_buf.writer(alloc).print("tail {d}\n", .{i});
    }

    var fd = try diffFileWith(alloc, "big.zig", old_buf.items, new_buf.items, .myers);
    defer fd.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 2), fd.lines_removed);
}

test "myers windowed trace handles fully disjoint content (high edit distance)" {
    const alloc = std.testing.allocator;
    const old = "a\nb\nc\nd\ne\n";
    const new = "v\nw\nx\ny\nz\n";
    var fd = try diffFileWith(alloc, "disjoint.txt", old, new, .myers);
    defer fd.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 5), fd.lines_added);
    try std.testing.expectEqual(@as(u32, 5), fd.lines_removed);
}

test "myers windowed trace correct for word-level diffs (T = WordDelta)" {
    const alloc = std.testing.allocator;
    const old = "the quick brown fox jumps over the lazy dog\n";
    const new = "the quick red fox jumps over the sleepy dog\n";

    var fd = try diffFileWith(alloc, "words.txt", old, new, .myers);
    defer fd.deinit(alloc);

    var words_added: u32 = 0;
    var words_removed: u32 = 0;
    for (fd.word_deltas) |wd| switch (wd.op) {
        .ins => words_added += 1,
        .del => words_removed += 1,
        .eq => {},
    };
    try std.testing.expectEqual(@as(u32, 2), words_added);
    try std.testing.expectEqual(@as(u32, 2), words_removed);
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

test {
    std.testing.refAllDecls(@This());
}
