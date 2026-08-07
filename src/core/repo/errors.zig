//! User-facing errors produced by the Repository layer.
//!
//! Repository methods may still return lower-level errors such as
//! `OutOfMemory` or filesystem errors. Those are infrastructure
//! failures rather than expected repository conditions and should be
//! handled by the caller as unexpected errors.
//!
//! `RepositoryError` is the stable error boundary between the core
//! repository and higher-level interfaces such as the CLI.

pub const RepositoryError = error{

    /// A repository is already initialized at the requested location.
    AlreadyInitialized,

    /// The requested path does not contain a valid Merk repository.
    NotARepository,

    /// The current reference is detached and the operation requires a
    /// channel that can be advanced.
    DetachedCurrent,


    /// A path argument was absolute. Repository paths must be
    /// relative to the repository root.
    AbsolutePath,

    /// A path argument would resolve outside the repository root.
    PathEscapesRoot,

    /// The requested path is not tracked.
    NotTracked,

    /// A move destination is already tracked and force was not requested.
    DestinationTracked,

    /// Source and destination refer to the same path.
    SamePath,

    /// The requested path is tracked, but an existing filesystem entry
    /// prevents the operation from proceeding.
    ObstructedPath,


    /// The current channel has no commits.
    NoCommits,

    /// The current commit has multiple parents, but the operation only
    /// supports linear history.
    MergeCommit,

    /// A revision prefix matches multiple commits.
    AmbiguousRev,

    /// No commit matches the requested revision.
    RevNotFound,

    /// The supplied revision is neither a valid hash nor a resolvable
    /// revision prefix.
    InvalidRev,


    /// A referenced blob could not be found in the object store.
    BlobMissing,
};


/// intentionally exhaustive. Adding a new RepositoryError
/// requires adding its corresponding description here
pub fn describe(err: RepositoryError) []const u8 {
    return switch (err) {
        error.AlreadyInitialized => "repository already initialized",
        error.NotARepository => "not a merk repository",
        error.DetachedCurrent => "current is detached; this command requires an active channel",

        error.AbsolutePath => "path must be relative to the repository root",
        error.PathEscapesRoot => "path escapes the repository root",
        error.NotTracked => "path is not tracked",
        error.DestinationTracked => "destination is already tracked",
        error.SamePath => "source and destination are the same path",
        error.ObstructedPath => "path is obstructed by an existing filesystem entry",

        error.NoCommits => "the current channel has no commits",
        error.MergeCommit => "the current commit is a merge commit; this command only supports linear history",
        error.AmbiguousRev => "revision prefix matches multiple commits",
        error.RevNotFound => "no commit matches that revision",
        error.InvalidRev => "not a valid commit hash or revision prefix",

        error.BlobMissing => "referenced blob is missing from the object store",
    };
}