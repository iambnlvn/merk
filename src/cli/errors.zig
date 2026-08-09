const std = @import("std");
const repository_mod = @import("../core/repo/repo.zig");
const RepositoryError = repository_mod.RepositoryError;
const Context = @import("context.zig").Context;

/// Special CLI-level errors that control execution flow rather than
/// requiring generic reporting.
pub const CliError = error{
    /// Indicates an error has already been fully printed to the user
    /// with context-specific hints, and the CLI should just exit(1).
    SilentExit,
};

/// Narrows `anyerror` down to `RepositoryError` when `err` is one of
/// its variants, `null` otherwise.
fn narrowRepositoryError(err: anyerror) ?RepositoryError {
    const repo_errors = @typeInfo(RepositoryError).error_set orelse
        @compileError("RepositoryError must be a closed error set");

    inline for (repo_errors) |err_info| {
        if (err == @field(anyerror, err_info.name)) {
            return @field(RepositoryError, err_info.name);
        }
    }

    return null;
}

/// `true` when `err` is a `RepositoryError` this module already knows
/// how to describe. Exposed so `main.zig`'s top-level fallback can
/// skip re-printing an error a command already reported.
pub fn isReported(err: anyerror) bool {
    if (err == CliError.SilentExit) return true;
    return narrowRepositoryError(err) != null;
}

/// Reports `err` to `ctx.err` — `describe(err)` for a `RepositoryError`,
/// `@errorName(err)` flagged as unexpected for anything else — and
/// returns `err` unchanged so call sites can bubble it up cleanly.
pub fn report(ctx: Context, err: anyerror) anyerror {
    // If the command already handled the UI, do nothing.
    if (err == CliError.SilentExit) return err;

    if (narrowRepositoryError(err)) |repo_err| {
        ctx.err.print("merk: {s}\n", .{repository_mod.describe(repo_err)}) catch {};
    } else {
        ctx.err.print("merk: unexpected error: {s}\n", .{@errorName(err)}) catch {};
    }

    return err;
}

test "narrowRepositoryError auto-detects variants and rejects others" {
    try std.testing.expectEqual(RepositoryError.AlreadyInitialized, narrowRepositoryError(error.AlreadyInitialized).?);
    try std.testing.expectEqual(RepositoryError.InvalidRev, narrowRepositoryError(error.InvalidRev).?);
    try std.testing.expect(narrowRepositoryError(error.OutOfMemory) == null);
    try std.testing.expect(narrowRepositoryError(error.FileNotFound) == null);
}

test "isReported handles repo errors and SilentExit" {
    try std.testing.expect(isReported(error.NoCommits));
    try std.testing.expect(isReported(CliError.SilentExit));
    try std.testing.expect(!isReported(error.OutOfMemory));
}
