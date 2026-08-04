const std = @import("std");
const parsers = @import("flags.zig");

pub const Context = @import("context.zig").Context;

pub const FlagKind = enum { boolean, value };

/// Where a command belongs in `merk help`. Purely presentational — grouping
/// only, no behavioral effect on parsing.
pub const Category = enum {
    repository,
    snapshot,
    history,
    plumbing,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .repository => "Repository",
            .snapshot => "Snapshot",
            .history => "History",
            .plumbing => "Plumbing",
        };
    }
};

pub const Flag = struct {
    short: ?u8 = null,
    long: []const u8,
    kind: FlagKind,
    value_name: ?[]const u8 = null,
    help: []const u8 = "",
    required: bool = false,
    /// Raw display default, e.g. "10". Purely for `--help` output — the
    /// actual fallback value is supplied by the handler via
    /// `FlagMap.stringOr` / `.intOr` / etc, since Zig can't express a typed
    /// default alongside `[]const Flag` at comptime without generics per flag.
    default: ?[]const u8 = null,
};

/// Lightweight flag map backed by a fixed-size inline buffer. No heap
/// allocation; 32 slots is far more than any merk command will ever need
pub const FlagMap = struct {
    const capacity = 32;

    const Entry = struct {
        key: []const u8,
        value: []const u8, // "" means boolean present
    };

    buf: [capacity]Entry = undefined,
    len: usize = 0,

    /// Appends a new flag value. Supports multi-value flags by allowing
    /// duplicate keys up to the map capacity.
    pub fn set(self: *FlagMap, key: []const u8, value: []const u8) !void {
        if (self.len >= capacity) return Error.Overflow;
        self.buf[self.len] = .{ .key = key, .value = value };
        self.len += 1;
    }

    /// Gets the *last* instance of a flag (standard last-wins behavior).
    pub fn get(self: *const FlagMap, key: []const u8) ?[]const u8 {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            const e = self.buf[i];
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn has(self: *const FlagMap, key: []const u8) bool {
        return self.get(key) != null;
    }

    // Every `*Or` accessor takes an explicit default so call sites read as
    // documentation ("dry_run defaults to false", "depth defaults to 10")
    // instead of a bare `orelse` scattered through command bodies. A parse
    // failure on a *provided* value falls back to `default` too, keeping
    // handlers free of manual error plumbing for malformed flags; use
    // `stringOr`/`get` directly if you need to distinguish "absent" from
    // "present but invalid".

    pub fn boolean(self: *const FlagMap, key: []const u8) bool {
        return self.has(key);
    }

    /// Plain optional accessor — the usual `if (inv.flags.string("x")) |v|`
    /// pattern for flags with no natural default. Alias of `get`, kept as
    /// its own name since call sites read better as "string" than "get".
    pub fn string(self: *const FlagMap, key: []const u8) ?[]const u8 {
        return self.get(key);
    }

    pub fn stringOr(self: *const FlagMap, key: []const u8, default: []const u8) []const u8 {
        return self.get(key) orelse default;
    }

    pub fn intOr(self: *const FlagMap, comptime T: type, key: []const u8, default: T) T {
        const raw = self.get(key) orelse return default;
        return parsers.parseInt(T, raw) orelse default;
    }

    pub fn unsignedOr(self: *const FlagMap, comptime T: type, key: []const u8, default: T) T {
        const raw = self.get(key) orelse return default;
        return parsers.parseUnsigned(T, raw) orelse default;
    }

    pub fn boolValueOr(self: *const FlagMap, key: []const u8, default: bool) bool {
        const raw = self.get(key) orelse return default;
        return parsers.parseBool(raw) orelse default;
    }

    pub fn enumOr(self: *const FlagMap, comptime T: type, key: []const u8, default: T) T {
        const raw = self.get(key) orelse return default;
        return parsers.parseEnum(T, raw) orelse default;
    }

    /// MultiValueIterator provides a zero-allocation way to iterate through
    /// multiple instances of a flag (e.g., `--trailer`).
    pub const MultiValueIterator = struct {
        map: *const FlagMap,
        key: []const u8,
        index: usize = 0,

        pub fn next(self: *MultiValueIterator) ?[]const u8 {
            while (self.index < self.map.len) {
                const entry = self.map.buf[self.index];
                self.index += 1;
                if (std.mem.eql(u8, entry.key, self.key)) return entry.value;
            }
            return null;
        }
    };

    /// Returns an iterator to fetch all values bound to a specific flag key.
    pub fn getMulti(self: *const FlagMap, key: []const u8) MultiValueIterator {
        return .{ .map = self, .key = key };
    }
};

/// Everything a command handler receives. Positional args are already split
/// from flags; the raw ArgIterator is gone from the public surface.
pub const Invocation = struct {
    alloc: std.mem.Allocator,
    flags: FlagMap,
    /// Positional arguments left after flag parsing. Owned by the caller;
    /// lives for the duration of main().
    positional: std.ArrayListUnmanaged([]const u8),

    pub fn deinit(self: *Invocation) void {
        self.positional.deinit(self.alloc);
    }
};

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    usage: []const u8 = "",
    category: Category = .plumbing,
    flags: []const Flag = &.{},
    run: *const fn (ctx: Context, inv: *Invocation) anyerror!void,

    pub fn printHelp(self: Command, writer: *std.Io.Writer) !void {
        try writer.print("usage: merk {s}", .{self.name});
        if (self.usage.len > 0) try writer.print(" {s}", .{self.usage});
        try writer.writeByte('\n');

        if (self.description.len > 0) {
            try writer.writeByte('\n');
            try writer.print("{s}\n", .{self.description});
        }

        if (self.flags.len == 0) return;

        try writer.writeByte('\n');
        try writer.writeAll("options:\n");

        for (self.flags) |flag| {
            const col = try renderFlagPrefix(flag, writer);
            try padTo(writer, col, 26);
            if (flag.help.len > 0) try writer.writeAll(flag.help);
            if (flag.default) |d| try writer.print(" (default: {s})", .{d});
            if (flag.required) try writer.writeAll(" (required)");
            try writer.writeByte('\n');
        }

        try writer.writeAll("  -h, --help              show this help\n");
    }

    fn padTo(writer: *std.Io.Writer, col: usize, target: usize) !void {
        if (col >= target) {
            try writer.writeByte(' ');
            return;
        }
        var i: usize = col;
        while (i < target) : (i += 1) try writer.writeByte(' ');
    }

    /// Returns the number of columns consumed for alignment.
    fn renderFlagPrefix(flag: Flag, writer: *std.Io.Writer) !usize {
        var col: usize = 2;
        try writer.writeAll("  ");

        if (flag.short) |s| {
            try writer.print("-{c}, ", .{s});
            col += 4;
        } else {
            try writer.writeAll("    ");
            col += 4;
        }

        try writer.print("--{s}", .{flag.long});
        col += 2 + flag.long.len;

        if (flag.kind == .value) {
            const vn = flag.value_name orelse "value";
            try writer.print(" <{s}>", .{vn});
            col += 3 + vn.len;
        }

        return col;
    }

    pub fn printHelpToStderr(self: Command) void {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const w = &stderr_writer.interface;

        self.printHelp(w) catch {};
        w.flush() catch {};
    }

    /// Parses `args` (already past the binary + command name tokens) into an
    /// `Invocation`. Parse failures are reported to `err_writer` with enough
    /// context (which flag, what was wrong) to act on, then surfaced as a
    /// plain `Error` for the caller to branch on.
    ///
    /// The caller owns the returned value and must call `inv.deinit()`.
    pub fn parseArgs(
        self: Command,
        alloc: std.mem.Allocator,
        args: *std.process.ArgIterator,
        err_writer: *std.Io.Writer,
    ) Error!Invocation {
        var inv = Invocation{ .alloc = alloc, .flags = .{}, .positional = .{} };
        errdefer inv.deinit();

        var terminated = false;

        while (args.next()) |arg| {
            if (terminated or !std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) {
                try inv.positional.append(alloc, arg);
                continue;
            }

            if (std.mem.eql(u8, arg, "--")) {
                terminated = true;
                continue;
            }

            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                self.printHelpToStderr();
                return Error.HelpRequested;
            }

            if (std.mem.startsWith(u8, arg, "--")) {
                try self.parseLong(arg[2..], args, &inv, err_writer);
            } else {
                try self.parseShortCluster(arg[1..], args, &inv, err_writer);
            }
        }

        for (self.flags) |flag| {
            if (flag.required and !inv.flags.has(flag.long)) {
                err_writer.print("error: missing required flag --{s}\n", .{flag.long}) catch {};
                return Error.MissingRequired;
            }
        }

        return inv;
    }

    /// Handles `--foo`, `--foo=bar`, and `--foo bar`.
    fn parseLong(
        self: Command,
        body: []const u8,
        args: *std.process.ArgIterator,
        inv: *Invocation,
        err_writer: *std.Io.Writer,
    ) Error!void {
        const eq = std.mem.indexOfScalar(u8, body, '=');
        const key = if (eq) |i| body[0..i] else body;

        const flag = self.findLong(key) orelse {
            err_writer.print("error: unknown flag --{s}\n", .{key}) catch {};
            return Error.UnknownFlag;
        };

        if (eq) |i| {
            if (flag.kind == .boolean) {
                err_writer.print("error: --{s} does not take a value\n", .{key}) catch {};
                return Error.UnexpectedValue;
            }
            try inv.flags.set(key, body[i + 1 ..]);
            return;
        }

        if (flag.kind == .boolean) {
            try inv.flags.set(key, "");
            return;
        }

        const val = args.next() orelse {
            err_writer.print("error: --{s} requires a value\n", .{key}) catch {};
            return Error.MissingValue;
        };
        try inv.flags.set(key, val);
    }

    /// Handles short clusters: `-abc`, `-v`, `-o foo`, `-oFILE`.
    fn parseShortCluster(
        self: Command,
        cluster: []const u8,
        args: *std.process.ArgIterator,
        inv: *Invocation,
        err_writer: *std.Io.Writer,
    ) Error!void {
        var i: usize = 0;
        while (i < cluster.len) : (i += 1) {
            const ch = cluster[i];
            const flag = self.findShort(ch) orelse {
                err_writer.print("error: unknown flag -{c}\n", .{ch}) catch {};
                return Error.UnknownFlag;
            };

            if (flag.kind == .boolean) {
                try inv.flags.set(flag.long, "");
                continue;
            }

            // Remainder of the cluster is the inline value (-oFILE), or the
            // next token is consumed (-o FILE). Either way this ends the
            // cluster: a value-flag can't be chained with more shorts after it.
            const rest = cluster[i + 1 ..];
            const val = if (rest.len > 0) rest else args.next() orelse {
                err_writer.print("error: -{c} requires a value\n", .{ch}) catch {};
                return Error.MissingValue;
            };
            try inv.flags.set(flag.long, val);
            return;
        }
    }

    fn findLong(self: Command, name: []const u8) ?Flag {
        for (self.flags) |f| {
            if (std.mem.eql(u8, f.long, name)) return f;
        }
        return null;
    }

    fn findShort(self: Command, ch: u8) ?Flag {
        for (self.flags) |f| {
            if (f.short == ch) return f;
        }
        return null;
    }
};

pub const Error = error{
    UnknownFlag,
    MissingValue,
    UnexpectedValue,
    MissingRequired,
    HelpRequested,
    OutOfMemory,
    Overflow,
};
