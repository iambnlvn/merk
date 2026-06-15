const std = @import("std");
const diff = @import("nodus").diff;

pub fn parseFormat(s: []const u8) ?diff.Format {
    const map = std.StaticStringMap(diff.Format).initComptime(.{
        .{ "unified", .unified },
        .{ "side-by-side", .side_by_side },
        .{ "blocks", .blocks },
        .{ "ops", .ops },
        .{ "summary", .summary },
    });
    return map.get(s);
}

pub fn parseLevel(s: []const u8) ?diff.Level {
    const map = std.StaticStringMap(diff.Level).initComptime(.{
        .{ "file", .file },
        .{ "hunk", .hunk },
        .{ "line", .line },
        .{ "word", .word },
    });
    return map.get(s);
}

pub fn parseContext(s: []const u8) ?diff.Context {
    if (std.mem.eql(u8, s, "minimal")) return .minimal;
    if (std.mem.eql(u8, s, "normal")) return .normal;
    if (std.mem.eql(u8, s, "full")) return .full;
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    return .{ .exact = n };
}

pub fn parseGroupBy(s: []const u8) ?diff.GroupBy {
    const map = std.StaticStringMap(diff.GroupBy).initComptime(.{
        .{ "none", .none },
        .{ "files", .files },
        .{ "dirs", .dirs },
    });
    return map.get(s);
}

pub fn parseAlgorithm(s: []const u8) ?diff.Algorithm {
    const map = std.StaticStringMap(diff.Algorithm).initComptime(.{
        .{ "myers", .myers },
        .{ "patience", .patience },
        .{ "histogram", .histogram },
    });
    return map.get(s);
}

/// CLI-only: whether to emit ANSI color codes. The core renderers are
/// colorless; if/when color support is added to rendering, it should take
/// a plain `bool` derived from this, not this enum directly
pub const ColorMode = enum {
    auto,
    always,
    never,
};

pub fn parseColorMode(raw: []const u8) ?ColorMode {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "always")) return .always;
    if (std.mem.eql(u8, raw, "never")) return .never;
    return null;
}

/// Resolves `auto` against whether stdout is a TTY. CLI-only — core has no
/// concept of a terminal.
pub fn resolveColor(mode: ColorMode, stdout_is_tty: bool) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => stdout_is_tty,
    };
}

pub const Profile = enum { review, ci, debug };

pub const ProfileOpts = struct {
    pub fn apply(p: Profile, config: *diff.RenderConfig) void {
        switch (p) {
            .review => {
                config.format = .side_by_side;
                config.level = .line;
                config.group_by = .files;
            },
            .ci => {
                config.format = .summary;
                config.level = .file;
            },
            .debug => {
                config.format = .ops;
                config.context = .full;
            },
        }
    }
};

pub const DiffArgs = struct {
    refs: [2]?[]const u8 = .{ null, null },
    paths: std.ArrayList([]const u8),
    staged: bool = false,
    working: bool = false,
    config: diff.RenderConfig = .{},
    color: ColorMode = .auto,

    pub fn parse(alloc: std.mem.Allocator, args: []const []const u8) !DiffArgs {
        var da = DiffArgs{ .paths = .empty };
        errdefer da.paths.deinit(alloc);

        var i: usize = 2; // skip argv[0] and subcommand "diff"
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.format = parseFormat(args[i]) orelse return error.InvalidFormat;
            } else if (std.mem.eql(u8, arg, "--level")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.level = parseLevel(args[i]) orelse return error.InvalidLevel;
            } else if (std.mem.eql(u8, arg, "--context")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.context = parseContext(args[i]) orelse return error.InvalidContext;
            } else if (std.mem.eql(u8, arg, "--group")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.group_by = parseGroupBy(args[i]) orelse return error.InvalidGroup;
            } else if (std.mem.eql(u8, arg, "--show")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.filter = try diff.ChangeFilter.parse(args[i]);
            } else if (std.mem.eql(u8, arg, "--only-added")) {
                da.config.filter = .{ .show_added = true, .show_deleted = false, .show_modified = false };
            } else if (std.mem.eql(u8, arg, "--only-deleted")) {
                da.config.filter = .{ .show_added = false, .show_deleted = true, .show_modified = false };
            } else if (std.mem.eql(u8, arg, "--only-modified")) {
                da.config.filter = .{ .show_added = false, .show_deleted = false, .show_modified = true };
            } else if (std.mem.eql(u8, arg, "--word")) {
                da.config.word_mode = true;
            } else if (std.mem.eql(u8, arg, "--detect-moves")) {
                da.config.detect_moves = true;
            } else if (std.mem.eql(u8, arg, "--no-color")) {
                da.color = .never;
            } else if (std.mem.eql(u8, arg, "--color")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.color = parseColorMode(args[i]) orelse return error.InvalidColorMode;
            } else if (std.mem.eql(u8, arg, "--algo")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                da.config.algorithm = parseAlgorithm(args[i]) orelse return error.InvalidAlgorithm;
            } else if (std.mem.eql(u8, arg, "--profile")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                const p = std.meta.stringToEnum(Profile, args[i]) orelse return error.InvalidProfile;
                ProfileOpts.apply(p, &da.config);
            } else if (std.mem.eql(u8, arg, "--staged")) {
                da.staged = true;
            } else if (std.mem.eql(u8, arg, "--working")) {
                da.working = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return error.UnknownFlag;
            } else {
                if (da.refs[0] == null) {
                    da.refs[0] = arg;
                } else if (da.refs[1] == null) {
                    da.refs[1] = arg;
                } else {
                    try da.paths.append(alloc, arg);
                }
            }
        }
        return da;
    }

    pub fn deinit(self: *DiffArgs, alloc: std.mem.Allocator) void {
        self.paths.deinit(alloc);
    }
};

test "DiffArgs parse format and level" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "nodus", "diff", "--format", "side-by-side", "--level", "word" };
    var da = try DiffArgs.parse(alloc, &args);
    defer da.deinit(alloc);
    try std.testing.expectEqual(diff.Format.side_by_side, da.config.format);
    try std.testing.expectEqual(diff.Level.word, da.config.level);
}

test "DiffArgs parse --algo flag" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "nodus", "diff", "--algo", "patience" };
    var da = try DiffArgs.parse(alloc, &args);
    defer da.deinit(alloc);
    try std.testing.expectEqual(diff.Algorithm.patience, da.config.algorithm);
}

test "DiffArgs parse profile review" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "nodus", "diff", "--profile", "review" };
    var da = try DiffArgs.parse(alloc, &args);
    defer da.deinit(alloc);
    try std.testing.expectEqual(diff.Format.side_by_side, da.config.format);
    try std.testing.expectEqual(diff.Level.line, da.config.level);
    try std.testing.expectEqual(diff.GroupBy.files, da.config.group_by);
}
