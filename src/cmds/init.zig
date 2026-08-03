const std = @import("std");
const merk = @import("merk");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

const repository_mod = @import("../core/repository.zig");
const Repository = repository_mod.Repository;

pub fn run(ctx: Context, inv: *Invocation) !void {
    const target_dir = if (inv.positional.items.len > 0)
        inv.positional.items[0]
    else
        ".";

    const quiet = inv.flags.boolean("quiet");
    const force = inv.flags.boolean("force");

    const control_dir_path = try std.fs.path.join(inv.alloc, &.{ target_dir, ".merk" });
    defer inv.alloc.free(control_dir_path);

    const already_exists = if (std.fs.cwd().access(control_dir_path, .{})) |_| true else |_| false;

    if (already_exists and !force) {
        try ctx.out.print(
            \\Repository already exists in '{s}'.
            \\Use --force to reinitialize and overwrite.
            \\
        , .{target_dir});
        return error.RepositoryAlreadyExists;
    }

    std.fs.cwd().makePath(control_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Expected when --force is used
        else => return err,
    };

    const target_absolute_path: []const u8 = std.fs.cwd().realpathAlloc(inv.alloc, target_dir) catch target_dir;
    defer if (target_absolute_path.ptr != target_dir.ptr) inv.alloc.free(target_absolute_path);

    var control_dir = try std.fs.cwd().openDir(control_dir_path, .{});
    defer control_dir.close();

    var real_fs = merk.io.RealFs.init(control_dir);

    var repo = try Repository.init(inv.alloc, real_fs.fs(), target_dir);
    defer repo.deinit();

    if (quiet) return;

    const action_verb = if (already_exists) "Reinitialized existing" else "Initialized empty";
    const is_current_dir = std.mem.eql(u8, target_dir, ".") or std.mem.eql(u8, target_dir, "./");

    try ctx.out.print("{s} merk repository in {s}\n\n", .{ action_verb, target_absolute_path });

    try ctx.out.writeAll("Next steps:\n");
    if (!is_current_dir) {
        try ctx.out.print("  cd {s}\n", .{target_dir});
    }

    try ctx.out.writeAll(
        \\  merk snapshot --all
        \\  merk commit -m "Initial commit"
        \\
    );
}

pub const command = Command{
    .name = "init",
    .description = "Initialize a new merk repository.",
    .usage = "[directory]",
    .flags = &.{
        .{
            .short = 'q',
            .long = "quiet",
            .kind = .boolean,
            .help = "Only print errors and warnings.",
        },
        .{
            .short = 'f',
            .long = "force",
            .kind = .boolean,
            .help = "Force reinitialization of an existing repository.",
        },
    },
    .run = run,
};
