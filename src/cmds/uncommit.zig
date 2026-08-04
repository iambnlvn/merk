const std = @import("std");
const merk = @import("merk");

const repo_context = @import("repo_context.zig");
const commit_mod = @import("../core/commit.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Flag = cli.Flag;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    const hard = inv.flags.boolean("hard");

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const track = opened.repo.current_track;

    const head_hash = (try opened.repo.ref_store.readTrack(track)) orelse {
        try ctx.err.print("error: no commits yet\n", .{});
        return error.NoCommits;
    };

    var head_commit = try commit_mod.read(inv.alloc, &opened.repo.store, head_hash);
    defer head_commit.deinit(inv.alloc);

    if (head_commit.parents.len > 1) {
        try ctx.err.print(
            "error: HEAD is a merge commit ({d} parents); uncommit only supports linear history\n",
            .{head_commit.parents.len},
        );
        return error.MergeCommit;
    }

    if (hard) {
        try ctx.err.print(
            "error: --hard isn't wired up yet (needs a way to reload the index/worktree from an arbitrary snapshot hash) — only the default soft undo is supported right now\n",
            .{},
        );
        return error.NotImplemented;
    }

    const undone_hex = try merk.crypto.hash.toHex(inv.alloc, head_hash);
    defer inv.alloc.free(undone_hex);

    if (head_commit.parents.len == 0) {
        // Root commit: there's no parent to move the track pointer to, so
        // the soft-undo equivalent is deleting the track's ref file
        // entirely — the same "no ref yet" state every other command
        // already treats as "no commits" (commit.zig's `maybe_head == null`
        // root-commit path, log.zig's "no commits yet" error). The next
        // `merk commit` on this track will go through exactly the same
        // root-commit path it did the first time.
        try opened.repo.ref_store.deleteTrack(track);

        try ctx.out.print("undone         {s}\n", .{undone_hex});
        try ctx.out.print("{s} is now at  (no commits)\n", .{track.raw});
        try ctx.out.print(
            "\nThat was the root commit — '{s}' has no commits now.\nChanges from the undone commit are still staged — edit and re-run\n`merk commit` when ready, or `merk restore --staged <path>` to drop\nspecific files back out of the index.\n",
            .{track.raw},
        );
        return;
    }

    const parent_hash = head_commit.parents[0].hash;

    // Soft undo: move the track pointer back one commit. The index is
    // deliberately left untouched — it still holds the snapshot that was
    // just committed (see commit.zig's own "staged tree == HEAD" check,
    // which relies on the same invariant), so the undone commit's changes
    // stay staged and ready to edit/re-commit, same as `git reset --soft`.
    try opened.repo.ref_store.updateTrack(track, parent_hash);

    const parent_hex = try merk.crypto.hash.toHex(inv.alloc, parent_hash);
    defer inv.alloc.free(parent_hex);

    try ctx.out.print("undone         {s}\n", .{undone_hex});
    try ctx.out.print("{s} is now at  {s}\n", .{ track.raw, parent_hex });
    try ctx.out.print(
        "\nChanges from the undone commit are still staged — edit and re-run\n`merk commit` when ready, or `merk restore --staged <path>` to drop\nspecific files back out of the index.\n",
        .{},
    );
}

pub const command = Command{
    .name = "uncommit",
    .description = "Move the current track back to its parent, undoing the last commit.",
    .usage = "[--hard]",
    .category = .history,
    .flags = &.{
        .{
            .long = "hard",
            .kind = .boolean,
            .help = "also reset the index and working tree to the parent commit (not yet implemented)",
        },
    },
    .run = run,
};
