const std = @import("std");
const storage = @import("storage");

const cli = @import("../cli/command.zig");
const repo_context = @import("repo_context.zig");
const config_mod = @import("../core/config/config.zig");

const Command = cli.Command;
const Context = cli.Context;
const Invocation = cli.Invocation;

const Setting = struct {
    name: []const u8,
    key: []const u8,
    description: []const u8,
    boolean: bool = false,
};

const settings = [_]Setting{
    .{ .name = "name", .key = "identity.name", .description = "default author name" },
    .{ .name = "email", .key = "identity.email", .description = "default author email address" },
    .{ .name = "author-name", .key = "commit.author", .description = "override the default author name for commits" },
    .{ .name = "author-email", .key = "commit.author_email", .description = "override the default author email for commits" },
    .{ .name = "committer-name", .key = "commit.committer", .description = "default committer name" },
    .{ .name = "committer-email", .key = "commit.committer_email", .description = "default committer email address" },
    .{ .name = "intent", .key = "commit.intent", .description = "default commit intent (for example, feature or fix)" },
    .{ .name = "no-body-trailers", .key = "commit.no_body_trailers", .description = "do not parse trailers from commit bodies", .boolean = true },
    .{ .name = "channel", .key = "workspace.channel", .description = "default workspace channel" },
    .{ .name = "ignore", .key = "workspace.ignore", .description = "ignore-file path" },
    .{ .name = "sign-history", .key = "history.sign", .description = "sign history entries", .boolean = true },
};

pub fn run(ctx: Context, inv: *Invocation) !void {
    if (inv.positional.items.len == 1 and std.mem.eql(u8, inv.positional.items[0], "help")) {
        return printSettings(ctx);
    }

    if (inv.positional.items.len != 1 and inv.positional.items.len != 2) {
        try ctx.err.writeAll("error: expected a setting, optionally followed by a value\n");
        command.printHelp(ctx.err) catch {};
        return error.InvalidArguments;
    }

    const setting = findSetting(inv.positional.items[0]) orelse {
        try ctx.err.print("error: unknown setting '{s}' (run merk config help)\n", .{inv.positional.items[0]});
        return error.UnknownConfigSetting;
    };

    const global = inv.flags.boolean("global");
    if (inv.positional.items.len == 1) {
        return printValue(ctx, inv.alloc, setting.key, global);
    }

    const value = inv.positional.items[1];
    if (std.mem.indexOfAny(u8, value, "\n\r\"") != null) {
        try ctx.err.writeAll("error: configuration values cannot contain newlines or double quotes\n");
        return error.InvalidConfigValue;
    }
    if (setting.boolean and !isBoolean(value)) {
        try ctx.err.print("error: {s} must be true or false\n", .{setting.name});
        return error.InvalidConfigValue;
    }

    if (global) {
        const path = try config_mod.defaultUserConfigPath(inv.alloc) orelse {
            try ctx.err.writeAll("error: cannot determine the user configuration directory\n");
            return error.NoUserConfigDirectory;
        };
        defer inv.alloc.free(path);
        try appendAbsolute(inv.alloc, path, setting.key, value);
        try ctx.out.print("Set {s} in {s}\n", .{ setting.name, path });
    } else {
        const opened = try repo_context.open(ctx);
        defer opened.deinit(ctx.alloc);
        try appendRepo(inv.alloc, opened.repo.fs, setting.key, value);
        try ctx.out.print("Set {s} in .merk/config/settings\n", .{setting.name});
    }
}

fn findSetting(name: []const u8) ?Setting {
    for (settings) |setting| {
        if (std.mem.eql(u8, name, setting.name)) return setting;
    }
    return null;
}

fn isBoolean(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false");
}

