//TODO!: this needs to be redone, this is an initial impl
// might use a range tree or arrays by supporting both
// we can prolly optimize this with range trees but i
// think the number of lines of a hunk or the number of hunks
// is way too small (an O(log(n))tree trav could be
// way too slower than a linear O(n)) array scan, plus the
// cache locality issues related to range trees.
// needs some research on this

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const diff_algorithms = @import("diff_algorithms.zig");
const LineDelta = diff_algorithms.LineDelta;

/// The half-open index range `[start, end)` into a `LineDelta` slice
/// that one hunk covers, including its context lines. Two adjacent
/// `HunkRange`s never overlap and are returned in ascending order.
pub const HunkRange = struct {
    start: usize,
    end: usize,
};

/// Groups `line_deltas` into hunks the same way `git diff` does: each
/// contiguous run of non-`.eq` ops, padded with up to `context` lines
/// of `.eq` on each side, merging with a neighboring run if the `.eq`
/// gap between them is `<= context * 2`. Pure `.eq` middle sections
/// longer than that stay out of every hunk entirely — patch
/// application doesn't need them in a hunk (see `applySelected`, which
/// always keeps `.eq` lines regardless of hunk membership) but a
/// caller rendering hunks for a human to review does.
///
/// Owned by the caller — free with `alloc.free(result)`.
pub fn hunkRanges(alloc: Allocator, line_deltas: []const LineDelta, context: u32) ![]HunkRange {
    var out: ArrayList(HunkRange) = .empty;
    errdefer out.deinit(alloc);

    var it = HunkRangeIterator.init(line_deltas, context);
    while (it.next()) |r| try out.append(alloc, r);

    return out.toOwnedSlice(alloc);
}

/// The actual boundary-computation logic, exposed as a zero-allocation
/// iterator so `hunkRanges` (which wants an owned slice) and
/// `diff_render.zig`'s `HunkIterator` (which wants to iterate without
/// paying for a slice it's about to throw away) can both build on the
/// exact same walk without either one recomputing it independently.
pub const HunkRangeIterator = struct {
    deltas: []const LineDelta,
    context: u32,
    i: usize,

    pub fn init(deltas: []const LineDelta, context: u32) HunkRangeIterator {
        return .{ .deltas = deltas, .context = context, .i = 0 };
    }

    pub fn next(self: *HunkRangeIterator) ?HunkRange {
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

        const result = HunkRange{ .start = start, .end = hunk_end };
        self.i = hunk_end;
        return result;
    }
};

