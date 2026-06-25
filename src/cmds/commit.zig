const std = @import("std");
const nodus = @import("nodus");

const cli = @import("../cli/command.zig");
const flags = @import("../cli/flags.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;

const commit_mod = nodus.commit;
const CommitInfo = commit_mod.CommitInfo;
const refs = nodus.refs;

const CommitMetadataInfo = commit_mod.CommitMetadataInfo;
const Intent = commit_mod.commitMetadata.Intent;

const repo_root = ".";

pub fn run(inv: *Invocation) !void {
    const title_raw = inv.flags.string("message") orelse {
        std.debug.print("error: commit message is required (-m <message>)\n", .{});
        command.printHelpToStderr();
        return error.MissingMessage;
    };

    if (std.mem.trim(u8, title_raw, " \t").len == 0) {
        std.debug.print("error: commit message must not be empty\n", .{});
        return error.EmptyMessage;
    }

    const body = inv.flags.string("body") orelse "";

    const intent_raw = inv.flags.string("intent") orelse "feature";
    const intent = flags.parseEnum(Intent, intent_raw) orelse {
        std.debug.print(
            "error: unknown intent '{s}'. valid values: feature, fix, refactor, chore, docs, test, perf, style, ci\n",
            .{intent_raw},
        );
        return error.UnknownIntent;
    };

    const label_raw = inv.flags.string("label");

    var store = try nodus.object.Store.init(inv.alloc, repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(inv.alloc, repo_root);
    defer index.deinit();

    try index.load();

    if (index.entries.items.len == 0) {
        std.debug.print("error: nothing to commit (index is empty — run `nodus add <path>` first)\n", .{});
        return error.NothingToCommit;
    }

    const nodus_dir = try std.fs.cwd().openDir(".nodus", .{});

    const maybe_head = try refs.resolveHead(inv.alloc, nodus_dir);
    const parents: []const nodus.hash.Hash = if (maybe_head) |h|
        &.{h}
    else
        &.{};

    const author_name = inv.flags.string("author") orelse
        std.posix.getenv("NODUS_AUTHOR_NAME") orelse
        std.posix.getenv("USER") orelse
        "unknown";

    const author_email = inv.flags.string("email") orelse
        std.posix.getenv("NODUS_AUTHOR_EMAIL") orelse
        "unknown@local";

    var label_list = std.ArrayListUnmanaged([]const u8){};
    defer label_list.deinit(inv.alloc);

    if (label_raw) |l| {
        var it = std.mem.splitScalar(u8, l, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len > 0) try label_list.append(inv.alloc, trimmed);
        }
    }

    for (inv.positional.items) |pos| {
        try label_list.append(inv.alloc, pos);
    }

    const commit_hash = try commit_mod.buildAndWrite(
        inv.alloc,
        &store,
        &index,
        .{
            .snapshot = .{
                .tree = undefined, // overwritten by buildAndWrite
                .parents = parents,
            },
            .author = .{
                .name = author_name,
                .email = author_email,
            },
            .metadata = .{
                .timestamp_ms = 0, // 0 → auto wall-clock in write()
                .intent = intent,
                .labels = label_list.items,
            },
            .message = .{
                .title = title_raw,
                .body = body,
            },
        },
    );

    const branch = try refs.headBranch(inv.alloc, nodus_dir) orelse
        try inv.alloc.dupe(u8, "main");
    defer inv.alloc.free(branch);

    try refs.updateRef(inv.alloc, nodus_dir, branch, commit_hash);

    const short = nodus.hash.shortHex(commit_hash);
    const root_marker: []const u8 = if (parents.len == 0) " (root-commit)" else "";
    std.debug.print("[{s}{s}] {s}\n", .{ short, root_marker, title_raw });
    std.debug.print("  author : {s} <{s}>\n", .{ author_name, author_email });
    std.debug.print("  intent : {s}\n", .{@tagName(intent)});
    if (label_list.items.len > 0) {
        std.debug.print("  labels : ", .{});
        for (label_list.items, 0..) |l, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{l});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("  files  : {}\n", .{index.entries.items.len});
    std.debug.print("  files  : {}\n", .{index.entries.items});
}

pub const command = Command{
    .name = "commit",
    .description = "Record staged changes as a new commit.",
    .usage = "[-m <message>] [options] [labels...]",
    .flags = &.{
        .{
            .short = 'm',
            .long = "message",
            .kind = .value,
            .value_name = "msg",
            .help = "commit title (required)",
            .required = true,
        },
        .{
            .long = "body",
            .kind = .value,
            .value_name = "text",
            .help = "extended description",
        },
        .{
            .short = 'i',
            .long = "intent",
            .kind = .value,
            .value_name = "intent",
            .help = "feature|fix|refactor|chore|docs|test|perf|style|ci  (default: feature)",
        },
        .{
            .short = 'l',
            .long = "label",
            .kind = .value,
            .value_name = "label[,label]",
            .help = "comma-separated scope labels; positional args also accepted",
        },
        .{
            .long = "author",
            .kind = .value,
            .value_name = "name",
            .help = "override author name ($NODUS_AUTHOR_NAME / $USER fallback)",
        },
        .{
            .long = "email",
            .kind = .value,
            .value_name = "addr",
            .help = "override author email ($NODUS_AUTHOR_EMAIL fallback)",
        },
    },
    .run = run,
};
