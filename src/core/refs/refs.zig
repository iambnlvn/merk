const std = @import("std");
const hash_mod = @import("merk").crypto.hash;
const fs_mod = @import("merk").io;
const track_mod = @import("track_name.zig");
const focus_mod = @import("focus.zig");

pub const Hash = hash_mod.Hash;
pub const TrackName = track_mod.TrackName;
pub const Focus = focus_mod.Focus;

const TRACKS_DIR = track_mod.TRACKS_DIR;
const FOCUS_FILE = focus_mod.FOCUS_FILE;

/// Root directory for markers (tags), mirroring TRACKS_DIR. Reserved so the
/// on-disk layout is settled up front; ReferenceStore doesn't operate on
/// it yet.
pub const MARKERS_DIR = "references/markers";

/// Root directory for peers (remotes), mirroring TRACKS_DIR. Reserved so
/// the on-disk layout is settled up front;
/// TODO: ReferenceStore doesn't operate on it yet
pub const PEERS_DIR = "references/peers";

pub const ReferenceStore = struct {
    alloc: std.mem.Allocator,
    fs: fs_mod.FileSystem,

    /// Create a new reference store backed by the given filesystem
    /// abstraction
    ///
    /// `fs` is expected to provide the repository's reference root, where
    /// `focus` and `references/tracks/*` are stored
    pub fn init(alloc: std.mem.Allocator, fs: fs_mod.FileSystem) ReferenceStore {
        return .{ .alloc = alloc, .fs = fs };
    }

    /// Parses raw focus bytes into symbolic-or-detached state. Every public
    /// method that touches `focus` is a thin projection of this single parse
    fn readFocus(self: ReferenceStore) !?Focus {
        const bytes = try self.fs.readFile(self.alloc, FOCUS_FILE) orelse return null;
        defer self.alloc.free(bytes);
        return try Focus.parse(self.alloc, bytes);
    }

    /// The raw parsed state of Focus — symbolic  or detached
    ///  for callers that need to tell the two apart without
    /// immediately resolving to a hash (e.g. `merk status`
    /// printing "on track main" vs "Focus detached at <hash>")
    /// NOTE: `null` if Focus doesn't exist yet. Caller must call `.deinit(alloc)`
    /// on the result
    pub fn focusState(self: ReferenceStore) !?Focus {
        return self.readFocus();
    }

    /// Returns `null` when Focus is missing, or when a symbolic Focus
    /// references a track that does not exist. Detached Focus values are
    /// returned directly as the stored hash
    pub fn resolveFocus(self: ReferenceStore) !?Hash {
        const state = try self.readFocus() orelse return null;
        switch (state) {
            .detached => |h| return h,
            .symbolic => |track_name| {
                defer self.alloc.free(track_name);
                const tn = try TrackName.parse(track_name);
                return try self.readTrack(tn);
            },
        }
    }

    /// Returns the track name Focus currently points at
    /// When Focus is detached, returns `null`. When Focus is symbolic, the
    /// caller takes ownership of the returned track-name slice
    pub fn focusTrack(self: ReferenceStore) !?[]u8 {
        const state = try self.readFocus() orelse return null;
        return switch (state) {
            .symbolic => |s| s, // ownership transfers to caller
            .detached => null,
        };
    }

    /// Set Focus to point at `track` (symbolic Focus)
    pub fn setFocusToTrack(self: ReferenceStore, track: TrackName) !void {
        var buf: [256]u8 = undefined;
        const contents = try std.fmt.bufPrint(&buf, "{s}{s}", .{ focus_mod.symbolic_prefix, track.raw });
        try self.fs.writeFile(self.alloc, FOCUS_FILE, contents);
    }

    /// Set Focus directly to `hash` (detached Focus)
    pub fn setDetachedFocus(self: ReferenceStore, hash: Hash) !void {
        const hex = try hash_mod.toHex(self.alloc, hash);
        defer self.alloc.free(hex);
        try self.fs.writeFile(self.alloc, FOCUS_FILE, hex);
    }

    /// Update the reference file for `references/tracks/<track>` to point
    /// at `hash`. Creates the track if it doesn't exist yet
    pub fn updateTrack(self: ReferenceStore, track: TrackName, hash: Hash) !void {
        var path_buf: [256]u8 = undefined;
        const path = try track.refPath(&path_buf);

        const hex = try hash_mod.toHex(self.alloc, hash);
        defer self.alloc.free(hex);

        try self.fs.writeFile(self.alloc, path, hex);
    }

    /// Read the hash stored in `references/tracks/<track>`.
    /// Returns `null` when the track's reference file does not exist. This
    /// also doubles as "resolve an arbitrary track, independent of
    /// Focus" — e.g. for committing onto a track other than the one
    /// currently in Focus
    pub fn readTrack(self: ReferenceStore, track: TrackName) !?Hash {
        var path_buf: [256]u8 = undefined;
        const path = try track.refPath(&path_buf);

        const bytes = try self.fs.readFile(self.alloc, path) orelse return null;
        defer self.alloc.free(bytes);

        return try hash_mod.fromHex(std.mem.trim(u8, bytes, " \t\r\n"));
    }

    /// Whether `track` currently has a reference file (has ever been
    /// committed to), independent of whether it's currently in Focus
    pub fn trackExists(self: ReferenceStore, track: TrackName) !bool {
        return (try self.readTrack(track)) != null;
    }

    /// Remove `references/tracks/<track>`. Errors with
    /// `error.TrackNotFound` if the track doesn't exist — callers that want
    /// delete-if-present semantics should check `trackExists` first (or
    /// catch that error).
    ///
    /// NOTE: doesn't check whether `track` is currently in Focus; callers
    /// that care (e.g. a `merk track -d` command refusing to delete the
    /// current track) need that check themselves — this is pure
    /// reference-file bookkeeping
    pub fn deleteTrack(self: ReferenceStore, track: TrackName) !void {
        var path_buf: [256]u8 = undefined;
        const path = try track.refPath(&path_buf);

        self.fs.deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => return error.TrackNotFound,
            else => return err,
        };
    }

    /// List every track with a reference file under `references/tracks/`
    /// (including nested ones, e.g. "release/2026/q3-hardening"), in no
    /// particular order. Empty slice if no tracks exist yet, a fresh repo
    /// isn't an error. Caller owns the returned slice and each name in it.
    pub fn listTracks(self: ReferenceStore, alloc: std.mem.Allocator) ![][]u8 {
        return self.fs.listFiles(alloc, TRACKS_DIR);
    }
};

