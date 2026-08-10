//! `Channel`: a validated, repo-root-relative channel (channel) name.
//!
//! A channel name is a `/`-separated path like `main` or
//! `release/2026/q3-hardening`, used verbatim as the suffix of its
//! reference file under `refs/channels/`. `parse` is the only way to
//! get a `Channel` — once you have one, it's guaranteed safe to join
//! onto that directory without escaping it.

const std = @import("std");
const testing = std.testing;

/// Root directory under which every channel's reference file lives:
/// `refs/channels/<name>`. Sibling to `refs/markers` and `refs/peers` —
/// see refs.zig for the full on-disk layout.
pub const CHANNELS_DIR = "refs/channels";

/// Why a candidate channel name was rejected by `parse`. Kept specific
/// (rather than one generic "invalid" error) so a CLI can tell the user
/// exactly what was wrong with what they typed.
pub const ChannelError = error{
    /// The name was empty.
    EmptyChannel,
    /// The name was an absolute path (started with `/`).
    AbsoluteChannel,
    /// A `/`-separated segment was empty — a leading, trailing, or
    /// doubled `/` (e.g. `/a`, `a/`, `a//b`).
    EmptyPathSegment,
    /// A segment was `..`, which would let the name reference something
    /// outside `refs/channels/` once joined into a path.
    ParentPathSegment,
};

pub const Channel = struct {
    raw: []const u8,

    /// Validate `channel`.  Rejects empty names,
    /// absolute paths, and any `..` or empty path segment — see
    /// `ChannelError` for which specific condition maps to which
    /// error. Does not copy `channel`; the returned `Channel`
    /// borrows it, so it must outlive the `Channel`.
    pub fn parse(channel: []const u8) ChannelError!Channel {
        if (channel.len == 0) return error.EmptyChannel;
        if (std.fs.path.isAbsolute(channel)) return error.AbsoluteChannel;

        var parts = std.mem.splitScalar(u8, channel, '/');
        while (parts.next()) |part| {
            if (part.len == 0) return error.EmptyPathSegment;
            if (std.mem.eql(u8, part, "..")) return error.ParentPathSegment;
        }
        return .{ .raw = channel };
    }

    /// Whether `channel` would be accepted by `parse` — for callers that
    /// just need a yes/no (e.g. validating CLI input as the user types)
    /// without handling a specific `ChannelError` variant.
    pub fn isValid(channel: []const u8) bool {
        _ = parse(channel) catch return false;
        return true;
    }

    /// Whether `a` and `b` name the same channel.
    pub fn eql(a: Channel, b: Channel) bool {
        return std.mem.eql(u8, a.raw, b.raw);
    }

    /// The last `/`-separated segment — e.g. `"q3-hardening"` for
    /// `"release/2026/q3-hardening"`, or the whole name for an
    /// unnested one like `"main"`. Useful anywhere a nested channel
    /// needs a short display form (status lines, prompts) without the
    /// full path.
    pub fn leaf(self: Channel) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, self.raw, '/')) |idx| {
            return self.raw[idx + 1 ..];
        }
        return self.raw;
    }

    /// Whether this channel name is nested under a `/` (e.g.
    /// `"release/2026/q3-hardening"` vs `"main"`). Cheap check for
    /// callers that want to group or indent nested channels in listings.
    pub fn isNested(self: Channel) bool {
        return std.mem.indexOfScalar(u8, self.raw, '/') != null;
    }

    /// Path of this channel's reference file, relative to the
    /// repository's reference root: `refs/channels/<name>`. Errors with
    /// `error.NoSpaceLeft` if `buf` isn't large enough to hold it.
    pub fn refPath(self: Channel, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ CHANNELS_DIR, self.raw });
    }
};

test "parse rejects empty, absolute, and '..' segments with specific errors" {
    try testing.expectError(error.EmptyChannel, Channel.parse(""));
    try testing.expectError(error.AbsoluteChannel, Channel.parse("/abs/path"));
    try testing.expectError(error.ParentPathSegment, Channel.parse("a/../b"));
    try testing.expectError(error.EmptyPathSegment, Channel.parse("a//b"));
}

test "isValid mirrors parse without exposing a specific error" {
    try testing.expect(Channel.isValid("main"));
    try testing.expect(Channel.isValid("release/2026/q3-hardening"));
    try testing.expect(!Channel.isValid(""));
    try testing.expect(!Channel.isValid("/abs"));
    try testing.expect(!Channel.isValid("a/../b"));
}

test "eql compares by name, not by identity" {
    const a = try Channel.parse("main");
    const b = try Channel.parse("main");
    const c = try Channel.parse("develop");
    try testing.expect(Channel.eql(a, b));
    try testing.expect(!Channel.eql(a, c));
}

test "parse accepts a simple channel name" {
    const c = try Channel.parse("main");
    try testing.expectEqualStrings("main", c.raw);
}

test "parse accepts nested channel names" {
    const c = try Channel.parse("release/2026/q3-hardening");
    try testing.expectEqualStrings("release/2026/q3-hardening", c.raw);
}

test "refPath renders under the channels directory" {
    const c = try Channel.parse("main");
    var buf: [256]u8 = undefined;
    const path = try c.refPath(&buf);
    try testing.expectEqualStrings("refs/channels/main", path);
}

test "refPath renders nested channel names under the channels directory" {
    const c = try Channel.parse("release/2026/q3-hardening");
    var buf: [256]u8 = undefined;
    const path = try c.refPath(&buf);
    try testing.expectEqualStrings("refs/channels/release/2026/q3-hardening", path);
}

test "leaf returns the final segment of a nested name and the whole name otherwise" {
    const nested = try Channel.parse("release/2026/q3-hardening");
    try testing.expectEqualStrings("q3-hardening", nested.leaf());

    const flat = try Channel.parse("main");
    try testing.expectEqualStrings("main", flat.leaf());
}

test "isNested distinguishes flat from nested channel names" {
    const nested = try Channel.parse("release/2026/q3-hardening");
    const flat = try Channel.parse("main");
    try testing.expect(nested.isNested());
    try testing.expect(!flat.isNested());
}
