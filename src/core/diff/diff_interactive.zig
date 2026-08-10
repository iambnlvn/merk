const std = @import("std");
const Allocator = std.mem.Allocator;

const diff_algorithms = @import("diff_algorithms.zig");
const LineDelta = diff_algorithms.LineDelta;
const Op = diff_algorithms.Op;

const diff_patch = @import("diff_patch.zig");
const HunkRange = diff_patch.HunkRange;
const hunkRanges = diff_patch.hunkRanges;
const applySelected = diff_patch.applySelected;

/// What the user answered for one hunk. `help` isn't a decision -- it
/// re-prompts the same hunk -- so it never appears in `run`'s result;
/// it's only surfaced so `nextDecision` and its caller can stay
/// separate small pieces instead of one function that both parses
/// input and prints help text.
pub const Decision = enum { stage, skip, quit, stage_all_remaining, skip_all_remaining, help, invalid };

/// The outcome of running the whole loop over every hunk.
pub const InteractiveOutcome = struct {
    /// Reconstructed file content with exactly the staged hunks
    /// applied. Caller owns; pass this straight to
    /// `Staging.addContent`. Empty selection still produces valid
    /// content (== old_src, modulo the trailing-newline rule
    /// `applySelected` documents) rather than null, so a caller doesn't
    /// need a separate branch for "nothing selected" vs. "content to
    /// stage" -- `any_staged` is what decides whether to bother calling
    /// `addContent` at all.
    content: []u8,
    /// Total number of hunks the diff produced.
    hunk_count: usize,
    /// Number of hunks marked to stage. 0 means nothing changed --
    /// callers should treat this as "nothing to stage" and skip
    /// calling `Staging.addContent` (staging old_src unchanged would
    /// be a no-op that still touches the entry's mtime bookkeeping for
    /// no reason).
    staged_count: usize,
    /// True if the user answered 'q' (or ran out of input entirely --
    /// see `readAnswer`) before every hunk was decided. Hunks not yet
    /// reached are treated as skipped in `content` -- same semantics
    /// as `git add -p`'s "q" ("quit; do not stage this hunk or any of
    /// the remaining ones").
    quit_early: bool,

    pub fn deinit(self: *InteractiveOutcome, alloc: Allocator) void {
        alloc.free(self.content);
    }
};

/// Runs the interactive loop over every hunk in `line_deltas` (as
/// grouped by `hunkRanges(line_deltas, context)`), prompting on
/// `writer`/`reader` for each one, and returns the reconstructed
/// content plus bookkeeping on what happened.
///
/// `old_src`/`new_src` must be the exact byte slices `line_deltas` was
/// diffed from (i.e. what was passed to `diffFileWith`) -- they're
/// needed for `applySelected`'s trailing-newline handling, not
/// re-diffed here.
pub fn run(
    alloc: Allocator,
    line_deltas: []const LineDelta,
    old_src: []const u8,
    new_src: []const u8,
    context: u32,
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
) !InteractiveOutcome {
    const hunks = try hunkRanges(alloc, line_deltas, context);
    defer alloc.free(hunks);

    const selected = try alloc.alloc(bool, hunks.len);
    defer alloc.free(selected);
    @memset(selected, false);

    var staged_count: usize = 0;
    var quit_early = false;
    // Once the user answers 'a' or 'd', every remaining hunk is
    // auto-decided without prompting -- this holds that decision.
    var force: ?bool = null;

    for (hunks, 0..) |hunk, i| {
        if (force) |f| {
            selected[i] = f;
            if (f) staged_count += 1;
            continue;
        }

        try writeHunk(writer, line_deltas, hunk, i, hunks.len);

        prompt: while (true) {
            try writer.writeAll("Stage this hunk [y,n,q,a,d,?]? ");
            // Must flush before reading: the prompt above (and, on the
            // first iteration for this hunk, writeHunk's output too)
            // is still sitting in writer's buffer at this point --
            // reader.takeDelimiterExclusive below blocks for input, and
            // nothing forces a flush on its own. See this function's
            // own doc comment.
            try writer.flush();

            const raw = readAnswer(reader) catch |err| switch (err) {
                // Genuinely nothing left to read (as opposed to a final
                // unterminated line, which takeDelimiterExclusive still
                // returns successfully) -- treat like an explicit 'q'
                // rather than looping forever re-prompting a reader
                // that can never answer.
                error.EndOfStream => {
                    quit_early = true;
                    break :prompt;
                },
                // A line longer than reader's own buffer. Reprompt
                // rather than aborting the whole session over one
                // garbage line -- see readAnswer's doc comment for the
                // known limitation this leaves.
                error.StreamTooLong => {
                    try writeHelp(writer);
                    continue :prompt;
                },
                else => return err,
            };
            const answer = std.mem.trim(u8, raw, " \t\r\n");

            switch (decide(answer)) {
                .stage => {
                    selected[i] = true;
                    staged_count += 1;
                    break :prompt;
                },
                .skip => break :prompt,
                .quit => {
                    quit_early = true;
                    break :prompt;
                },
                .stage_all_remaining => {
                    force = true;
                    selected[i] = true;
                    staged_count += 1;
                    break :prompt;
                },
                .skip_all_remaining => {
                    force = false;
                    break :prompt;
                },
                .help, .invalid => {
                    try writeHelp(writer);
                    continue :prompt;
                },
            }
        }

        if (quit_early) break;
    }

    const content = try applySelected(alloc, line_deltas, hunks, selected, old_src, new_src);
    return .{
        .content = content,
        .hunk_count = hunks.len,
        .staged_count = staged_count,
        .quit_early = quit_early,
    };
}

