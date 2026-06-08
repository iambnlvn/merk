const std = @import("std");

pub const FlagKind = enum { boolean, value };

pub const Flag = struct {
    short: ?u8 = null,
    long: []const u8,
    kind: FlagKind,
    value_name: ?[]const u8 = null,
    help: []const u8 = "",
    required: bool = false,
};

/// Lightweight flag map backed by a fixed-size inline buffer. No heap
/// allocation; 32 slots is far more than any nodus command will ever need.
pub const FlagMap = struct {
    const capacity = 32;

    const Entry = struct {
        key: []const u8,
        value: []const u8, // "" means boolean present
    };

    buf: [capacity]Entry = undefined,
    len: usize = 0,

    fn slice(self: *FlagMap) []Entry {
        return self.buf[0..self.len];
    }

    fn constSlice(self: *const FlagMap) []const Entry {
        return self.buf[0..self.len];
    }

    pub fn set(self: *FlagMap, key: []const u8, value: []const u8) !void {
        // Overwrite if already set (last-wins, like most CLIs).
        for (self.slice()) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.value = value;
                return;
            }
        }
        if (self.len >= capacity) return Error.Overflow;
        self.buf[self.len] = .{ .key = key, .value = value };
        self.len += 1;
    }

    pub fn get(self: *const FlagMap, key: []const u8) ?[]const u8 {
        for (self.constSlice()) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn has(self: *const FlagMap, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn string(self: *const FlagMap, key: []const u8) ?[]const u8 {
        return self.get(key);
    }

    pub fn boolean(self: *const FlagMap, key: []const u8) bool {
        return self.has(key);
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
    flags: []const Flag = &.{},
    run: *const fn (inv: *Invocation) anyerror!void,

    pub fn printHelp(self: Command, writer: anytype) !void {
        try writer.print("usage: nodus {s}", .{self.name});
        if (self.usage.len > 0) try writer.print(" {s}", .{self.usage});
        try writer.writeByte('\n');

        if (self.description.len > 0) {
            try writer.writeByte('\n');
            try writer.print("{s}\n", .{self.description});
        }

        const all_flags = self.flags.len > 0;
        if (!all_flags) return;

        try writer.writeByte('\n');
        try writer.writeAll("options:\n");

        for (self.flags) |flag| {
            const col = try renderFlagPrefix(flag, writer);
            if (flag.help.len > 0) {
                const pad_to: usize = 26;
                if (col < pad_to) {
                    var i: usize = 0;
                    while (i < pad_to - col) : (i += 1) {
                        try writer.writeByte(' ');
                    }
                } else {
                    try writer.writeByte(' ');
                }
                try writer.writeAll(flag.help);
                if (flag.required) try writer.writeAll(" (required)");
            }
            try writer.writeByte('\n');
        }

        try writer.writeAll("  -h, --help              show this help\n");
    }

    /// Returns the number of columns consumed for alignment
    fn renderFlagPrefix(flag: Flag, writer: anytype) !usize {
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
        // Allocate an explicit buffer on the stack for the stderr stream
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const w = &stderr_writer.interface;

        // Pass the interface pointer to the help printer
        self.printHelp(w) catch {};

        w.flush() catch {};
    }

    /// Parses `args` (already past the binary + command name tokens) into an
    /// `Invocation`.
    ///  The caller owns the returned value and must call
    /// `inv.deinit()`
    pub fn parseArgs(
        self: Command,
        alloc: std.mem.Allocator,
        args: *std.process.ArgIterator,
    ) Error!Invocation {
        var inv = Invocation{
            .alloc = alloc,
            .flags = .{},
            .positional = .{},
        };
        errdefer inv.deinit();

        var terminated = false;

        while (args.next()) |arg| {
            if (terminated or !std.mem.startsWith(u8, arg, "-")) {
                try inv.positional.append(alloc, arg);
                continue;
            }

            if (std.mem.eql(u8, arg, "--")) {
                terminated = true;
                continue;
            }

            // Help shortcut handled by dispatch too
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                self.printHelpToStderr();
                return Error.HelpRequested;
            }

            // Long flag: --foo or --foo=bar
            if (std.mem.startsWith(u8, arg, "--")) {
                const body = arg[2..];
                if (std.mem.indexOf(u8, body, "=")) |eq| {
                    const key = body[0..eq];
                    const val = body[eq + 1 ..];
                    const flag = self.findLong(key) orelse return Error.UnknownFlag;
                    if (flag.kind == .boolean) return Error.UnexpectedValue;
                    try inv.flags.set(key, val);
                } else {
                    const flag = self.findLong(body) orelse return Error.UnknownFlag;
                    if (flag.kind == .boolean) {
                        try inv.flags.set(body, "");
                    } else {
                        const val = args.next() orelse return Error.MissingValue;
                        try inv.flags.set(body, val);
                    }
                }
                continue;
            }

            // Short flag cluster: -abc, -v, -o foo
            const cluster = arg[1..];
            for (cluster, 0..) |ch, i| {
                const flag = self.findShort(ch) orelse return Error.UnknownFlag;
                if (flag.kind == .boolean) {
                    try inv.flags.set(flag.long, "");
                } else {
                    // Remainder of cluster is the inline value (-oFILE), or
                    // consume the next token
                    const rest = cluster[i + 1 ..];
                    const val = if (rest.len > 0) rest else (args.next() orelse return Error.MissingValue);
                    try inv.flags.set(flag.long, val);
                    break;
                }
            }
        }

        // Validate required flags
        for (self.flags) |flag| {
            if (flag.required and !inv.flags.has(flag.long)) {
                std.debug.print("error: missing required flag --{s}\n", .{flag.long});
                return Error.MissingRequired;
            }
        }

        return inv;
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
