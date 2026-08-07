const std = @import("std");
const crypto = @import("crypto");
const storage = @import("storage");

const channel_mod = @import("channel_name.zig");
const current_mod = @import("current.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Vfs = storage.Vfs;

pub const Hash = crypto.Hash;
pub const ChannelName = channel_mod.ChannelName;
pub const Current = current_mod.Current;

const CHANNELS_DIR = channel_mod.CHANNELS_DIR;
const CURRENT_FILE = current_mod.CURRENT_FILE;

/// Root directory for markers (tags), sibling to `refs/channels`.
/// Reserved so the on-disk layout is settled up front; `ReferenceStore`
/// doesn't operate on it yet.
pub const MARKERS_DIR = "refs/markers";

/// Root directory for peers (remotes), sibling to `refs/channels`.
/// Reserved so the on-disk layout is settled up front.
/// TODO: ReferenceStore doesn't operate on it yet
pub const PEERS_DIR = "refs/peers";

/// This module's own error conditions. Every public function below can
/// also return whatever `storage.FileSystem` produces for a bad read/write
/// (e.g. `error.FileNotFound`, permission errors) — those propagate
/// through unchanged and aren't repeated here; only errors that
/// originate in this module are named.
pub const RefsError = error{
    /// `refs/current` exists but its contents parse as neither a
    /// symbolic ref (`ref: refs/channels/<name>`) nor a valid hex hash —
    /// truncated, hand-edited, or empty. Deliberately distinct from
    /// "Current doesn't exist yet", which is `null`, not an error — see
    /// `currentState`.
    CorruptCurrent,
    /// A channel's reference file exists but its contents aren't a
    /// valid hex hash.
    CorruptChannelRef,
    /// `deleteChannel` or `renameChannel` was asked to operate on a
    /// channel that has no reference file.
    ChannelNotFound,
    /// `renameChannel` without `.force` and the destination channel
    /// already has a reference file.
    DestinationExists,
};

pub const ReferenceStore = struct {
    alloc: Allocator,
    fs: Vfs,

    /// Create a new reference store backed by the given filesystem
    /// abstraction
    ///
    /// `fs` is expected to provide the repository's reference root,
    /// where `refs/current` and `refs/channels/*` are stored
    pub fn init(alloc: Allocator, fs: Vfs) ReferenceStore {
        return .{ .alloc = alloc, .fs = fs };
    }

    /// Parses raw `refs/current` bytes into symbolic-or-detached state.
    /// Every public method that touches Current is a thin projection of
    /// this single parse — including the translation of a malformed
    /// file into `error.CorruptCurrent`, so callers never need to know
    /// `Current.parse` exists or what errors it can raise internally.
    fn readCurrent(self: ReferenceStore) !?Current {
        const file = try self.fs.readFile(self.alloc, CURRENT_FILE);
        const bytes = file orelse return null;
        defer self.alloc.free(bytes);
        return Current.parse(self.alloc, bytes) catch return error.CorruptCurrent;
    }

    /// The raw parsed state of Current — symbolic or detached — for
    /// callers that need to tell the two apart without immediately
    /// resolving to a hash (e.g. `merk status` printing "on channel
    /// main" vs "detached at <hash>"). Caller must call `.deinit(alloc)`
    /// on a non-null result.
    ///
    /// Returns `null` if Current doesn't exist yet (fresh, uninitialized
    /// repository — not an error). Errors with `error.CorruptCurrent` if
    /// it exists but is unreadable as either state.
    pub fn currentState(self: RefStore) !?Current {
        return self.readCurrent();
    }

    /// Resolves Current all the way down to a commit hash: follows a
    /// symbolic Current to its channel's current hash, or returns a
    /// detached Current's hash directly.
    ///
    /// Returns `null` if Current doesn't exist yet, or if a symbolic
    /// Current points at a channel that has no commits yet — both are
    /// "no resolved commit," not an error. Errors with
    /// `error.CorruptCurrent` if Current itself is unreadable, or if a
    /// symbolic Current names an invalid channel (e.g. hand-edited into
    /// something `ChannelName.parse` rejects).
    pub fn resolveCurrent(self: RefStore) !?Hash {
        const state = try self.readCurrent() orelse return null;
        switch (state) {
            .detached => |h| return h,
            .symbolic => |channel_name| {
                defer self.alloc.free(channel_name);
                const cn = ChannelName.parse(channel_name) catch return error.CorruptCurrent;
                return try self.readChannel(cn);
            },
        }
    }

    /// The channel name Current currently points at. `null` when
    /// Current is detached (pointed at a commit directly) or doesn't
    /// exist yet. When it returns a name, the caller takes ownership of
    /// that slice and must free it.
    ///
    /// Errors with `error.CorruptCurrent` if Current exists but is
    /// unreadable.
    pub fn currentChannel(self: ReferenceStore) !?[]u8 {
        const current = try self.readCurrent();
        const state = current orelse return null;
        return switch (state) {
            .symbolic => |s| s, // ownership transfers to caller
            .detached => null,
        };
    }

    /// Whether `channel` is the one Current symbolically points at
    /// right now. `false` for a detached Current or a channel name that
    /// doesn't match — never an error just because the name doesn't
    /// match. Exists mainly so callers with a policy question ("can I
    /// delete/rename this channel?") can answer it without duplicating
    /// `currentChannel`'s allocation-and-compare dance themselves; see
    /// `deleteChannel` and `renameChannel` below, which deliberately
    /// don't make that call on their own.
    ///
    /// Errors with `error.CorruptCurrent` if Current exists but is
    /// unreadable.
    pub fn isCurrentChannel(self: ReferenceStore, channel: ChannelName) !bool {
        const current = try self.currentChannel();
        const name = current orelse return false;
        defer self.alloc.free(name);
        return ChannelName.eql(channel, .{ .raw = name });
    }

    /// Point Current at `channel` (symbolic Current) — the on-disk
    /// equivalent of `git switch`/`git checkout <branch>`. Does not
    /// require `channel` to already have a reference file; Current can
    /// point at a channel that's never been committed to yet.
    pub fn setCurrentToChannel(self: ReferenceStore, channel: ChannelName) !void {
        var buf: [256]u8 = undefined;
        const contents = try std.fmt.bufPrint(&buf, "{s}{s}", .{ current_mod.symbolic_prefix, channel.raw });
        try self.fs.writeFile(self.alloc, CURRENT_FILE, contents);
    }

    /// Point Current directly at `hash` (detached Current) — the
    /// on-disk equivalent of `git checkout <commit>`.
    pub fn setDetachedCurrent(self: ReferenceStore, hash: Hash) !void {
        const hex = try crypto.toHex(self.alloc, hash);
        defer self.alloc.free(hex);
        try self.fs.writeFile(self.alloc, CURRENT_FILE, hex);
    }

    /// Point `channel`'s reference file at `hash`, creating the channel
    /// if it doesn't have one yet.
    pub fn updateChannel(self: ReferenceStore, channel: ChannelName, hash: Hash) !void {
        var path_buf: [256]u8 = undefined;
        const path = try channel.refPath(&path_buf);

        const hex = try crypto.toHex(self.alloc, hash);
        defer self.alloc.free(hex);

        try self.fs.writeFile(self.alloc, path, hex);
    }

    /// Read the hash stored in `refs/channels/<channel>`. This doubles
    /// as "resolve an arbitrary channel, independent of Current" — e.g.
    /// for committing onto a channel other than the one currently
    /// checked out.
    ///
    /// Returns `null` when the channel has no reference file yet (never
    /// committed to — not an error). Errors with
    /// `error.CorruptChannelRef` if the file exists but isn't a valid
    /// hex hash.
    pub fn readChannel(self: ReferenceStore, channel: ChannelName) !?Hash {
        var path_buf: [256]u8 = undefined;
        const path = try channel.refPath(&path_buf);

        const file = try self.fs.readFile(self.alloc, path);
        const bytes = file orelse return null;
        defer self.alloc.free(bytes);

        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        return crypto.fromHex(trimmed) catch return error.CorruptChannelRef;
    }

    /// Whether `channel` currently has a reference file (has ever been
    /// committed to), independent of whether it's currently checked out.
    pub fn channelExists(self: ReferenceStore, channel: ChannelName) !bool {
        const hash = try self.readChannel(channel);
        return hash != null;
    }

    /// Remove `refs/channels/<channel>`. Errors with
    /// `error.ChannelNotFound` if the channel doesn't exist — use
    /// `deleteChannelIfExists` for delete-if-present semantics instead
    /// of checking `channelExists` first and racing against it.
    ///
    /// NOTE: doesn't check whether `channel` is currently checked out;
    /// callers that care (e.g. a `merk channel -d` command refusing to
    /// delete the current channel) should check `isCurrentChannel`
    /// themselves — this is pure reference-file bookkeeping.
    pub fn deleteChannel(self: ReferenceStore, channel: ChannelName) !void {
        var path_buf: [256]u8 = undefined;
        const path = try channel.refPath(&path_buf);

        self.fs.deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => return error.ChannelNotFound,
            else => return err,
        };
    }

    /// Like `deleteChannel`, but a channel with no reference file is
    /// treated as already-deleted rather than an error. Returns whether
    /// a reference file was actually removed.
    pub fn deleteChannelIfExists(self: ReferenceStore, channel: ChannelName) !bool {
        self.deleteChannel(channel) catch |err| switch (err) {
            error.ChannelNotFound => return false,
            else => return err,
        };
        return true;
    }

    pub const RenameOptions = struct {
        /// Overwrite an already-existing destination channel's
        /// reference file instead of erroring.
        force: bool = false,
    };

    /// Rename `from` to `to`: `to` ends up with `from`'s current hash,
    /// and `from`'s reference file is removed — the on-disk equivalent
    /// of `git branch -m`.
    ///
    /// NOTE: like `deleteChannel`, this is pure reference-file
    /// bookkeeping. It doesn't touch Current, so a caller renaming the
    /// currently-checked-out channel also needs to repoint Current at
    /// `to` itself (check with `isCurrentChannel` first).
    ///
    /// Errors with `error.ChannelNotFound` if `from` has no reference
    /// file, or `error.DestinationExists` if `to` already does and
    /// `.force` wasn't set.
    pub fn renameChannel(self: ReferenceStore, from: ChannelName, to: ChannelName, options: RenameOptions) !void {
        const source_hash = try self.readChannel(from);
        const hash = source_hash orelse return error.ChannelNotFound;

        const destination_exists = try self.channelExists(to);
        if (!options.force and destination_exists) return error.DestinationExists;

        try self.updateChannel(to, hash);
        try self.deleteChannel(from);
    }

    /// List every channel with a reference file under `refs/channels/`
    /// (including nested ones, e.g. "release/2026/q3-hardening"), in no
    /// particular order. Empty slice if no channels exist yet, a fresh
    /// repo isn't an error. Caller owns the returned slice and each name
    /// in it.
    pub fn listChannels(self: ReferenceStore, alloc: Allocator) ![][]u8 {
        return self.fs.listFiles(alloc, CHANNELS_DIR);
    }
};