/// Reconstructs file content bytes from `line_deltas`, applying only
/// the hunks marked `true` in `selected` (same length and order as
/// `hunks`, typically the output of `hunkRanges`) and leaving every
/// other hunk's range exactly as the *old* (baseline) side had it.
///
/// The rule per op, inside a selected hunk vs. not:
///   .eq   — always emitted verbatim; identical on both sides, so hunk
///           selection can't affect it either way.
///   .ins  — emitted only if its hunk is selected (an unselected
///           insertion is "don't apply this addition").
///   .del  — emitted (i.e. the old line is KEPT) only if its hunk is
///           NOT selected; a selected deletion is "apply this removal",
///           so it's omitted from the output.
/// A `.ins`/`.del` delta that falls outside every hunk range shouldn't
/// occur in practice (hunkRanges always covers every non-`.eq` delta by
/// construction), but is treated as "not selected" rather than
/// asserted against, so a caller passing hand-built ranges that don't
/// happen to cover everything fails soft (wrong-but-safe reconstruction)
/// rather than crashing.
///
/// Trailing-newline-ness is NOT recoverable from `line_deltas` alone —
/// `LineDelta.content` never includes its line's trailing `\n` (see
/// diff_algorithms.zig's own doc comment on `LineDelta`), and
/// `splitLines` collapses "ends with \n" and "doesn't end with \n"
/// into the same line sequence. So this function takes `old_src` and
/// `new_src` — the exact raw bytes the diff was computed from, which
/// every caller already has on hand — and, after reconstructing the
/// line content, decides whether the LAST emitted line should get a
/// trailing `\n` by asking: which source did that line actually come
/// from?
///   - last emitted delta is `.ins`  → it only exists in `new_src`, so
///     follow `new_src`'s ending.
///   - last emitted delta is `.del`  → it's a kept old line, so follow
///     `old_src`'s ending.
///   - last emitted delta is `.eq`   → present in both; if they agree,
///     use that. If they disagree (old/new differ in trailing-newline-
///     ness on an unrelated final unchanged line — possible but rare),
///     `new_src`'s ending wins, since it reflects the worktree's
///     current state.
/// A blob staged via this function's output is therefore
/// byte-identical to what `Staging.addFileFromDir` would store for the
/// same effective content, which full-hunk-selection round trips now
/// verify directly (see the test below).
///
/// Caller owns the returned slice.
pub fn applySelected(
    alloc: Allocator,
    line_deltas: []const LineDelta,
    hunks: []const HunkRange,
    selected: []const bool,
    old_src: []const u8,
    new_src: []const u8,
) ![]u8 {
    std.debug.assert(hunks.len == selected.len);

    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var hunk_i: usize = 0;
    var last_emitted_op: ?diff_algorithms.Op = null;
    for (line_deltas, 0..) |d, i| {
        while (hunk_i < hunks.len and i >= hunks[hunk_i].end) hunk_i += 1;
        const in_selected_hunk = hunk_i < hunks.len and
            i >= hunks[hunk_i].start and i < hunks[hunk_i].end and
            selected[hunk_i];

        const emit = switch (d.op) {
            .eq => true,
            .ins => in_selected_hunk,
            .del => !in_selected_hunk,
        };
        if (emit) {
            try out.appendSlice(alloc, d.content);
            try out.append(alloc, '\n');
            last_emitted_op = d.op;
        }
    }

    if (last_emitted_op) |op| {
        const wants_trailing_newline = switch (op) {
            .ins => endsWithNewline(new_src),
            .del => endsWithNewline(old_src),
            .eq => endsWithNewline(new_src),
        };
        if (!wants_trailing_newline) {
            std.debug.assert(out.items.len > 0 and out.items[out.items.len - 1] == '\n');
            _ = out.pop();
        }
    }

    return out.toOwnedSlice(alloc);
}

fn endsWithNewline(src: []const u8) bool {
    return src.len > 0 and src[src.len - 1] == '\n';
}

const testing = std.testing;

test "hunkRanges groups a single changed region with context on both sides" {
    const alloc = testing.allocator;
    var fd = try diff_algorithms.diffFileWith(
        alloc,
        "f.txt",
        "a\nb\nc\nd\ne\nf\ng\n",
        "a\nb\nc\nX\ne\nf\ng\n",
        .myers,
    );
    defer fd.deinit(alloc);

    const ranges = try hunkRanges(alloc, fd.line_deltas, 1);
    defer alloc.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
}

test "hunkRanges splits two far-apart changes into separate hunks" {
    const alloc = testing.allocator;
    var old_buf: ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    for (0..20) |i| {
        if (i == 2) {
            try old_buf.appendSlice(alloc, "old-a\n");
            try new_buf.appendSlice(alloc, "new-a\n");
        } else if (i == 17) {
            try old_buf.appendSlice(alloc, "old-b\n");
            try new_buf.appendSlice(alloc, "new-b\n");
        } else {
            try old_buf.writer(alloc).print("line{d}\n", .{i});
            try new_buf.writer(alloc).print("line{d}\n", .{i});
        }
    }

    var fd = try diff_algorithms.diffFileWith(alloc, "f.txt", old_buf.items, new_buf.items, .myers);
    defer fd.deinit(alloc);

    const ranges = try hunkRanges(alloc, fd.line_deltas, 2);
    defer alloc.free(ranges);

    try testing.expectEqual(@as(usize, 2), ranges.len);
}

test "applySelected with every hunk selected reproduces the new content" {
    const alloc = testing.allocator;
    const old = "a\nb\nc\n";
    const new = "a\nX\nc\n";

    var fd = try diff_algorithms.diffFileWith(alloc, "f.txt", old, new, .myers);
    defer fd.deinit(alloc);

    const ranges = try hunkRanges(alloc, fd.line_deltas, 1);
    defer alloc.free(ranges);

    const selected = try alloc.alloc(bool, ranges.len);
    defer alloc.free(selected);
    @memset(selected, true);

    const result = try applySelected(alloc, fd.line_deltas, ranges, selected, old, new);
    defer alloc.free(result);

    try testing.expectEqualStrings(new, result);
}

