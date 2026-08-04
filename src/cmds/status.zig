const std = @import("std");
const merk = @import("merk");

const repo_context = @import("repo_context.zig");

const cli = @import("../cli/command.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;
const Context = cli.Context;

pub fn run(ctx: Context, inv: *Invocation) !void {
    _ = inv;

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);

    const index = &opened.repo.index;

    if (index.entries.items.len == 0) {
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

    var printed_any = false;

    inline for (.{
        .modified,
        .deleted,
    }) |wanted_state| {
        var header_printed = false;

        for (index.entries.items) |entry| {
            const state = try index.stateOf(opened.repo.root, entry);

            if (state != wanted_state)
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
    .flags = &.{},
    .run = run,
};