pub const RefStore = ReferenceStore;

test "resolveCurrent - detached current with malformed hex propagates an error" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    try mem_fs.fs().writeFile(allocator, CURRENT_FILE, "not-a-valid-hash");

    const store = RefStore.init(allocator, mem_fs.fs());
    if (store.resolveCurrent()) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "resolveCurrent - empty current file is treated as corrupt, not missing" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    try mem_fs.fs().writeFile(allocator, CURRENT_FILE, "");

    const store = RefStore.init(allocator, mem_fs.fs());
    if (store.resolveCurrent()) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "resolveCurrent - symbolic current with malformed hex in target file errors" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");

    try store.setCurrentToChannel(main);
    try mem_fs.fs().writeFile(allocator, "refs/channels/main", "zzz-not-hex-zzz");

    if (store.resolveCurrent()) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "currentChannel - symbolic current with empty channel name" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    try mem_fs.fs().writeFile(allocator, CURRENT_FILE, current_mod.symbolic_prefix);

    const store = RefStore.init(allocator, mem_fs.fs());
    const channel = try store.currentChannel();
    try testing.expect(channel != null);
    defer allocator.free(channel.?);
    try testing.expectEqualStrings("", channel.?);
}

test "updateChannel overwrites previous hash on the same channel" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0x11);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0x22);

    try store.updateChannel(main, hash_a);
    const first = try store.readChannel(main);
    try testing.expect(first != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&first.?));

    try store.updateChannel(main, hash_b);
    const second = try store.readChannel(main);
    try testing.expect(second != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash_b), std.mem.asBytes(&second.?));
    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&first.?), std.mem.asBytes(&second.?)));
}