test "resolveFocus - detached focus with malformed hex propagates an error" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    try test_fs.fs().writeFile(allocator, FOCUS_FILE, "not-a-valid-hash");

    const store = ReferenceStore.init(allocator, test_fs.fs());
    if (store.resolveFocus()) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "resolveFocus - empty focus file is treated as corrupt, not missing" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    try test_fs.fs().writeFile(allocator, FOCUS_FILE, "");

    const store = ReferenceStore.init(allocator, test_fs.fs());
    if (store.resolveFocus()) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "resolveFocus - symbolic focus with malformed hex in target file errors" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const main = try TrackName.parse("main");

    try store.setFocusToTrack(main);
    try test_fs.fs().writeFile(allocator, "references/tracks/main", "zzz-not-hex-zzz");

    if (store.resolveFocus()) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "focusTrack - symbolic focus with empty track name" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    try test_fs.fs().writeFile(allocator, FOCUS_FILE, focus_mod.symbolic_prefix);

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const track = try store.focusTrack();
    try std.testing.expect(track != null);
    defer allocator.free(track.?);
    try std.testing.expectEqualStrings("", track.?);
}

test "updateTrack overwrites previous hash on the same track" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const main = try TrackName.parse("main");

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0x11);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0x22);

    try store.updateTrack(main, hash_a);
    const first = try store.readTrack(main);
    try std.testing.expect(first != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&first.?));

    try store.updateTrack(main, hash_b);
    const second = try store.readTrack(main);
    try std.testing.expect(second != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_b), std.mem.asBytes(&second.?));
    try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&first.?), std.mem.asBytes(&second.?)));
}

test "readTrack returns null for a track that was never created" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const never = try TrackName.parse("never-existed");

    const result = try store.readTrack(never);
    try std.testing.expectEqual(@as(?Hash, null), result);
}

