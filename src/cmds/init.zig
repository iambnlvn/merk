const std = @import("std");
const merk = @import("merk");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

const repository_mod = @import("../core/repository.zig");
const Repository = repository_mod.Repository;

pub fn run(ctx: Context, inv: *Invocation) !void {
    // 1. Resolve the target directory
    const target_dir = if (inv.positional.items.len > 0)
        inv.positional.items[0]
    else
        ctx.repo_root;

    const quiet = inv.flags.boolean("quiet");

    // 2. Create the control directory
    // repository.zig notes: "Creating that directory and rooting `fs` there is the caller's job"
    const control_dir_path = try std.fs.path.join(inv.alloc, &.{ target_dir, ".merk" });
    defer inv.alloc.free(control_dir_path);

    std.fs.cwd().makePath(control_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var control_dir = try std.fs.cwd().openDir(control_dir_path, .{});
    defer control_dir.close();

    // 3. Initialize the RealFs rooted at the new control directory
    var real_fs = merk.io.RealFs.init(control_dir);

    // 4. Delegate to Repository.init to handle the internal scaffolding
    // This will create the `Store`, `PageStore`, `Index`, and set the Focus to "main".
    var repo = try Repository.init(inv.alloc, real_fs.fs(), target_dir);
    defer repo.deinit();

    if (!quiet) {
        std.debug.print("Initialized empty merk repository in {s}\n", .{target_dir});
    }
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
            .help = "Only print error and warning messages",
        },
    },
    .run = run,
};
