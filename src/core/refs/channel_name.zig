//! `ChannelName`: a validated, repo-root-relative channel (branch) name.
//!
//! A channel name is a `/`-separated path like `main` or
//! `release/2026/q3-hardening`, used verbatim as the suffix of its
//! reference file under `refs/channels/`. `parse` is the only way to
//! get a `ChannelName` — once you have one, it's guaranteed safe to join
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
pub const ChannelNameError = error{
    /// The name was empty.
    EmptyChannelName,
    /// The name was an absolute path (started with `/`).
    AbsoluteChannelName,
    /// A `/`-separated segment was empty — a leading, trailing, or
    /// doubled `/` (e.g. `/a`, `a/`, `a//b`).
    EmptyPathSegment,
    /// A segment was `..`, which would let the name reference something
    /// outside `refs/channels/` once joined into a path.
    ParentPathSegment,
};

pub const ChannelName = struct {
    raw: []const u8,

    /// Validate `channel` as a channel name. Rejects empty names,
    /// absolute paths, and any `..` or empty path segment — see
    /// `ChannelNameError` for which specific condition maps to which
    /// error. Does not copy `channel`; the returned `ChannelName`
    /// borrows it, so it must outlive the `ChannelName`.
    pub fn parse(channel: []const u8) ChannelNameError!ChannelName {
        if (channel.len == 0) return error.EmptyChannelName;
        if (std.fs.path.isAbsolute(channel)) return error.AbsoluteChannelName;

        var parts = std.mem.splitScalar(u8, channel, '/');
        while (parts.next()) |part| {
            if (part.len == 0) return error.EmptyPathSegment;
            if (std.mem.eql(u8, part, "..")) return error.ParentPathSegment;
        }
        return .{ .raw = channel };
    }

    /// Whether `channel` would be accepted by `parse` — for callers that
    /// just need a yes/no (e.g. validating CLI input as the user types)
    /// without handling a specific `ChannelNameError` variant.
    pub fn isValid(channel: []const u8) bool {
        _ = parse(channel) catch return false;
        return true;
    }

    /// Whether `a` and `b` name the same channel.
    pub fn eql(a: ChannelName, b: ChannelName) bool {
        return std.mem.eql(u8, a.raw, b.raw);
    }

    /// The last `/`-separated segment — e.g. `"q3-hardening"` for
    /// `"release/2026/q3-hardening"`, or the whole name for an
    /// unnested one like `"main"`. Useful anywhere a nested channel
    /// needs a short display form (status lines, prompts) without the
    /// full path.
    pub fn leaf(self: ChannelName) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, self.raw, '/')) |idx| {
            return self.raw[idx + 1 ..];
        }
        return self.raw;
    }

    /// Whether this channel name is nested under a `/` (e.g.
    /// `"release/2026/q3-hardening"` vs `"main"`). Cheap check for
    /// callers that want to group or indent nested channels in listings.
    pub fn isNested(self: ChannelName) bool {
        return std.mem.indexOfScalar(u8, self.raw, '/') != null;
    }

    /// Path of this channel's reference file, relative to the
    /// repository's reference root: `refs/channels/<name>`. Errors with
    /// `error.NoSpaceLeft` if `buf` isn't large enough to hold it.
    pub fn refPath(self: ChannelName, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ CHANNELS_DIR, self.raw });
    }
};

test "parse rejects empty, absolute, and '..' segments with specific errors" {
    try testing.expectError(error.EmptyChannelName, ChannelName.parse(""));
    try testing.expectError(error.AbsoluteChannelName, ChannelName.parse("/abs/path"));
    try testing.expectError(error.ParentPathSegment, ChannelName.parse("a/../b"));
    try testing.expectError(error.EmptyPathSegment, ChannelName.parse("a//b"));
}

test "isValid mirrors parse without exposing a specific error" {
    try testing.expect(ChannelName.isValid("main"));
    try testing.expect(ChannelName.isValid("release/2026/q3-hardening"));
    try testing.expect(!ChannelName.isValid(""));
    try testing.expect(!ChannelName.isValid("/abs"));
    try testing.expect(!ChannelName.isValid("a/../b"));
}

test "eql compares by name, not by identity" {
    const a = try ChannelName.parse("main");
    const b = try ChannelName.parse("main");
    const c = try ChannelName.parse("develop");
    try testing.expect(ChannelName.eql(a, b));
    try testing.expect(!ChannelName.eql(a, c));
}

test "parse accepts a simple channel name" {
    const c = try ChannelName.parse("main");
    try testing.expectEqualStrings("main", c.raw);
}

test "parse accepts nested channel names" {
    const c = try ChannelName.parse("release/2026/q3-hardening");
    try testing.expectEqualStrings("release/2026/q3-hardening", c.raw);
}

test "refPath renders under the channels directory" {
    const c = try ChannelName.parse("main");
    var buf: [256]u8 = undefined;
    const path = try c.refPath(&buf);
    try testing.expectEqualStrings("refs/channels/main", path);
}

test "refPath renders nested channel names under the channels directory" {
    const c = try ChannelName.parse("release/2026/q3-hardening");
    var buf: [256]u8 = undefined;
    const path = try c.refPath(&buf);
    try testing.expectEqualStrings("refs/channels/release/2026/q3-hardening", path);
}

test "leaf returns the final segment of a nested name and the whole name otherwise" {
    const nested = try ChannelName.parse("release/2026/q3-hardening");
    try testing.expectEqualStrings("q3-hardening", nested.leaf());

    const flat = try ChannelName.parse("main");
    try testing.expectEqualStrings("main", flat.leaf());
}

test "isNested distinguishes flat from nested channel names" {
    const nested = try ChannelName.parse("release/2026/q3-hardening");
    const flat = try ChannelName.parse("main");
    try testing.expect(nested.isNested());
    try testing.expect(!flat.isNested());
}