test "switching focus from detached to symbolic changes focusTrack result" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const main = try TrackName.parse("main");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x55);

    try store.setDetachedFocus(mock_hash);
    try std.testing.expectEqual(@as(?[]u8, null), try store.focusTrack());

    try store.setFocusToTrack(main);
    const track = try store.focusTrack();
    try std.testing.expect(track != null);
    defer allocator.free(track.?);
    try std.testing.expectEqualStrings("main", track.?);
}

test "switching tracks via setFocusToTrack changes what resolveFocus follows" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const main = try TrackName.parse("main");
    const develop = try TrackName.parse("develop");

    var hash_main: Hash = undefined;
    @memset(std.mem.asBytes(&hash_main), 0x66);
    var hash_dev: Hash = undefined;
    @memset(std.mem.asBytes(&hash_dev), 0x77);

    try store.setFocusToTrack(main);
    try store.updateTrack(main, hash_main);

    try store.setFocusToTrack(develop);
    try store.updateTrack(develop, hash_dev);

    const resolved = try store.resolveFocus();
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_dev), std.mem.asBytes(&resolved.?));
    try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&hash_main), std.mem.asBytes(&resolved.?)));

    try store.setFocusToTrack(main);
    const resolved_main = try store.resolveFocus();
    try std.testing.expect(resolved_main != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_main), std.mem.asBytes(&resolved_main.?));
}

test "updateTrack handles deeply nested track names with multiple path segments" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const nested = try TrackName.parse("release/2026/q3-hardening");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x88);

    try store.updateTrack(nested, mock_hash);

    const read_hash = try store.readTrack(nested);
    try std.testing.expect(read_hash != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));

    try store.setFocusToTrack(nested);
    const resolved = try store.resolveFocus();
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}

test "hash round-trip preserves non-uniform byte patterns" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const main = try TrackName.parse("main");

    var mock_hash: Hash = undefined;
    for (std.mem.asBytes(&mock_hash), 0..) |*b, i| {
        b.* = @truncate(i);
    }

    try store.updateTrack(main, mock_hash);
    const read_hash = try store.readTrack(main);
    try std.testing.expect(read_hash != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));
}

test "distinct tracks with distinct hashes do not clobber each other" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const main = try TrackName.parse("main");
    const develop = try TrackName.parse("develop");
    const feature_x = try TrackName.parse("feature/x");

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0x99);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0xEE);
    var hash_c: Hash = undefined;
    @memset(std.mem.asBytes(&hash_c), 0xFF);

    try store.updateTrack(main, hash_a);
    try store.updateTrack(develop, hash_b);
    try store.updateTrack(feature_x, hash_c);

    const ra = try store.readTrack(main);
    const rb = try store.readTrack(develop);
    const rc = try store.readTrack(feature_x);

    try std.testing.expect(ra != null and rb != null and rc != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&ra.?));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_b), std.mem.asBytes(&rb.?));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_c), std.mem.asBytes(&rc.?));
}

test "setFocusToTrack followed by setDetachedFocus correctly overwrites symbolic state" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const main = try TrackName.parse("main");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x12);

    try store.setFocusToTrack(main);

    const track = try store.focusTrack();
    try std.testing.expect(track != null);
    if (track) |t| allocator.free(t);

    try store.setDetachedFocus(mock_hash);

    const track_detached = try store.focusTrack();
    defer if (track_detached) |t| allocator.free(t);
    try std.testing.expectEqual(@as(?[]u8, null), track_detached);

    const resolved = try store.resolveFocus();
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}

test "focusState distinguishes symbolic from detached without resolving" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const main = try TrackName.parse("main");

    try std.testing.expectEqual(@as(?Focus, null), try store.focusState());

    try store.setFocusToTrack(main);
    var symbolic_state = try store.focusState() orelse return error.ExpectedFocusState;
    defer symbolic_state.deinit(allocator);
    switch (symbolic_state) {
        .symbolic => |s| try std.testing.expectEqualStrings("main", s),
        .detached => return error.TestExpectedSymbolic,
    }

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x33);
    try store.setDetachedFocus(mock_hash);

    var detached_state = try store.focusState() orelse return error.ExpectedFocusState;
    defer detached_state.deinit(allocator);
    switch (detached_state) {
        .detached => |h| try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&h)),
        .symbolic => return error.TestExpectedDetached,
    }
}

