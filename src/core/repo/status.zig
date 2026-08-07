//! Result types for `Repository.status`. Plain data, no formatting —
//! turning this into text is entirely the CLI's job, which is what
//! keeps `Repository` usable from tests and other callers that never
//! want anything printed.

const std = @import("std");
const merkle_mod = @import("merkle");
const EntryChange = merkle_mod.EntryChange;
const WorktreeState = merkle_mod.WorktreeState;

/// One entry's worktree-vs-index status, for `Status.unstaged`.
pub const WorktreeEntryStatus = struct {
    path: []const u8,
    state: WorktreeState,
};

/// Result of `Repository.status`. `staged` is index-vs-HEAD (what a
/// commit right now would record); `unstaged` is worktree-vs-index
/// (what `add` would pick up). Free with `.deinit`.
///
/// NOTE: `unstaged` only covers currently-tracked paths — it can report
/// `.modified`/`.deleted` but not brand-new untracked files, since that
/// needs a worktree directory walk this layer doesn't own.
pub const Status = struct {
    staged: []EntryChange,
    unstaged: []WorktreeEntryStatus,

    pub fn deinit(self: *Status, alloc: std.mem.Allocator) void {
        merkle_mod.freeChanges(alloc, self.staged);
        alloc.free(self.unstaged);
        self.* = undefined;
    }
};
