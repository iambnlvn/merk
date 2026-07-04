const std = @import("std");
const nodus = @import("nodus");

const cli = @import("../cli/command.zig");
const flags = @import("../cli/flags.zig");
const Command = cli.Command;
const Invocation = cli.Invocation;

const commit_mod = nodus.commit;
const Intent = commit_mod.commitMetadata.Intent;
const TrailerInfo = commit_mod.message.TrailerInfo;
const TimestampedIdentityInfo = commit_mod.identity.TimestampedIdentityInfo;

const refs = nodus.refs;

const context = @import("../cli/context.zig");
const Context = context.Context;

/// Parse a Unix-ms timestamp from either:
///   - a plain integer string ("1700000000000")
///   - an ISO-8601 date "YYYY-MM-DD" (interpreted as UTC midnight)
/// Returns null on bad input so the caller can emit a clean error.
fn parseTimestamp(raw: []const u8) ?i64 {
    // Plain integer (milliseconds)
    if (std.fmt.parseInt(i64, raw, 10)) |ms| return ms else |_| {}

    // ISO-8601 date YYYY-MM-DD
    if (raw.len == 10 and raw[4] == '-' and raw[7] == '-') {
        const year = std.fmt.parseInt(u16, raw[0..4], 10) catch return null;
        const month = std.fmt.parseInt(u8, raw[5..7], 10) catch return null;
        const day = std.fmt.parseInt(u8, raw[8..10], 10) catch return null;
        if (month < 1 or month > 12 or day < 1 or day > 31) return null;

        // Days since Unix epoch to start of year (simplified, ignoring leap seconds)
        var days: i64 = 0;
        var y: u16 = 1970;
        while (y < year) : (y += 1) {
            const leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
            days += if (leap) 366 else 365;
        }
        const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
        for (month_days[0 .. month - 1], 1..) |d, m| {
            days += d;
            if (m == 2 and leap) days += 1;
        }
        days += day - 1;
        return days * 86_400_000; // ms per day
    }

    return null;
}

/// Scan the body for git-style trailers at the tail.
///
/// Trailers are lines of the form `key: value` after a blank-line separator.
/// The block must be contiguous and at the end of the body — any non-trailer
/// line in the candidate block terminates the scan.
///
/// Parsed trailers are appended to `out`; the function returns the body with
/// the trailer block (and the blank line above it) stripped.
fn extractBodyTrailers(
    alloc: std.mem.Allocator,
    body: []const u8,
    out: *std.ArrayListUnmanaged(TrailerInfo),
) ![]const u8 {
    // Collect lines in reverse so we can find the contiguous trailer tail.
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(alloc);

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| try lines.append(alloc, line);

    // Walk backwards, collecting trailer lines until we hit a blank or
    // a line that doesn't match the `key: value` pattern.
    var trailer_start: usize = lines.items.len; // index of first trailer line

    var i: usize = lines.items.len;
    while (i > 0) {
        i -= 1;
        const line = std.mem.trimRight(u8, lines.items[i], " \t\r");

        // A blank line ends the backwards scan; everything below it is the
        // trailer block (if any were found).
        if (line.len == 0) break;

        // Must match `key: value` — key is non-empty, no spaces/colons, then ": "
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse break;
        if (colon == 0) break; // empty key
        const key = line[0..colon];
        const rest = line[colon + 1 ..];
        if (rest.len < 2 or rest[0] != ' ') break; // need ": "

        // Validate key chars (same rules as TrailerInfo.validate)
        var key_ok = true;
        for (key) |c| {
            if (c < 0x21 or c > 0x7E or c == ':') {
                key_ok = false;
                break;
            }
        }
        if (!key_ok) break;

        trailer_start = i;
    }

    if (trailer_start == lines.items.len) return body; // nothing found

    // Append trailers in forward order (they were scanned backwards).
    for (lines.items[trailer_start..]) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':').?;
        const value = std.mem.trim(u8, trimmed[colon + 2 ..], " \t");
        try out.append(alloc, .{ .key = trimmed[0..colon], .value = value });
    }

    // Strip the trailer block and the blank line above it from the body.
    // Find the last non-trailer, non-blank line.
    var end = trailer_start;
    while (end > 0 and std.mem.trimRight(u8, lines.items[end - 1], " \t\r").len == 0) {
        end -= 1;
    }

    if (end == 0) return "";

    // Re-join the kept lines.
    var kept = std.ArrayListUnmanaged(u8){};
    errdefer kept.deinit(alloc);
    for (lines.items[0..end], 0..) |line, idx| {
        if (idx > 0) try kept.append(alloc, '\n');
        try kept.appendSlice(alloc, line);
    }
    return kept.toOwnedSlice(alloc);
}