test "trackExists reflects whether a track has ever been committed to" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const main = try TrackName.parse("main");

    try std.testing.expect(!try store.trackExists(main));

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x44);
    try store.updateTrack(main, mock_hash);

    try std.testing.expect(try store.trackExists(main));
}

test "deleteTrack removes the reference and errors on a repeat delete" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());
    const feature = try TrackName.parse("feature/x");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x66);
    try store.updateTrack(feature, mock_hash);
    try std.testing.expect(try store.trackExists(feature));

    try store.deleteTrack(feature);
    try std.testing.expect(!try store.trackExists(feature));

    try std.testing.expectError(error.TrackNotFound, store.deleteTrack(feature));
}

test "listTracks finds nested tracks and is empty for a fresh repo" {
    const allocator = std.testing.allocator;
    var test_fs = fs_mod.TestFs.init(allocator);
    defer test_fs.deinit();

    const store = ReferenceStore.init(allocator, test_fs.fs());

    const empty = try store.listTracks(allocator);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const main = try TrackName.parse("main");
    const nested = try TrackName.parse("release/2026/q3-hardening");
    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x77);
    try store.updateTrack(main, mock_hash);
    try store.updateTrack(nested, mock_hash);

    const names = try store.listTracks(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);

    var saw_main = false;
    var saw_nested = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "main")) saw_main = true;
        if (std.mem.eql(u8, n, "release/2026/q3-hardening")) saw_nested = true;
    }
    try std.testing.expect(saw_main);
    try std.testing.expect(saw_nested);
}

test "markers and peers directories are reserved and distinct from tracks" {
    try std.testing.expect(!std.mem.eql(u8, MARKERS_DIR, TRACKS_DIR));
    try std.testing.expect(!std.mem.eql(u8, PEERS_DIR, TRACKS_DIR));
    try std.testing.expect(!std.mem.eql(u8, MARKERS_DIR, PEERS_DIR));
}

test "RealFs: ReferenceStore end-to-end with real filesystem" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_fs = fs_mod.RealFs.init(tmp.dir);
    const store = ReferenceStore.init(allocator, real_fs.fs());
    const main = try TrackName.parse("main");

    var hash: Hash = undefined;
    @memset(std.mem.asBytes(&hash), 0xAB);

    try store.updateTrack(main, hash);
    const read = try store.readTrack(main);
    try std.testing.expect(read != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash), std.mem.asBytes(&read.?));
}

test "RealFs: focus round-trips between symbolic and detached on real disk" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_fs = fs_mod.RealFs.init(tmp.dir);
    const store = ReferenceStore.init(allocator, real_fs.fs());
    const main = try TrackName.parse("main");

    var hash: Hash = undefined;
    @memset(std.mem.asBytes(&hash), 0xCD);

    try store.updateTrack(main, hash);
    try store.setFocusToTrack(main);

    const resolved = try store.resolveFocus();
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash), std.mem.asBytes(&resolved.?));

    try store.setDetachedFocus(hash);
    const track_after_detach = try store.focusTrack();
    try std.testing.expectEqual(@as(?[]u8, null), track_after_detach);
}

test "RealFs: listTracks with nested paths on real disk" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_fs = fs_mod.RealFs.init(tmp.dir);
    const store = ReferenceStore.init(allocator, real_fs.fs());

    const main = try TrackName.parse("main");
    const nested = try TrackName.parse("release/2026/q3-hardening");
    var hash: Hash = undefined;
    @memset(std.mem.asBytes(&hash), 0xCD);

    try store.updateTrack(main, hash);
    try store.updateTrack(nested, hash);

    const names = try store.listTracks(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 2), names.len);
    var saw_main = false;
    var saw_nested = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "main")) saw_main = true;
        if (std.mem.eql(u8, n, "release/2026/q3-hardening")) saw_nested = true;
    }
    try std.testing.expect(saw_main);
    try std.testing.expect(saw_nested);
}
