const std = @import("std");
const merk = @import("merk");

const repository_mod = @import("../core/repository.zig");
const Repository = repository_mod.Repository;

const cli = @import("../cli/command.zig");
const Context = cli.Context;

/// Everything a repo-touching command needs to open, use, and tear down
/// a `Repository` — bundled behind one call instead of two loosely
/// coupled pieces (`real_fs` and an opened-repo handle) a caller had to
/// declare separately and wire together by hand.
///
/// `Repository` embeds the `io.FileSystem` interface built from
/// `real_fs.fs()` — `{ ptr, vtable }` pointing back at `real_fs` itself —
/// and holds onto it for as long as `Repository` lives. `real_fs` is
/// therefore heap-allocated here (not stored inline in `Opened`), so the
/// `Opened` value itself is free to be returned, copied, or moved without
/// invalidating that pointer.
///
/// Usage (matches every command in cmds/):
///
///     const opened = try repo_context.open(ctx);
///     defer opened.deinit(ctx.alloc);
///     try opened.repo.add(inv.positional.items);
pub const Opened = struct {
    real_fs: *merk.io.RealFs,
    repo: *Repository,

    pub fn deinit(self: Opened, alloc: std.mem.Allocator) void {
        self.repo.deinit();
        alloc.destroy(self.real_fs);
    }
};

/// Opens `<repo_root>/.merk` and hands it to `Repository.open`.
///
/// NOTE: doesn't close the `.merk` dir handle — `Repository`/`real_fs`
/// hold it for the command's whole run, and the process exits shortly
/// after, so the OS reclaims the fd. Worth revisiting if commands ever
/// start opening more than one repo per process.
pub fn open(ctx: Context) !Opened {
    var root_dir = try std.fs.cwd().openDir(ctx.repo_root, .{});
    defer root_dir.close();

    const control_dir = root_dir.openDir(".merk", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            ctx.err.print("error: not a merk repository (no .merk directory found)\n", .{}) catch {};
            return err;
        },
        else => return err,
    };

    const real_fs = try ctx.alloc.create(merk.io.RealFs);
    errdefer ctx.alloc.destroy(real_fs);
    real_fs.* = merk.io.RealFs.init(control_dir);

    const repo = Repository.open(ctx.alloc, real_fs.fs(), ctx.repo_root) catch |err| switch (err) {
        error.NotARepository => {
            ctx.err.print("error: not a merk repository (.merk exists but has no Focus yet)\n", .{}) catch {};
            return err;
        },
        error.DetachedFocus => {
            ctx.err.print("error: Focus is detached; this command needs a track checked out\n", .{}) catch {};
            return err;
        },
        else => return err,
    };
    errdefer repo.deinit();

    return .{ .real_fs = real_fs, .repo = repo };
}