pub fn run(ctx: Context, inv: *Invocation) !void {
    const title_raw = inv.flags.string("message") orelse {
        std.debug.print("error: commit message is required (-m <message>)\n", .{});
        command.printHelpToStderr();
        return error.MissingMessage;
    };

    if (std.mem.trim(u8, title_raw, " \t").len == 0) {
        std.debug.print("error: commit message must not be empty\n", .{});
        return error.EmptyMessage;
    }

    const intent_raw = inv.flags.string("intent") orelse "feature";
    const intent = flags.parseEnum(Intent, intent_raw) orelse {
        std.debug.print(
            "error: unknown intent '{s}'. valid values: " ++
                "feature, fix, refactor, docs, test, performance, " ++
                "security, build, ci, release, chore\n",
            .{intent_raw},
        );
        return error.UnknownIntent;
    };

    const author_name = inv.flags.string("author") orelse
        std.posix.getenv("NODUS_AUTHOR_NAME") orelse
        std.posix.getenv("USER") orelse
        "unknown";

    const author_email = inv.flags.string("author-email") orelse
        std.posix.getenv("NODUS_AUTHOR_EMAIL") orelse
        "unknown@local";

    const author_date: i64 = blk: {
        const raw = inv.flags.string("date") orelse inv.flags.string("author-date") orelse break :blk 0;
        break :blk parseTimestamp(raw) orelse {
            std.debug.print(
                "error: cannot parse date '{s}' — use Unix-ms or YYYY-MM-DD\n",
                .{raw},
            );
            return error.BadDate;
        };
    };

    const committer: ?TimestampedIdentityInfo = blk: {
        const cn = inv.flags.string("committer") orelse inv.flags.string("committer-name");
        const ce = inv.flags.string("committer-email");
        const cd_raw = inv.flags.string("committer-date");

        // If none of the committer flags are present, leave as null (= mirrors author).
        if (cn == null and ce == null and cd_raw == null) break :blk null;

        const committer_date: i64 = if (cd_raw) |raw|
            parseTimestamp(raw) orelse {
                std.debug.print(
                    "error: cannot parse committer-date '{s}' — use Unix-ms or YYYY-MM-DD\n",
                    .{raw},
                );
                return error.BadDate;
            }
        else
            0;

        break :blk TimestampedIdentityInfo{
            .name = cn orelse author_name,
            .email = ce orelse author_email,
            .timestamp_ms = committer_date,
        };
    };

    const label_raw = inv.flags.string("label");

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

    var trailer_list = std.ArrayListUnmanaged(TrailerInfo){};
    defer trailer_list.deinit(inv.alloc);

    //  body-embedded trailers (parsed first so --trailer flags can override/append).
    const body_raw = inv.flags.string("body") orelse "";
    const skip_body_trailers = inv.flags.boolean("no-body-trailers");

    const body: []const u8 = if (!skip_body_trailers)
        try extractBodyTrailers(inv.alloc, body_raw, &trailer_list)
    else
        body_raw;

    const body_was_rewritten = body.ptr != body_raw.ptr;
    defer if (body_was_rewritten) inv.alloc.free(body);

    // explicit --trailer key=value[,key=value] flags (append after body trailers).
    // Explicit --trailer flags.
    // Preferred:
    //   --trailer reviewed-by=Alice
    //   --trailer closes=#42
    //
    // Also supports comma-separated values for convenience:
    //   --trailer reviewed-by=Alice,closes=#42
    var trailer_it = inv.flags.getMulti("trailer");

    while (trailer_it.next()) |raw| {
        var csv = std.mem.splitScalar(u8, raw, ',');

        while (csv.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \t");
            if (trimmed.len == 0) continue;

            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
                std.debug.print(
                    "error: trailer '{s}' must be in key=value form\n",
                    .{trimmed},
                );
                return error.BadTrailer;
            };

            const key = std.mem.trim(u8, trimmed[0..eq], " \t");
            const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

            const trailer = TrailerInfo{
                .key = key,
                .value = value,
            };

            trailer.validate() catch |err| {
                std.debug.print(
                    "error: invalid trailer '{s}': {s}\n",
                    .{ trimmed, @errorName(err) },
                );
                return error.BadTrailer;
            };

            try trailer_list.append(inv.alloc, trailer);
        }
    }

    var store = try nodus.object.Store.init(inv.alloc, ctx.repo_root);
    defer store.deinit();

    var index = try nodus.index.Index.init(inv.alloc, ctx.repo_root);
    defer index.deinit();

    try index.load();

    if (index.entries.items.len == 0) {
        std.debug.print("error: nothing to commit (index is empty — run `nodus add <path>` first)\n", .{});
        return error.NothingToCommit;
    }

    var nodus_dir = try std.fs.cwd().openDir(".nodus", .{});
    defer nodus_dir.close();

    const maybe_head = try refs.resolveHead(inv.alloc, nodus_dir);
    const parents: []const nodus.hash.Hash = if (maybe_head) |h| &.{h} else &.{};

    try index.save();
    const index_root = index.index_root;

    if (maybe_head) |head_hash| {
        var parent_c = try commit_mod.read(inv.alloc, &store, head_hash);
        defer parent_c.deinit(inv.alloc);

        if (std.mem.eql(u8, &parent_c.snapshot.tree, &index_root)) {
            std.debug.print(
                "error: nothing to commit — staged tree is identical to HEAD (stage changes with `nodus add` first)\n",
                .{},
            );
            return error.NothingToCommit;
        }
    }

    const commit_hash = try commit_mod.write(
        inv.alloc,
        &store,
        .{
            .snapshot = .{
                .tree = index_root,
                .parents = parents,
            },
            .identity = .{
                .author = .{
                    .name = author_name,
                    .email = author_email,
                    .timestamp_ms = author_date,
                },
                .committer = committer,
            },
            .metadata = .{
                .timestamp_ms = 0,
                .intent = intent,
                .labels = label_list.items,
            },
            .message = .{
                .title = title_raw,
                .body = body,
                .trailers = trailer_list.items,
            },
        },
    );
    const branch = try refs.headBranch(inv.alloc, nodus_dir) orelse blk: {
        try refs.writeHeadRef(nodus_dir, "main");
        break :blk try inv.alloc.dupe(u8, "main");
    };
    defer inv.alloc.free(branch);

    try refs.updateRef(inv.alloc, nodus_dir, branch, commit_hash);
    const short = nodus.hash.shortHex(commit_hash);

    std.debug.print("✓ Commit created\n\n", .{});

    std.debug.print("  Hash      {s}\n", .{short});
    std.debug.print("  Branch    {s}\n", .{branch});
    if (parents.len == 0) {
        std.debug.print("  Type      root commit\n", .{});
    }
    std.debug.print("  Intent    {s}\n", .{@tagName(intent)});

    std.debug.print("\n  Message\n", .{});
    std.debug.print("    {s}\n", .{title_raw});

    if (body.len > 0) {
        std.debug.print("\n  Description\n", .{});
        std.debug.print("    {s}\n", .{body});
    }

    std.debug.print("\n  Author\n", .{});
    std.debug.print("    {s} <{s}>\n", .{ author_name, author_email });

    if (committer) |c| {
        std.debug.print("\n  Committer\n", .{});
        std.debug.print("    {s} <{s}>\n", .{ c.name, c.email });
    }

    if (label_list.items.len > 0) {
        std.debug.print("\n  Labels\n", .{});
        for (label_list.items) |label| {
            std.debug.print("    • {s}\n", .{label});
        }
    }

    if (trailer_list.items.len > 0) {
        std.debug.print("\n  Trailers\n", .{});
        for (trailer_list.items) |t| {
            std.debug.print("    {s}: {s}\n", .{ t.key, t.value });
        }
    }

    std.debug.print("\n  Changes\n", .{});
    std.debug.print("    {} staged file{s}\n", .{
        index.entries.items.len,
        if (index.entries.items.len == 1) "" else "s",
    });
}

