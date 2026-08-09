//TODO: enhance this cuw this contains unnecessary code

const std = @import("std");
const repository_mod = @import("../core/repo/repo.zig");
const RepositoryError = repository_mod.RepositoryError;
const Context = @import("context.zig").Context;

/// Narrows `anyerror` down to `RepositoryError` when `err` is one of
/// its variants, `null` otherwise.
fn narrowRepositoryError(err: anyerror) ?RepositoryError {
    return switch (err) {
        error.AlreadyInitialized => error.AlreadyInitialized,
        error.NotARepository => error.NotARepository,
        error.DetachedCurrent => error.DetachedCurrent,
        error.AbsolutePath => error.AbsolutePath,
        error.PathEscapesRoot => error.PathEscapesRoot,
        error.NotTracked => error.NotTracked,
        error.DestinationTracked => error.DestinationTracked,
        error.SamePath => error.SamePath,
        error.NoCommits => error.NoCommits,
        error.MergeCommit => error.MergeCommit,
        error.AmbiguousRev => error.AmbiguousRev,
        error.RevNotFound => error.RevNotFound,
        error.InvalidRev => error.InvalidRev,
        else => null,
    };
}

/// `true` when `err` is a `RepositoryError` this module already knows
/// how to describe. Exposed so `main.zig`'s top-level fallback can
/// skip re-printing an error a command already reported via `report`
/// below, without duplicating the arm list here.
pub fn isReported(err: anyerror) bool {
    return narrowRepositoryError(err) != null;
}

/// Reports `err` to `ctx.err` — `describe(err)` for a `RepositoryError`,
/// `@errorName(err)` flagged as unexpected for anything else — and
/// returns `err` unchanged so call sites can write
/// `return report(ctx, err);` directly out of a `catch` block instead
/// of a multi-line if/print/return every time.
pub fn report(ctx: Context, err: anyerror) anyerror {
    if (narrowRepositoryError(err)) |repo_err| {
        ctx.err.print("merk: {s}\n", .{repository_mod.describe(repo_err)}) catch {};
    } else {
        ctx.err.print("merk: unexpected error: {s}\n", .{@errorName(err)}) catch {};
    }
    return err;
}

test "narrowRepositoryError recognizes RepositoryError variants and rejects everything else" {
    try std.testing.expectEqual(RepositoryError.AlreadyInitialized, narrowRepositoryError(error.AlreadyInitialized).?);
    try std.testing.expectEqual(RepositoryError.InvalidRev, narrowRepositoryError(error.InvalidRev).?);
    try std.testing.expect(narrowRepositoryError(error.OutOfMemory) == null);
    try std.testing.expect(narrowRepositoryError(error.FileNotFound) == null);
}

test "isReported mirrors narrowRepositoryError" {
    try std.testing.expect(isReported(error.NoCommits));
    try std.testing.expect(!isReported(error.OutOfMemory));
}
