const std = @import("std");
const hash_mod = @import("merk").crypto.hash;
pub const Hash = hash_mod.Hash;

pub const FOCUS_FILE = "focus";

/// The on-disk prefix marking a symbolic Focus
pub const symbolic_prefix = "ref: references/tracks/";

/// The parsed state of Focus: pointed at a track (symbolic), or directly
/// at a commit (detached)
pub const Focus = union(enum) {
    /// Focus is on a track, by name. Owned.
    symbolic: []u8,
    /// Detached Focus: pointed directly at a commit hash, not via a track.
    detached: Hash,

    pub fn deinit(self: Focus, alloc: std.mem.Allocator) void {
        switch (self) {
            .symbolic => |s| alloc.free(s),
            .detached => {},
        }
    }

    /// Parse raw focus-file bytes into symbolic-or-detached state
    pub fn parse(alloc: std.mem.Allocator, raw: []const u8) !Focus {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");

        if (std.mem.startsWith(u8, trimmed, symbolic_prefix)) {
            const track = trimmed[symbolic_prefix.len..];
            return Focus{ .symbolic = try alloc.dupe(u8, track) };
        }
        return Focus{ .detached = try hash_mod.fromHex(trimmed) };
    }
};

test "parse recognizes a symbolic focus and extracts the track name" {
    const alloc = std.testing.allocator;
    var focus = try Focus.parse(alloc, "ref: references/tracks/main\n");
    defer focus.deinit(alloc);

    switch (focus) {
        .symbolic => |s| try std.testing.expectEqualStrings("main", s),
        .detached => return error.TestExpectedSymbolic,
    }
}

test "parse recognizes nested track names in a symbolic focus" {
    const alloc = std.testing.allocator;
    var focus = try Focus.parse(alloc, "ref: references/tracks/release/2026/q3-hardening");
    defer focus.deinit(alloc);

    switch (focus) {
        .symbolic => |s| try std.testing.expectEqualStrings("release/2026/q3-hardening", s),
        .detached => return error.TestExpectedSymbolic,
    }
}

test "parse recognizes a detached focus as a bare hash" {
    const alloc = std.testing.allocator;
    const hex = "ab" ** 32;
    var focus = try Focus.parse(alloc, hex);
    defer focus.deinit(alloc);

    switch (focus) {
        .detached => {},
        .symbolic => return error.TestExpectedDetached,
    }
}

test "parse trims surrounding whitespace" {
    const alloc = std.testing.allocator;
    var focus = try Focus.parse(alloc, "  ref: references/tracks/dev  \n");
    defer focus.deinit(alloc);
    switch (focus) {
        .symbolic => |s| try std.testing.expectEqualStrings("dev", s),
        .detached => return error.TestExpectedSymbolic,
    }
}

test "parse propagates malformed hex on a detached-looking value" {
    const alloc = std.testing.allocator;
    if (Focus.parse(alloc, "not-a-valid-hash")) |ok| {
        var mut = ok;
        mut.deinit(alloc);
        return error.TestExpectedError;
    } else |_| {}
}

test "parse treats an empty focus file as corrupt, not a valid state" {
    const alloc = std.testing.allocator;
    if (Focus.parse(alloc, "")) |ok| {
        var mut = ok;
        mut.deinit(alloc);
        return error.TestExpectedError;
    } else |_| {}
}
