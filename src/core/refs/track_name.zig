const std = @import("std");

/// Root directory under which every track's reference file lives:
/// `references/tracks/<name>`.
pub const TRACKS_DIR = "references/tracks";

pub const TrackName = struct {
    raw: []const u8,

    pub fn parse(track: []const u8) !TrackName {
        if (track.len == 0) return error.InvalidTrackName;
        if (std.fs.path.isAbsolute(track)) return error.InvalidTrackName;

        var parts = std.mem.splitScalar(u8, track, '/');
        while (parts.next()) |part| {
            if (part.len == 0) return error.InvalidTrackName;
            if (std.mem.eql(u8, part, "..")) return error.InvalidTrackName;
        }
        return .{ .raw = track };
    }

    /// Path of this track's reference file, relative to the repository's
    /// reference root: `references/tracks/<name>`.
    pub fn refPath(self: TrackName, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ TRACKS_DIR, self.raw });
    }
};

test "parse rejects empty, absolute, and '..' segments" {
    try std.testing.expectError(error.InvalidTrackName, TrackName.parse(""));
    try std.testing.expectError(error.InvalidTrackName, TrackName.parse("/abs/path"));
    try std.testing.expectError(error.InvalidTrackName, TrackName.parse("a/../b"));
    try std.testing.expectError(error.InvalidTrackName, TrackName.parse("a//b"));
}

test "parse accepts a simple track name" {
    const t = try TrackName.parse("main");
    try std.testing.expectEqualStrings("main", t.raw);
}

test "parse accepts nested track names" {
    const t = try TrackName.parse("release/2026/q3-hardening");
    try std.testing.expectEqualStrings("release/2026/q3-hardening", t.raw);
}

test "refPath renders under the tracks directory" {
    const t = try TrackName.parse("main");
    var buf: [256]u8 = undefined;
    const path = try t.refPath(&buf);
    try std.testing.expectEqualStrings("references/tracks/main", path);
}

test "refPath renders nested track names under the tracks directory" {
    const t = try TrackName.parse("release/2026/q3-hardening");
    var buf: [256]u8 = undefined;
    const path = try t.refPath(&buf);
    try std.testing.expectEqualStrings("references/tracks/release/2026/q3-hardening", path);
}