test "readChannel returns null for a channel that was never created" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const never = try ChannelName.parse("never-existed");

    const result = try store.readChannel(never);
    try testing.expectEqual(@as(?Hash, null), result);
}

test "switching current from detached to symbolic changes currentChannel result" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x55);

    try store.setDetachedCurrent(mock_hash);
    try testing.expectEqual(@as(?[]u8, null), try store.currentChannel());

    try store.setCurrentToChannel(main);
    const channel = try store.currentChannel();
    try testing.expect(channel != null);
    defer allocator.free(channel.?);
    try testing.expectEqualStrings("main", channel.?);
}

test "switching channels via setCurrentToChannel changes what resolveCurrent follows" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");
    const develop = try ChannelName.parse("develop");

    var hash_main: Hash = undefined;
    @memset(std.mem.asBytes(&hash_main), 0x66);
    var hash_dev: Hash = undefined;
    @memset(std.mem.asBytes(&hash_dev), 0x77);

    try store.setCurrentToChannel(main);
    try store.updateChannel(main, hash_main);

    try store.setCurrentToChannel(develop);
    try store.updateChannel(develop, hash_dev);

    const resolved = try store.resolveCurrent();
    try testing.expect(resolved != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash_dev), std.mem.asBytes(&resolved.?));
    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&hash_main), std.mem.asBytes(&resolved.?)));

    try store.setCurrentToChannel(main);
    const resolved_main = try store.resolveCurrent();
    try testing.expect(resolved_main != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash_main), std.mem.asBytes(&resolved_main.?));
}

