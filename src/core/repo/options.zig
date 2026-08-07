//! Options structs for `Repository` methods that take more than one or
//! two required arguments, or that are likely to grow a flag later.
//!
//! The rule of thumb: if a CLI command would parse this into named
//! flags (`--force`, `--soft`/`--mixed`/`--hard`, `--cached`), it's a
//! struct here — not a positional bool/enum parameter — so parsing a
//! command's flags and building the call are the same struct literal,
//! and adding a flag later is a new field instead of a signature break.

const crypto = @import("crypto");
const Hash = crypto.Hash;

/// Options for `Repository.init`.
pub const InitOptions = struct {
    /// Bypass `error.AlreadyInitialized` and reinitialize Current plus
    /// the index against a fresh "main" track. Does NOT delete existing
    /// objects, commits, or other tracks already in the control
    /// directory — tearing down a repo's data entirely is a CLI-level
    /// concern (e.g. `rm -rf .merk`), not this API's job.
    force: bool = false,
};

/// Options for `Repository.removePaths`.
pub const RemoveOptions = struct {
    /// Only untrack; leave the worktree file where it is.
    cached: bool = false,
};

/// Options for `Repository.movePath`.
pub const MoveOptions = struct {
    /// Overwrite an already-tracked destination instead of erroring.
    force: bool = false,
};

pub const ResetMode = enum {
    /// Move the track pointer only. Index and worktree untouched.
    soft,
    /// Move the track pointer and reset the index to match. Worktree untouched.
    mixed,
    /// Move the track pointer, reset the index, and overwrite tracked
    /// worktree files to match. Does not delete files newly untracked
    /// by the reset — that needs a worktree walk this layer doesn't do.
    hard,
};

/// Options for `Repository.reset`. Bundled into a struct (rather than
/// `reset(target, mode)`) so a `--soft`/`--mixed`/`--hard` flag maps
/// directly onto a struct literal, and a future flag (e.g. a `--keep`
/// mode that preserves worktree edits) is an added field, not a
/// signature break.
pub const ResetOptions = struct {
    target: Hash,
    mode: ResetMode = .mixed,
};
