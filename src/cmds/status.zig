const std = @import("std");
const merkle = @import("merkle");

const repo_context = @import("repo_context.zig");
const errors_mod = @import("../cli/errors.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    _ = inv;

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const result = opened.repo.status() catch |err| return errors_mod.report(ctx, err);
    defer merkle.freeChanges(ctx.alloc, result.staged);
    defer ctx.alloc.free(result.unstaged);

    if (result.staged.len == 0 and result.unstaged.len == 0) {
        try ctx.out.writeAll(
            \\Repository
            \\
            \\No pending snapshot.
            \\Working tree is clean.
            \\
        );
        return;
    }

    try ctx.out.writeAll(
        \\Repository
        \\
    );

    if (result.staged.len > 0) {
        try ctx.out.print("Staged for next commit ({d} path{s})\n\n", .{
            result.staged.len,
            if (result.staged.len == 1) "" else "s",
        });
    }

    var printed_any = result.staged.len > 0;

    inline for (.{
        .modified,
        .deleted,
    }) |wanted_state| {
        var header_printed = false;

        for (result.unstaged) |entry| {
            if (entry.state != wanted_state)
                continue;

            if (!header_printed) {
                header_printed = true;
                printed_any = true;

                const header = switch (wanted_state) {
                    .modified => "Modified",
                    .deleted => "Deleted",
                    else => unreachable,
                };

                try ctx.out.print("{s}\n", .{header});
            }

            try ctx.out.print("  {s}\n", .{entry.path});
        }

        if (header_printed)
            try ctx.out.writeByte('\n');
    }

    if (!printed_any) {
        try ctx.out.writeAll(
            \\No pending snapshot changes.
            \\
        );
    }
}

pub const command = Command{
    .name = "status",
    .description = "Show the repository status.",
    .usage = "",
    .category = .snapshot,
    .flags = &.{},
    .run = run,
};
