//! The one error set every `Repository` method promises to use for
//! ordinary, expected-to-happen conditions (a bad path, an ambiguous
//! rev, a repo that's already there). It's the seam this module offers
//! the CLI layer: match on `RepositoryError` and you've covered every
//! *user-facing* failure a command can hit, without knowing anything
//! about `Index`, `History`, `ReferenceStore`, or storage internals.
//!
//! It is NOT the full error union every method returns — Zig's
//! inferred error sets mean things like `error.OutOfMemory` or a raw
//! filesystem error can still surface from underneath. Those represent
//! an environment or storage-layer failure rather than something a user
//! did, so `describe` deliberately doesn't cover them: a caller that
//! gets an error not handled by `describe` should treat it as "wrap in
//! `@errorName` and report it as unexpected," not silently fall back to
//! a made-up message.

pub const RepositoryError = error{
    AlreadyInitialized,
    NotARepository,
    /// current points directly at a commit rather than a track. Every
    /// mutating command here (`add`/`commit`/`reset`) needs a track to
    /// advance, so detached current is out of scope for this facade —
    /// surface it to the caller instead of guessing which track to use.
    DetachedFocus,

    // -- path arguments (add/rm/mv/restore) --
    /// A path argument was already absolute; every path in this API is
    /// repo-root-relative.
    AbsolutePath,
    /// A path argument had a `..` segment that would resolve outside root.
    PathEscapesRoot,
    /// The path isn't in the index — nothing to restore/remove/move/unstage.
    NotTracked,
    /// `movePath`'s destination is already tracked and `force` wasn't set.
    DestinationTracked,
    /// `movePath` was given the same path for `from` and `to`.
    SamePath,

    // -- history/rev resolution (show/diff/uncommit) --
    /// The current track has no commits yet.
    NoCommits,
    /// HEAD is a merge commit; `uncommit` only supports linear history.
    MergeCommit,
    /// A short hash prefix passed to `resolveRev` matched more than one object.
    AmbiguousRev,
    /// Neither a full hash nor a known prefix.
    RevNotFound,
    /// Not valid hex and not a resolvable prefix either.
    InvalidRev,
};

/// One-line, user-facing description of each `RepositoryError` variant.
/// This is the whole pattern for how `Repository` talks to a CLI:
///
///   1. A command builds an Options struct from parsed flags/args.
///   2. It calls exactly one `Repository` method.
///   3. On failure, if the error is a `RepositoryError`, it prints
///      `describe(err)`. Anything else is unexpected — print
///      `@errorName(err)` and treat it as a bug report, not a normal
///      failure mode.
///
/// The switch is exhaustive over `RepositoryError`'s fields on purpose:
/// adding a new variant is a compile error here until it gets a
/// description, so the CLI can never silently fall through to a
/// generic message for a condition this module already knows how to
/// name.
pub fn describe(err: RepositoryError) []const u8 {
    return switch (err) {
        error.AlreadyInitialized => "a repository already exists here",
        error.NotARepository => "not a merk repository (no current found)",
        error.DetachedFocus => "current is detached from a track; this command needs one",
        error.AbsolutePath => "path must be relative to the repository root",
        error.PathEscapesRoot => "path escapes the repository root",
        error.NotTracked => "path is not tracked",
        error.DestinationTracked => "destination is already tracked (use force to overwrite)",
        error.SamePath => "source and destination are the same path",
        error.NoCommits => "the current track has no commits yet",
        error.MergeCommit => "HEAD is a merge commit; this command only supports linear history",
        error.AmbiguousRev => "that prefix matches more than one commit",
        error.RevNotFound => "no commit matches that reference",
        error.InvalidRev => "not a valid commit hash or prefix",
    };
}