test "applySelected with no hunk selected reproduces the old content" {
    const alloc = testing.allocator;
    const old = "a\nb\nc\n";
    const new = "a\nX\nc\n";

    var fd = try diff_algorithms.diffFileWith(alloc, "f.txt", old, new, .myers);
    defer fd.deinit(alloc);

    const ranges = try hunkRanges(alloc, fd.line_deltas, 1);
    defer alloc.free(ranges);

    const selected = try alloc.alloc(bool, ranges.len);
    defer alloc.free(selected);
    @memset(selected, false);

    const result = try applySelected(alloc, fd.line_deltas, ranges, selected, old, new);
    defer alloc.free(result);

    try testing.expectEqualStrings(old, result);
}

test "applySelected picks exactly one hunk's change out of two independent hunks" {
    const alloc = testing.allocator;
    var old_buf: ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    for (0..20) |i| {
        if (i == 2) {
            try old_buf.appendSlice(alloc, "old-a\n");
            try new_buf.appendSlice(alloc, "new-a\n");
        } else if (i == 17) {
            try old_buf.appendSlice(alloc, "old-b\n");
            try new_buf.appendSlice(alloc, "new-b\n");
        } else {
            try old_buf.writer(alloc).print("line{d}\n", .{i});
            try new_buf.writer(alloc).print("line{d}\n", .{i});
        }
    }

    var fd = try diff_algorithms.diffFileWith(alloc, "f.txt", old_buf.items, new_buf.items, .myers);
    defer fd.deinit(alloc);

    const ranges = try hunkRanges(alloc, fd.line_deltas, 2);
    defer alloc.free(ranges);
    try testing.expectEqual(@as(usize, 2), ranges.len);

    // Select only the first hunk (the "a" change) -- the second ("b")
    // should still read as "old-b" in the result.
    const selected = try alloc.alloc(bool, ranges.len);
    defer alloc.free(selected);
    selected[0] = true;
    selected[1] = false;

    const result = try applySelected(alloc, fd.line_deltas, ranges, selected, old_buf.items, new_buf.items);
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "new-a") != null);
    try testing.expect(std.mem.indexOf(u8, result, "old-b") != null);
    try testing.expect(std.mem.indexOf(u8, result, "new-b") == null);
}

test "applySelected preserves a missing trailing newline on full selection" {
    const alloc = testing.allocator;
    const old = "a\nb";
    const new = "a\nX";

    var fd = try diff_algorithms.diffFileWith(alloc, "f.txt", old, new, .myers);
    defer fd.deinit(alloc);

    const ranges = try hunkRanges(alloc, fd.line_deltas, 1);
    defer alloc.free(ranges);
    const selected = try alloc.alloc(bool, ranges.len);
    defer alloc.free(selected);
    @memset(selected, true);

    const result = try applySelected(alloc, fd.line_deltas, ranges, selected, old, new);
    defer alloc.free(result);

    try testing.expectEqualStrings(new, result);
}

test "applySelected preserves trailing newline presence when old has one and new doesn't" {
    const alloc = testing.allocator;
    const old = "a\nb\n";
    const new = "a\nX";

    var fd = try diff_algorithms.diffFileWith(alloc, "f.txt", old, new, .myers);
    defer fd.deinit(alloc);

    const ranges = try hunkRanges(alloc, fd.line_deltas, 1);
    defer alloc.free(ranges);
    const selected = try alloc.alloc(bool, ranges.len);
    defer alloc.free(selected);

    // Selected: last line becomes the `.ins` "X" -> follows new_src (no \n).
    @memset(selected, true);
    const staged_new = try applySelected(alloc, fd.line_deltas, ranges, selected, old, new);
    defer alloc.free(staged_new);
    try testing.expectEqualStrings("a\nX", staged_new);

    // Unselected: last line stays the `.del` "b" (kept) -> follows old_src (has \n).
    @memset(selected, false);
    const staged_old = try applySelected(alloc, fd.line_deltas, ranges, selected, old, new);
    defer alloc.free(staged_old);
    try testing.expectEqualStrings("a\nb\n", staged_old);
}

test {
    testing.refAllDecls(@This());
}