test "updateChannel handles deeply nested channel names with multiple path segments" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const nested = try ChannelName.parse("release/2026/q3-hardening");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x88);

    try store.updateChannel(nested, mock_hash);

    const read_hash = try store.readChannel(nested);
    try testing.expect(read_hash != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));

    try store.setCurrentToChannel(nested);
    const resolved = try store.resolveCurrent();
    try testing.expect(resolved != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}

test "hash round-trip preserves non-uniform byte patterns" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");

    var mock_hash: Hash = undefined;
    for (std.mem.asBytes(&mock_hash), 0..) |*b, i| {
        b.* = @truncate(i);
    }

    try store.updateChannel(main, mock_hash);
    const read_hash = try store.readChannel(main);
    try testing.expect(read_hash != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));
}

test "distinct channels with distinct hashes do not clobber each other" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");
    const develop = try ChannelName.parse("develop");
    const feature_x = try ChannelName.parse("feature/x");

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0x99);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0xEE);
    var hash_c: Hash = undefined;
    @memset(std.mem.asBytes(&hash_c), 0xFF);

    try store.updateChannel(main, hash_a);
    try store.updateChannel(develop, hash_b);
    try store.updateChannel(feature_x, hash_c);

    const ra = try store.readChannel(main);
    const rb = try store.readChannel(develop);
    const rc = try store.readChannel(feature_x);

    try testing.expect(ra != null and rb != null and rc != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&ra.?));
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash_b), std.mem.asBytes(&rb.?));
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash_c), std.mem.asBytes(&rc.?));
}