/// Parses one line of user input into a `Decision`. Only the first
/// non-whitespace character matters -- `y`, `yes`, and `Y` all read as
/// `.stage` -- matching how `git add -p` accepts terse single-letter
/// answers without demanding an exact match.
fn decide(answer: []const u8) Decision {
    if (answer.len == 0) return .invalid;
    return switch (answer[0]) {
        'y', 'Y' => .stage,
        'n', 'N' => .skip,
        'q', 'Q' => .quit,
        'a', 'A' => .stage_all_remaining,
        'd', 'D' => .skip_all_remaining,
        '?' => .help,
        else => .invalid,
    };
}

fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\y - stage this hunk
        \\n - do not stage this hunk
        \\q - quit; do not stage this hunk or any remaining ones
        \\a - stage this hunk and all later hunks in this file
        \\d - do not stage this hunk or any later ones in this file
        \\? - print this help
        \\
    );
}

fn writeHunk(
    writer: *std.Io.Writer,
    line_deltas: []const LineDelta,
    hunk: HunkRange,
    index: usize,
    total: usize,
) !void {
    const deltas = line_deltas[hunk.start..hunk.end];
    try writer.print("@@ hunk {d}/{d}, line {d} @@\n", .{ index + 1, total, displayLineNum(deltas) });
    for (deltas) |d| {
        const prefix: []const u8 = switch (d.op) {
            .eq => "  ",
            .del => "- ",
            .ins => "+ ",
        };
        try writer.print("{s}{s}\n", .{ prefix, d.content });
    }
}

/// Same rule diff_render.zig's `Hunk.displayLineNum` uses: the old-file
/// line number of the first non-`.ins` delta in the hunk (falling back
/// to the new-file number of the first delta if the hunk is pure
/// insertion), so a hunk shown here lines up with the same hunk shown
/// by `render`/`renderFile` in review-before-staging output.
fn displayLineNum(deltas: []const LineDelta) u32 {
    for (deltas) |d| {
        if (d.op != .ins) return d.old_lineno;
    }
    return deltas[0].new_lineno;
}

/// Reads one line of user input via `reader.takeDelimiterExclusive('\n')`
/// and discards the newline itself with `.toss(1)` -- the standard
/// std.Io.Reader idiom for line-oriented input (see e.g. the REPL
/// pattern in std.Io.Reader's own doc comments). The returned slice
/// borrows from `reader`'s internal buffer and is only valid until the
/// next read call; `run` only ever inspects it (via `decide`) before
/// reading again, so nothing here holds onto it longer than that.
///
/// `takeDelimiterExclusive` itself treats a final, non-newline-terminated
/// line as a successful read (not an error) -- `error.EndOfStream` only
/// comes back when there is truly nothing left to read at all. `run`
/// relies on that distinction to tell "last line, no trailing newline"
/// (answer it normally) apart from "reader is exhausted" (treat as an
/// implicit quit).
///
/// No local buffer is owned or sized here -- unlike the byte-at-a-time
/// version this replaced, buffer sizing is entirely the caller's
/// concern via whatever backs `reader` (e.g. the CLI's own stdin
/// buffer). `error.StreamTooLong` -- a single line longer than that
/// buffer -- is possible but is handled by `run`'s caller, not here.
fn readAnswer(reader: *std.Io.Reader) ![]const u8 {
    const line = try reader.takeDelimiterExclusive('\n');
    reader.toss(1);
    return line;
}

