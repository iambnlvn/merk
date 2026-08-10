const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("storage");

const repository_mod = @import("../core/repository.zig");
const Repository = repository_mod.Repository;

const cli = @import("../cli/command.zig");
const Context = cli.Context;
const OsFs = storage.OsFs;
/// Everything a repo-touching command needs to open, use, and tear down
/// a `Repository` — bundled behind one call instead of two loosely
/// coupled pieces (`real_fs` and an opened-repo handle) a caller had to
/// declare separately and wire together by hand.
///
/// `Repository` embeds the `storage.FileSystem` interface built from
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
    real_fs: *OsFs,
    repo: *Repository,
    /// Absolute path of the directory containing `.merk`, as found by
    /// `discoverRoot`. Owned by `Opened`; may differ from `ctx.repo_root`
    /// when the command was run from a subdirectory of the repo.
    root: []const u8,

    pub fn deinit(self: Opened, alloc: Allocator) void {
        self.repo.deinit();
        alloc.destroy(self.real_fs);
        alloc.free(self.root);
    }
};

pub const DiscoverError = error{NotARepository} || Allocator.Error;

pub fn discoverRoot(alloc: Allocator, start_dir: []const u8) DiscoverError![]const u8 {
    var current = std.fs.cwd().realpathAlloc(alloc, start_dir) catch return error.NotARepository;
    errdefer alloc.free(current);

    while (true) {
        const has_control_dir = blk: {
            var dir = std.fs.cwd().openDir(current, .{}) catch break :blk false;
            defer dir.close();
            dir.access(".merk", .{}) catch break :blk false;
            break :blk true;
        };
        if (has_control_dir) return current;

        const parent = std.fs.path.dirname(current) orelse return error.NotARepository;
        if (std.mem.eql(u8, parent, current)) return error.NotARepository; // hit filesystem root

        const parent_dup = try alloc.dupe(u8, parent);
        alloc.free(current);
        current = parent_dup;
    }
}

/// NOTE: doesn't close the `.merk` dir handle — `Repository`/`real_fs`
/// hold it for the command's whole run, and the process exits shortly
/// after, so the OS reclaims the fd
pub fn open(ctx: Context) !Opened {
    const root = discoverRoot(ctx.alloc, ctx.repo_root) catch |err| switch (err) {
        error.NotARepository => {
            ctx.err.print("error: not a merk repository (or any parent directory up to /)\n", .{}) catch {};
            return err;
        },
        error.OutOfMemory => return err,
    };
    errdefer ctx.alloc.free(root);

    var root_dir = try std.fs.cwd().openDir(root, .{});
    defer root_dir.close();

    // discoverRoot already confirmed .merk exists, but re-open here rather
    // than threading a handle through — it stat'd via access(), not opened.
    const control_dir = root_dir.openDir(".merk", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            ctx.err.print("error: not a merk repository (no .merk directory found)\n", .{}) catch {};
            return err;
        },
        else => return err,
    };

    const real_fs = try ctx.alloc.create(OsFs);
    errdefer ctx.alloc.destroy(real_fs);
    real_fs.* = OsFs.init(control_dir);

    const repo = Repository.open(ctx.alloc, real_fs.fs(), root) catch |err| switch (err) {
        error.NotARepository => {
            ctx.err.print("error: not a merk repository (.merk exists but has no Current yet)\n", .{}) catch {};
            return err;
        },
        error.DetachedCurrent => {
            ctx.err.print("error: Current is detached; this command needs a track checked out\n", .{}) catch {};
            return err;
        },
        else => return err,
    };
    errdefer repo.deinit();

    return .{ .real_fs = real_fs, .repo = repo, .root = root };
}