test "setCurrentToChannel followed by setDetachedCurrent correctly overwrites symbolic state" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x12);

    try store.setCurrentToChannel(main);

    const channel = try store.currentChannel();
    try testing.expect(channel != null);
    if (channel) |c| allocator.free(c);

    try store.setDetachedCurrent(mock_hash);

    const channel_detached = try store.currentChannel();
    defer if (channel_detached) |c| allocator.free(c);
    try testing.expectEqual(@as(?[]u8, null), channel_detached);

    const resolved = try store.resolveCurrent();
    try testing.expect(resolved != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}

test "currentState distinguishes symbolic from detached without resolving" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");

    try testing.expectEqual(@as(?Current, null), try store.currentState());

    try store.setCurrentToChannel(main);
    var symbolic_state = try store.currentState() orelse return error.ExpectedCurrentState;
    defer symbolic_state.deinit(allocator);
    switch (symbolic_state) {
        .symbolic => |s| try testing.expectEqualStrings("main", s),
        .detached => return error.TestExpectedSymbolic,
    }

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x33);
    try store.setDetachedCurrent(mock_hash);

    var detached_state = try store.currentState() orelse return error.ExpectedCurrentState;
    defer detached_state.deinit(allocator);
    switch (detached_state) {
        .detached => |h| try testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&h)),
        .symbolic => return error.TestExpectedDetached,
    }
}

test "channelExists reflects whether a channel has ever been committed to" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");

    try testing.expect(!try store.channelExists(main));

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x44);
    try store.updateChannel(main, mock_hash);

    try testing.expect(try store.channelExists(main));
}

test "deleteChannel removes the reference and errors on a repeat delete" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const feature = try ChannelName.parse("feature/x");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x66);
    try store.updateChannel(feature, mock_hash);
    try testing.expect(try store.channelExists(feature));

    try store.deleteChannel(feature);
    try testing.expect(!try store.channelExists(feature));

    try testing.expectError(error.ChannelNotFound, store.deleteChannel(feature));
}

test "deleteChannelIfExists reports whether it actually deleted anything" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const feature = try ChannelName.parse("feature/y");

    // Nothing to delete yet — false, not an error.
    try testing.expectEqual(false, try store.deleteChannelIfExists(feature));

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x99);
    try store.updateChannel(feature, mock_hash);

    try testing.expectEqual(true, try store.deleteChannelIfExists(feature));
    try testing.expect(!try store.channelExists(feature));
}

test "renameChannel moves the hash and removes the old reference file" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const old_name = try ChannelName.parse("old-name");
    const new_name = try ChannelName.parse("new-name");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0xAA);
    try store.updateChannel(old_name, mock_hash);

    try store.renameChannel(old_name, new_name, .{});

    try testing.expect(!try store.channelExists(old_name));
    const moved = try store.readChannel(new_name);
    try testing.expect(moved != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&moved.?));
}

test "renameChannel errors on a missing source and on an existing destination without force" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const missing = try ChannelName.parse("does-not-exist");
    const main = try ChannelName.parse("main");
    const develop = try ChannelName.parse("develop");

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0xBB);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0xCC);
    try store.updateChannel(main, hash_a);
    try store.updateChannel(develop, hash_b);

    try testing.expectError(error.ChannelNotFound, store.renameChannel(missing, develop, .{}));
    try testing.expectError(error.DestinationExists, store.renameChannel(main, develop, .{}));

    // force lets it through and overwrites the destination's hash.
    try store.renameChannel(main, develop, .{ .force = true });
    try testing.expect(!try store.channelExists(main));
    const overwritten = try store.readChannel(develop);
    try testing.expect(overwritten != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&overwritten.?));
}