const testing = std.testing;

fn buildTwoHunkDiff(alloc: Allocator, old_buf: *std.ArrayList(u8), new_buf: *std.ArrayList(u8)) !diff_algorithms.FileDiff {
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
    return diff_algorithms.diffFileWith(alloc, "f.txt", old_buf.items, new_buf.items, .myers);
}

test "run stages only the hunks answered y, in order" {
    const alloc = testing.allocator;
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    var fd = try buildTwoHunkDiff(alloc, &old_buf, &new_buf);
    defer fd.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var in: std.Io.Reader = .fixed("y\nn\n");

    var outcome = try run(alloc, fd.line_deltas, old_buf.items, new_buf.items, 2, &out.writer, &in);
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), outcome.hunk_count);
    try testing.expectEqual(@as(usize, 1), outcome.staged_count);
    try testing.expect(!outcome.quit_early);
    try testing.expect(std.mem.indexOf(u8, outcome.content, "new-a") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.content, "old-b") != null);
}

test "run 'a' stages the current hunk and every remaining one without prompting" {
    const alloc = testing.allocator;
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    var fd = try buildTwoHunkDiff(alloc, &old_buf, &new_buf);
    defer fd.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // Only one answer supplied -- 'a' on the first hunk must decide
    // the second without reading further input.
    var in: std.Io.Reader = .fixed("a\n");

    var outcome = try run(alloc, fd.line_deltas, old_buf.items, new_buf.items, 2, &out.writer, &in);
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), outcome.staged_count);
    try testing.expect(std.mem.indexOf(u8, outcome.content, "new-a") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.content, "new-b") != null);
}

test "run 'q' stops prompting and stages nothing further" {
    const alloc = testing.allocator;
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    var fd = try buildTwoHunkDiff(alloc, &old_buf, &new_buf);
    defer fd.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var in: std.Io.Reader = .fixed("y\nq\n");

    var outcome = try run(alloc, fd.line_deltas, old_buf.items, new_buf.items, 2, &out.writer, &in);
    defer outcome.deinit(alloc);

    try testing.expect(outcome.quit_early);
    try testing.expectEqual(@as(usize, 1), outcome.staged_count);
    try testing.expect(std.mem.indexOf(u8, outcome.content, "new-a") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.content, "old-b") != null);
}

test "run runs out of input mid-file and treats it as an implicit quit, not an infinite loop" {
    const alloc = testing.allocator;
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    var fd = try buildTwoHunkDiff(alloc, &old_buf, &new_buf);
    defer fd.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // One answer for the first hunk, then nothing -- no second line,
    // not even an unterminated one.
    var in: std.Io.Reader = .fixed("y\n");

    var outcome = try run(alloc, fd.line_deltas, old_buf.items, new_buf.items, 2, &out.writer, &in);
    defer outcome.deinit(alloc);

    try testing.expect(outcome.quit_early);
    try testing.expectEqual(@as(usize, 1), outcome.staged_count);
}

test "run '?' prints help and re-prompts the same hunk" {
    const alloc = testing.allocator;
    const old = "a\nb\nc\n";
    const new = "a\nX\nc\n";

    var fd = try diff_algorithms.diffFileWith(alloc, "f.txt", old, new, .myers);
    defer fd.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var in: std.Io.Reader = .fixed("?\ny\n");

    var outcome = try run(alloc, fd.line_deltas, old, new, 1, &out.writer, &in);
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), outcome.staged_count);
    try testing.expect(std.mem.indexOf(u8, out.written(), "stage this hunk") != null);
}

test "run with zero hunks (identical files) stages nothing and needs no input" {
    const alloc = testing.allocator;
    const src = "a\nb\nc\n";

    var fd = try diff_algorithms.diffFileWith(alloc, "f.txt", src, src, .myers);
    defer fd.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var in: std.Io.Reader = .fixed("");

    var outcome = try run(alloc, fd.line_deltas, src, src, 1, &out.writer, &in);
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), outcome.hunk_count);
    try testing.expectEqual(@as(usize, 0), outcome.staged_count);
    try testing.expectEqualStrings(src, outcome.content);
}

test {
    testing.refAllDecls(@This());
}