pub const command = Command{
    .name = "commit",
    .description = "Record staged changes as a new commit.",
    .usage = "[-m <message>] [options] [labels...]",
    .flags = &.{
        // message
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
            .help = "extended description; git-style 'key: value' trailers at the tail are parsed automatically",
        },
        .{
            .long = "no-body-trailers",
            .kind = .boolean,
            .help = "treat the body as plain text; skip trailer extraction",
        },
        .{
            .long = "trailer",
            .kind = .value,
            .value_name = "key=value",
            .help = "append a trailer (repeat for multiple, e.g. --trailer reviewed-by=Alice --trailer closes=#42)",
        },
        // classification
        .{
            .short = 'i',
            .long = "intent",
            .kind = .value,
            .value_name = "intent",
            .help = "feature|fix|refactor|docs|test|performance|security|build|ci|release|chore  (default: feature)",
        },
        .{
            .short = 'l',
            .long = "label",
            .kind = .value,
            .value_name = "label[,label]",
            .help = "comma-separated scope labels; positional args also accepted",
        },
        // author
        .{
            .long = "author",
            .kind = .value,
            .value_name = "name",
            .help = "author name  ($NODUS_AUTHOR_NAME / $USER fallback)",
        },
        .{
            .long = "author-email",
            .kind = .value,
            .value_name = "addr",
            .help = "author email  ($NODUS_AUTHOR_EMAIL fallback)",
        },
        .{
            .long = "author-date",
            .kind = .value,
            .value_name = "date",
            .help = "author timestamp: Unix-ms or YYYY-MM-DD  (default: now)",
        },
        .{
            .long = "date",
            .kind = .value,
            .value_name = "date",
            .help = "alias for --author-date",
        },
        // committer (optional; defaults to author)
        .{
            .long = "committer",
            .kind = .value,
            .value_name = "name",
            .help = "committer name  (default: same as author)",
        },
        .{
            .long = "committer-name",
            .kind = .value,
            .value_name = "name",
            .help = "alias for --committer",
        },
        .{
            .long = "committer-email",
            .kind = .value,
            .value_name = "addr",
            .help = "committer email  (default: same as author)",
        },
        .{
            .long = "committer-date",
            .kind = .value,
            .value_name = "date",
            .help = "committer timestamp: Unix-ms or YYYY-MM-DD  (default: same as author)",
        },
    },
    .run = run,
};
