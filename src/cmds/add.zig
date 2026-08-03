const std = @import("std");
const merk = @import("merk");

const repository_mod = @import("../core/repository.zig");
const Repository = repository_mod.Repository;

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

/// `Repository` stores the `io.FileSystem` interface it's given —
/// `{ ptr, vtable }` — inside itself and every sub-component (`Store`,
/// `Index`, `PageStore`, `ReferenceStore`). That `ptr` has to keep
/// pointing at a live `RealFs`, so the `RealFs` must outlive the
/// `Repository` built from it. Bundling them together here is what
/// makes that lifetime obvious at the call site instead of implicit
const OpenedRepo = struct {
    repo: *Repository,
    real_fs: *merk.io.RealFs,

    fn deinit(self: OpenedRepo, alloc: std.mem.Allocator) void {
        self.repo.deinit();
        alloc.destroy(self.real_fs);
    }
};

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len == 0) {
        std.debug.print("error: 'add' requires at least one path\n", .{});
        command.printHelpToStderr();
        return error.MissingPath;
    }

    const opened = try openRepository(ctx);
    defer opened.deinit(ctx.alloc);

    try opened.repo.add(inv.positional.items);

    for (inv.positional.items) |path| {
        std.debug.print("staged {s}\n", .{path});
    }
}

/// Opens `<repo_root>/.merk` as a `RealFs` and hands it to
/// `Repository.open`. Every command that touches repo state needs this
/// same dance — worth lifting onto `Context` (or a shared
/// `cmds/repo.zig` helper) once more than one command is ported to
/// `Repository`, rather than duplicating it per-command.
///
/// NOTE: doesn't close `control_dir` — `Repository`/`RealFs` hold it
/// for the command's whole run, and the process exits shortly after,
/// so the OS reclaims the fd. Worth revisiting if commands ever start
/// opening more than one repo per process.
fn openRepository(ctx: Context) !OpenedRepo {
    var root_dir = try std.fs.cwd().openDir(ctx.repo_root, .{});
    defer root_dir.close();

    const control_dir = root_dir.openDir(".merk", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("error: not a merk repository (no .merk directory found)\n", .{});
            return err;
        },
        else => return err,
    };

    // Heap-allocated on purpose: `real_fs.fs()` embeds `&real_fs.*` into
    // the `io.FileSystem` value that `Repository` (and everything it
    // owns) copies around and holds onto long after this function returns
    const real_fs = try ctx.alloc.create(merk.io.RealFs);
    errdefer ctx.alloc.destroy(real_fs);
    real_fs.* = merk.io.RealFs.init(control_dir);

    const repo = Repository.open(ctx.alloc, real_fs.fs(), ctx.repo_root) catch |err| switch (err) {
        error.NotARepository => {
            std.debug.print("error: not a merk repository (.merk exists but has no Focus yet)\n", .{});
            return err;
        },
        error.DetachedFocus => {
            std.debug.print("error: Focus is detached; 'add' needs a track checked out\n", .{});
            return err;
        },
        else => return err,
    };

    return .{ .repo = repo, .real_fs = real_fs };
}

pub const command = Command{
    .name = "add",
    .description = "Stage paths in the index.",
    .usage = "<path>...",
    .run = run,
};
