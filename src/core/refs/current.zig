const std = @import("std");
const hash_mod = @import("merk").crypto.hash;
const channel_mod = @import("channel_name.zig");

const testing = std.testing;

pub const Hash = hash_mod.Hash;

/// Repo-root-relative path of the file recording what's currently
/// checked out: `refs/current`, sibling to `refs/channels/`,
/// `refs/markers/`, and `refs/peers/` — see refs.zig for the full layout.
pub const CURRENT_FILE = "refs/current";

/// The on-disk prefix marking a symbolic Current. Built from
/// `ChannelName.CHANNELS_DIR` rather than duplicated as a separate
/// literal, so the two can't silently drift apart if the channels
/// directory ever moves.
pub const symbolic_prefix = "ref: " ++ channel_mod.CHANNELS_DIR ++ "/";

/// The parsed state of Current: pointed at a channel (symbolic), or
/// directly at a commit (detached) — the on-disk equivalent of git's
/// `HEAD`.
pub const Current = union(enum) {
    /// Current is on a channel, by name. Owned.
    ///
    /// Deliberately a raw, unvalidated string rather than a
    /// `ChannelName`: `Current.parse` only knows how to split the
    /// on-disk format apart, not whether the result is a well-formed
    /// channel name. That check belongs to `ChannelName.parse`, applied
    /// by callers (e.g. `RefStore.resolveCurrent`) that need a validated
    /// channel to act on — see its doc comment for how an invalid name
    /// here surfaces as `error.CorruptCurrent` one layer up.
    symbolic: []u8,
    /// Detached Current: pointed directly at a commit hash, not via a
    /// channel.
    detached: Hash,

    pub fn deinit(self: Current, alloc: std.mem.Allocator) void {
        switch (self) {
            .symbolic => |s| alloc.free(s),
            .detached => {},
        }
    }

    /// Parse raw `refs/current` bytes into symbolic-or-detached state.
    pub fn parse(alloc: std.mem.Allocator, raw: []const u8) !Current {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");

        if (std.mem.startsWith(u8, trimmed, symbolic_prefix)) {
            const channel = trimmed[symbolic_prefix.len..];
            return Current{ .symbolic = try alloc.dupe(u8, channel) };
        }
        return Current{ .detached = try hash_mod.fromHex(trimmed) };
    }
};

test "parse recognizes a symbolic current and extracts the channel name" {
    const alloc = testing.allocator;
    var current = try Current.parse(alloc, "ref: refs/channels/main\n");
    defer current.deinit(alloc);

    switch (current) {
        .symbolic => |s| try testing.expectEqualStrings("main", s),
        .detached => return error.TestExpectedSymbolic,
    }
}

test "parse recognizes nested channel names in a symbolic current" {
    const alloc = testing.allocator;
    var current = try Current.parse(alloc, "ref: refs/channels/release/2026/q3-hardening");
    defer current.deinit(alloc);

    switch (current) {
        .symbolic => |s| try testing.expectEqualStrings("release/2026/q3-hardening", s),
        .detached => return error.TestExpectedSymbolic,
    }
}

test "parse recognizes a detached current as a bare hash" {
    const alloc = testing.allocator;
    const hex = "ab" ** 32;
    var current = try Current.parse(alloc, hex);
    defer current.deinit(alloc);

    switch (current) {
        .detached => {},
        .symbolic => return error.TestExpectedDetached,
    }
}

test "parse trims surrounding whitespace" {
    const alloc = testing.allocator;
    var current = try Current.parse(alloc, "  ref: refs/channels/dev  \n");
    defer current.deinit(alloc);
    switch (current) {
        .symbolic => |s| try testing.expectEqualStrings("dev", s),
        .detached => return error.TestExpectedSymbolic,
    }
}

test "parse propagates malformed hex on a detached-looking value" {
    const alloc = testing.allocator;
    if (Current.parse(alloc, "not-a-valid-hash")) |ok| {
        var mut = ok;
        mut.deinit(alloc);
        return error.TestExpectedError;
    } else |_| {}
}

test "parse treats an empty current file as corrupt, not a valid state" {
    const alloc = testing.allocator;
    if (Current.parse(alloc, "")) |ok| {
        var mut = ok;
        mut.deinit(alloc);
        return error.TestExpectedError;
    } else |_| {}
}

test "symbolic_prefix stays derived from ChannelName.CHANNELS_DIR, not duplicated" {
    try testing.expect(std.mem.startsWith(u8, symbolic_prefix, "ref: "));
    try testing.expect(std.mem.endsWith(u8, symbolic_prefix, channel_mod.CHANNELS_DIR ++ "/"));
}

test "parse accepts an empty channel name right after the prefix" {
    // refs.zig relies on this: a symbolic Current with nothing after the
    // prefix parses successfully as symbolic with an empty name — it's
    // ChannelName.parse's job (one layer up) to reject that as invalid,
    // not Current.parse's.
    const alloc = testing.allocator;
    var current = try Current.parse(alloc, symbolic_prefix);
    defer current.deinit(alloc);

    switch (current) {
        .symbolic => |s| try testing.expectEqualStrings("", s),
        .detached => return error.TestExpectedSymbolic,
    }
}
