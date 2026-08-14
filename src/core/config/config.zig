const std = @import("std");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const storage = @import("storage");
const Vfs = storage.Vfs;
const MemoryFs = storage.MemoryFs;

const config_format = @import("format.zig");
const ConfigFormat = config_format.ConfigFormat;

const schema = @import("schema.zig");
pub const Schema = schema.Schema;

pub const repository_settings_path = "config/settings";

pub const Config = struct {
    alloc: Allocator,
    cf: ConfigFormat,
    settings: Schema,

    pub fn deinit(self: *Config) void {
        self.cf.deinit(self.alloc);
    }

    pub fn load(
        alloc: Allocator,
        user_config_path: ?[]const u8,
        repo_fs: ?Vfs,
    ) !Config {
        var cf: ConfigFormat = .{};
        errdefer cf.deinit(alloc);

        if (user_config_path) |path| {
            if (try readAbsoluteFileIfExists(alloc, path)) |bytes| {
                defer alloc.free(bytes);
                try cf.mergeText(alloc, bytes);
            }
        }

        if (repo_fs) |fs| {
            if (try fs.readFile(alloc, repository_settings_path)) |bytes| {
                defer alloc.free(bytes);
                try cf.mergeText(alloc, bytes);
            }
        }

        const settings = try schema.reflect(Schema, &cf);

        return .{ .alloc = alloc, .cf = cf, .settings = settings };
    }

    pub fn get(self: *const Config, key: []const u8) ?[]const u8 {
        return self.cf.get(key);
    }
};

fn readAbsoluteFileIfExists(alloc: Allocator, path: []const u8) !?[]u8 {
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(alloc, 1024 * 1024);
}

pub fn defaultUserConfigPath(alloc: Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
        defer alloc.free(xdg);
        if (xdg.len > 0) return try std.fs.path.join(alloc, &.{ xdg, "merk", "config" });
    } else |_| {}

    if (std.process.getEnvVarOwned(alloc, "HOME")) |home| {
        defer alloc.free(home);
        if (home.len > 0) return try std.fs.path.join(alloc, &.{ home, ".config", "merk", "config" });
    } else |_| {}

    return null;
}

test "load with no files present returns an empty, valid config" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var cfg = try Config.load(alloc, null, mem_fs.fs());
    defer cfg.deinit();

    try testing.expect(cfg.settings.@"identity.name" == null);
    try testing.expect(cfg.settings.@"history.sign" == null);
}

test "repo-level config alone is readable" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    try mem_fs.fs().writeFile(alloc, repository_settings_path,
        \\identity.name "binor"
        \\identity.email "aa@example.com"
        \\workspace.channel "main"
        \\workspace.ignore ".merkignore"
        \\history.sign false
    );

    var cfg = try Config.load(alloc, null, mem_fs.fs());
    defer cfg.deinit();

    try testing.expectEqualStrings("binor", cfg.settings.@"identity.name".?);
    try testing.expectEqualStrings("aa@example.com", cfg.settings.@"identity.email".?);
    try testing.expectEqualStrings("main", cfg.settings.@"workspace.channel".?);
    try testing.expectEqualStrings(".merkignore", cfg.settings.@"workspace.ignore".?);
    try testing.expectEqual(false, cfg.settings.@"history.sign".?);
}

test "repo-level config overrides user-level config key by key" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var user_file = try tmp_dir.dir.createFile("user-config", .{});
    try user_file.writeAll(
        \\identity.name "User Level Name"
        \\identity.email "user@example.com"
        \\workspace.channel "main"
    );
    user_file.close();

    const user_path = try tmp_dir.dir.realpathAlloc(alloc, "user-config");
    defer alloc.free(user_path);

    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    try mem_fs.fs().writeFile(alloc, repository_settings_path, "identity.email \"repo@example.com\"\n");

    var cfg = try Config.load(alloc, user_path, mem_fs.fs());
    defer cfg.deinit();

    try testing.expectEqualStrings("User Level Name", cfg.settings.@"identity.name".?);
    try testing.expectEqualStrings("repo@example.com", cfg.settings.@"identity.email".?);
    try testing.expectEqualStrings("main", cfg.settings.@"workspace.channel".?);
}

test "a user-level path that doesn't exist on disk is treated as an empty layer, not an error" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var cfg = try Config.load(alloc, "/doesntexist", mem_fs.fs());
    defer cfg.deinit();

    try testing.expect(cfg.settings.@"identity.name" == null);
}

test "a present but malformed config file fails loudly rather than being skipped" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    try mem_fs.fs().writeFile(alloc, repository_settings_path, "identity.name\n"); // no value

    try testing.expectError(error.InvalidConfigSyntax, Config.load(alloc, null, mem_fs.fs()));
}

test "commit.* keys round-trip through Config, mirroring commit.zig's flag set" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    try mem_fs.fs().writeFile(alloc, repository_settings_path,
        \\commit.intent "fix"
        \\commit.author "bnlvn"
        \\commit.author_email "bnlvn@example.com"
        \\commit.committer "release-bot"
        \\commit.committer_email "bot@example.com"
        \\commit.no_body_trailers true
    );

    var cfg = try Config.load(alloc, null, mem_fs.fs());
    defer cfg.deinit();

    try testing.expectEqualStrings("fix", cfg.settings.@"commit.intent".?);
    try testing.expectEqualStrings("bnlvn", cfg.settings.@"commit.author".?);
    try testing.expectEqualStrings("bnlvn@example.com", cfg.settings.@"commit.author_email".?);
    try testing.expectEqualStrings("release-bot", cfg.settings.@"commit.committer".?);
    try testing.expectEqualStrings("bot@example.com", cfg.settings.@"commit.committer_email".?);
    try testing.expectEqual(true, cfg.settings.@"commit.no_body_trailers".?);
}

test "commit.* keys default to null when unset, leaving commit.zig's own fallbacks intact" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var cfg = try Config.load(alloc, null, mem_fs.fs());
    defer cfg.deinit();

    try testing.expect(cfg.settings.@"commit.intent" == null);
    try testing.expect(cfg.settings.@"commit.committer" == null);
    try testing.expect(cfg.settings.@"commit.no_body_trailers" == null);
}

test "an invalid typed value now fails at load time, not on first read of that field" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    try mem_fs.fs().writeFile(alloc, repository_settings_path, "history.sign yes\n");

    try testing.expectError(error.InvalidBooleanValue, Config.load(alloc, null, mem_fs.fs()));
}

test "defaultUserConfigPath doesn't crash and returns a plausible path when HOME is set" {
    const alloc = testing.allocator;
    if (try defaultUserConfigPath(alloc)) |path| {
        defer alloc.free(path);
        try testing.expect(std.mem.indexOf(u8, path, "merk") != null);
        try testing.expect(std.mem.indexOf(u8, path, "config") != null);
    }
}

test {
    testing.refAllDecls(@This());
}