fn printSettings(ctx: Context) !void {
    try ctx.out.writeAll(
        \\usage: merk config [--global] <setting> [value]
        \\
        \\Set a value by providing it; omit the value to print the current setting.
        \\Repository settings are stored in .merk/config/settings. --global writes the user
        \\default at $XDG_CONFIG_HOME/merk/config (or ~/.config/merk/config).
        \\
        \\settings:
        \\
    );
    for (settings) |setting| {
        try ctx.out.print("  {s:<17} {s}", .{ setting.name, setting.description });
        if (setting.boolean) try ctx.out.writeAll(" (true or false)");
        try ctx.out.writeByte('\n');
    }
    try ctx.out.writeAll(
        \\
        \\examples:
        \\  merk config --global name "binor"
        \\  merk config --global email "binor@example.com"
        \\  merk config email
        \\
    );
}

fn printValue(ctx: Context, alloc: std.mem.Allocator, key: []const u8, global: bool) !void {
    if (global) {
        const path = try config_mod.defaultUserConfigPath(alloc) orelse return;
        defer alloc.free(path);

        var cfg = try config_mod.Config.load(alloc, path, null);
        defer cfg.deinit();
        if (cfg.get(key)) |value| try ctx.out.print("{s}\n", .{value});
        return;
    }

    const opened = try repo_context.open(ctx);
    defer opened.deinit(ctx.alloc);
    const user_path = try config_mod.defaultUserConfigPath(alloc);
    defer if (user_path) |path| alloc.free(path);
    var cfg = try config_mod.Config.load(alloc, user_path, opened.repo.fs);
    defer cfg.deinit();
    if (cfg.get(key)) |value| try ctx.out.print("{s}\n", .{value});
}

fn appendRepo(alloc: std.mem.Allocator, fs: storage.Vfs, key: []const u8, value: []const u8) !void {
    const old = try fs.readFile(alloc, config_mod.repository_settings_path);
    defer if (old) |bytes| alloc.free(bytes);
    const updated = try appendedLine(alloc, old orelse "", key, value);
    defer alloc.free(updated);
    try fs.writeFile(alloc, config_mod.repository_settings_path, updated);
}

fn appendAbsolute(alloc: std.mem.Allocator, path: []const u8, key: []const u8, value: []const u8) !void {
    const old = readAbsoluteIfExists(alloc, path) catch |err| return err;
    defer if (old) |bytes| alloc.free(bytes);
    const updated = try appendedLine(alloc, old orelse "", key, value);
    defer alloc.free(updated);

    if (std.fs.path.dirname(path)) |parent| try std.fs.cwd().makePath(parent);
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(updated);
}

fn readAbsoluteIfExists(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(alloc, 1024 * 1024);
}

fn appendedLine(alloc: std.mem.Allocator, existing: []const u8, key: []const u8, value: []const u8) ![]u8 {
    const separator: []const u8 = if (existing.len == 0 or existing[existing.len - 1] == '\n') "" else "\n";
    return std.fmt.allocPrint(alloc, "{s}{s}{s} \"{s}\"\n", .{ existing, separator, key, value });
}

pub const command = Command{
    .name = "config",
    .description = "Read or set configuration. Omit the value to print a setting.\n\n" ++
        "settings:\n" ++
        "  name, email                  default author identity\n" ++
        "  author-name, author-email    commit author overrides\n" ++
        "  committer-name, committer-email\n" ++
        "                              default committer identity\n" ++
        "  intent                       default commit intent\n" ++
        "  no-body-trailers             true or false\n" ++
        "  channel, ignore, sign-history\n\n" ++
        "Run merk config help for descriptions and examples.",
    .usage = "[--global] <setting> [value]",
    .category = .repository,
    .flags = &.{.{
        .long = "global",
        .kind = .boolean,
        .help = "use the user config file (~/.config/merk/config)",
    }},
    .run = run,
};

test "appendedLine keeps existing configuration and makes the new value win" {
    const line = try appendedLine(std.testing.allocator, "identity.email \"old@test.com\"\n", "identity.email", "new@test.com");
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("identity.email \"old@test.com\"\nidentity.email \"new@test.com\"\n", line);
}

test "short setting names map to their stored keys" {
    try std.testing.expectEqualStrings("identity.email", findSetting("email").?.key);
    try std.testing.expect(findSetting("identity.email") == null);
    try std.testing.expect(findSetting("no-body-trailers").?.boolean);
}