test "listChannels finds nested channels and is empty for a fresh repo" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());

    const empty = try store.listChannels(allocator);
    defer allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const main = try ChannelName.parse("main");
    const nested = try ChannelName.parse("release/2026/q3-hardening");
    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x77);
    try store.updateChannel(main, mock_hash);
    try store.updateChannel(nested, mock_hash);

    const names = try store.listChannels(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 2), names.len);

    var saw_main = false;
    var saw_nested = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "main")) saw_main = true;
        if (std.mem.eql(u8, n, "release/2026/q3-hardening")) saw_nested = true;
    }
    try testing.expect(saw_main);
    try testing.expect(saw_nested);
}

test "markers and peers directories are reserved and distinct from channels" {
    try testing.expect(!std.mem.eql(u8, MARKERS_DIR, CHANNELS_DIR));
    try testing.expect(!std.mem.eql(u8, PEERS_DIR, CHANNELS_DIR));
    try testing.expect(!std.mem.eql(u8, MARKERS_DIR, PEERS_DIR));
}

test "reference layout is unified under a single refs/ root" {
    try testing.expect(std.mem.startsWith(u8, CURRENT_FILE, "refs/"));
    try testing.expect(std.mem.startsWith(u8, CHANNELS_DIR, "refs/"));
    try testing.expect(std.mem.startsWith(u8, MARKERS_DIR, "refs/"));
    try testing.expect(std.mem.startsWith(u8, PEERS_DIR, "refs/"));
}

test "isCurrentChannel is true only for the channel Current symbolically points at" {
    const allocator = testing.allocator;
    var mem_fs = storage.MemoryFs.init(allocator);
    defer mem_fs.deinit();

    const store = RefStore.init(allocator, mem_fs.fs());
    const main = try ChannelName.parse("main");
    const develop = try ChannelName.parse("develop");

    // No Current yet — nothing is "the current channel".
    try testing.expect(!try store.isCurrentChannel(main));

    try store.setCurrentToChannel(main);
    try testing.expect(try store.isCurrentChannel(main));
    try testing.expect(!try store.isCurrentChannel(develop));

    // Detached Current — no channel is current, even one that was
    // current a moment ago.
    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x42);
    try store.setDetachedCurrent(mock_hash);
    try testing.expect(!try store.isCurrentChannel(main));
}

test "os_fs: RefStore end-to-end with real filesystem" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_fs = storage.OsFs.init(tmp.dir);
    const store = RefStore.init(allocator, real_fs.fs());
    const main = try ChannelName.parse("main");

    var hash: Hash = undefined;
    @memset(std.mem.asBytes(&hash), 0xAB);

    try store.updateChannel(main, hash);
    const read = try store.readChannel(main);
    try testing.expect(read != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash), std.mem.asBytes(&read.?));
}

test "os_fs: current round-trips between symbolic and detached on real disk" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_fs = storage.OsFs.init(tmp.dir);
    const store = RefStore.init(allocator, real_fs.fs());
    const main = try ChannelName.parse("main");

    var hash: Hash = undefined;
    @memset(std.mem.asBytes(&hash), 0xCD);

    try store.updateChannel(main, hash);
    try store.setCurrentToChannel(main);

    const resolved = try store.resolveCurrent();
    try testing.expect(resolved != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&hash), std.mem.asBytes(&resolved.?));

    try store.setDetachedCurrent(hash);
    const channel_after_detach = try store.currentChannel();
    try testing.expectEqual(@as(?[]u8, null), channel_after_detach);
}

test "os_fs: listChannels with nested paths on real disk" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_fs = storage.OsFs.init(tmp.dir);
    const store = RefStore.init(allocator, real_fs.fs());

    const main = try ChannelName.parse("main");
    const nested = try ChannelName.parse("release/2026/q3-hardening");
    var hash: Hash = undefined;
    @memset(std.mem.asBytes(&hash), 0xCD);

    try store.updateChannel(main, hash);
    try store.updateChannel(nested, hash);

    const names = try store.listChannels(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    try testing.expectEqual(@as(usize, 2), names.len);
    var saw_main = false;
    var saw_nested = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "main")) saw_main = true;
        if (std.mem.eql(u8, n, "release/2026/q3-hardening")) saw_nested = true;
    }
    try testing.expect(saw_main);
    try testing.expect(saw_nested);
}
