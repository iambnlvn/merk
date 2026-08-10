const std = @import("std");
const storage = @import("storage");

const cli = @import("../cli/command.zig");
const cli_errors = @import("../cli/errors.zig");
const repo_mod = @import("../core/repo/repo.zig");

const Command = cli.Command;
const Context = cli.Context;
const Invocation = cli.Invocation;

const InitOptions = repo_mod.InitOptions;
const InitResult = repo_mod.InitResult;
const Repository = repo_mod.Repository;

const OsFs = storage.OsFs;

const ParsedArgs = struct {
    target_dir: []const u8,
    quiet: bool,
    force: bool,
};

fn parseOptions(inv: *Invocation) ParsedArgs {
    return .{
        .target_dir = if (inv.positional.items.len > 0) inv.positional.items[0] else ".",
        .quiet = inv.flags.boolean("quiet"),
        .force = inv.flags.boolean("force"),
    };
}

pub fn run(ctx: Context, inv: *Invocation) !void {
    const opts = parseOptions(inv);

    var control_dir = try ensureControlDir(inv.alloc, opts.target_dir);
    defer control_dir.close();

    var os_fs = OsFs.init(control_dir);

    const result = Repository.init(
        inv.alloc,
        os_fs.fs(),
        opts.target_dir,
        .{ .force = opts.force },
    ) catch |err| {
        if (err == error.AlreadyInitialized) {
            _ = ctx.err.writeAll(
                \\error: repository already initialized
                \\hint: use --force to reinitialize it
                \\
            ) catch {};

            // Bubble up SilentExit to avoid generic double-logging
            return cli_errors.CliError.SilentExit;
        }
        return cli_errors.report(ctx, err);
    };

    defer result.repository.deinit();

    if (!opts.quiet) {
        try printSuccess(ctx, inv.alloc, opts.target_dir, result.action);
    }
}

fn ensureControlDir(alloc: std.mem.Allocator, target_dir: []const u8) !std.fs.Dir {
    const control_dir_path = try std.fs.path.join(alloc, &.{ target_dir, ".merk" });
    defer alloc.free(control_dir_path);

    std.fs.cwd().makePath(control_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // expected when --force is used
        else => return err,
    };

    return std.fs.cwd().openDir(control_dir_path, .{});
}

fn printSuccess(
    ctx: Context,
    alloc: std.mem.Allocator,
    target_dir: []const u8,
    action: InitResult.Action,
) !void {
    const target_abs = std.fs.cwd().realpathAlloc(alloc, target_dir) catch null;
    defer if (target_abs) |p| alloc.free(p);
    const display_path = target_abs orelse target_dir;

    switch (action) {
        .initialized => {
            try ctx.out.print("Initialized merk repository in {s}\n\n", .{display_path});
        },
        .reinitialized => {
            try ctx.out.print("Reinitialized merk repository in {s}\n", .{display_path});
            try ctx.out.writeAll("The existing repository state was reset.\n\n");
        },
    }

    try ctx.out.writeAll("Next steps:\n");

    const is_current_dir =
        std.mem.eql(u8, target_dir, ".") or
        std.mem.eql(u8, target_dir, "./");

    if (!is_current_dir) {
        try ctx.out.print("  cd {s}\n", .{target_dir});
    }

    try ctx.out.writeAll(
        \\  merk stage --all
        \\  merk commit -m "Initial commit"
        \\
    );
}

pub const command = Command{
    .name = "init",
    .description = "Initialize a new merk repository.",
    .usage = "[directory]",
    .category = .repository,
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
