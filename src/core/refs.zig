/// Reference storage and HEAD resolution utilities.
///
/// This module manages branch refs under `refs/heads/`, reads and writes
/// HEAD state, and resolves symbolic HEADs to commit hashes.
const std = @import("std");
const hash_mod = @import("hash.zig");
pub const Hash = hash_mod.Hash;

const head_ref_prefix = "ref: refs/heads/";

/// A branch name that has already passed validation.
/// Once you hold a BranchName, nothing downstream needs to re-check it —
/// the type itself is the proof, so `refPath` etc. can't fail on bad input.
pub const BranchName = struct {
    raw: []const u8,

    pub fn parse(branch: []const u8) !BranchName {
        if (branch.len == 0) return error.InvalidBranchName;
        if (std.fs.path.isAbsolute(branch)) return error.InvalidBranchName;

        var parts = std.mem.splitScalar(u8, branch, '/');
        while (parts.next()) |part| {
            if (part.len == 0) return error.InvalidBranchName;
            if (std.mem.eql(u8, part, "..")) return error.InvalidBranchName;
        }
        return .{ .raw = branch };
    }

    fn refPath(self: BranchName, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "refs/heads/{s}", .{self.raw});
    }
};

/// The parsed state of HEAD. Replaces returning `?Hash` from one function
/// and `?[]u8` from another, each re-deriving "symbolic vs detached"
/// independently.
pub const HeadState = union(enum) {
    symbolic: []u8, // owned
    detached: Hash,

    fn deinit(self: HeadState, alloc: std.mem.Allocator) void {
        switch (self) {
            .symbolic => |s| alloc.free(s),
            .detached => {},
        }
    }
};

const AtomicFile = struct {
    fn write(alloc: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
        const parent = std.fs.path.dirname(path);
        if (parent) |p| try dir.makePath(p);

        var rand_buf: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{x}", .{ path, rand_buf });
        defer alloc.free(tmp_path);

        const file = try dir.createFile(tmp_path, .{ .truncate = true });
        var file_closed = false;
        defer if (!file_closed) file.close();
        errdefer {
            if (!file_closed) {
                file.close();
                file_closed = true;
            }
            dir.deleteFile(tmp_path) catch {};
        }

        try file.writeAll(contents);
        try file.sync();
        file.close();
        file_closed = true;

        dir.rename(tmp_path, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try dir.deleteFile(path);
                try dir.rename(tmp_path, path);
            },
            else => return err,
        };
    }
};

pub const RefStore = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,

    /// Create a new ref store backed by the given directory.
    ///
    /// `dir` is expected to be the repository ref directory root where
    /// `HEAD` and `refs/heads/*` are stored.
    pub fn init(alloc: std.mem.Allocator, dir: std.fs.Dir) RefStore {
        return .{ .alloc = alloc, .dir = dir };
    }

    /// Parses raw HEAD bytes into symbolic-or-detached state.
    /// Private: every public method below is a thin projection of this single parse.
    fn readHead(self: RefStore) !?HeadState {
        const head_bytes = self.dir.readFileAlloc(self.alloc, "HEAD", 256) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.alloc.free(head_bytes);

        const trimmed = std.mem.trim(u8, head_bytes, " \t\r\n");

        if (std.mem.startsWith(u8, trimmed, head_ref_prefix)) {
            const branch = trimmed[head_ref_prefix.len..];
            return HeadState{ .symbolic = try self.alloc.dupe(u8, branch) };
        }
        return HeadState{ .detached = try hash_mod.fromHex(trimmed) };
    }

    /// Resolve HEAD to a concrete commit hash.
    ///
    /// Returns `null` when HEAD is missing, or when a symbolic HEAD references
    /// a branch ref that does not exist. Detached HEAD values are returned
    /// directly as the stored hash.
    pub fn resolveHead(self: RefStore) !?Hash {
        const state = try self.readHead() orelse return null;
        switch (state) {
            .detached => |h| return h,
            .symbolic => |branch_name| {
                defer self.alloc.free(branch_name);
                const bn = try BranchName.parse(branch_name);
                return try self.readBranch(bn);
            },
        }
    }

    /// Returns the branch name pointed to by a symbolic HEAD.
    ///
    /// When HEAD is detached, returns `null`. When HEAD is a symbolic ref,
    /// the caller takes ownership of the returned branch name slice.
    pub fn headBranch(self: RefStore) !?[]u8 {
        const state = try self.readHead() orelse return null;
        return switch (state) {
            .symbolic => |s| s, // ownership transfers to caller
            .detached => null,
        };
    }

    /// Write `HEAD` as a symbolic ref to the given branch.
    pub fn writeHeadRef(self: RefStore, branch: BranchName) !void {
        var buf: [256]u8 = undefined;
        const contents = try std.fmt.bufPrint(&buf, "ref: refs/heads/{s}", .{branch.raw});
        try AtomicFile.write(self.alloc, self.dir, "HEAD", contents);
    }

    /// Write `HEAD` in detached mode to the given commit hash.
    pub fn writeDetachedHead(self: RefStore, hash: Hash) !void {
        const hex = try hash_mod.toHex(self.alloc, hash);
        defer self.alloc.free(hex);
        try AtomicFile.write(self.alloc, self.dir, "HEAD", hex);
    }

    /// Update the reference file for `refs/heads/<branch>` to point at `hash`.
    pub fn updateBranch(self: RefStore, branch: BranchName, hash: Hash) !void {
        var path_buf: [256]u8 = undefined;
        const path = try branch.refPath(&path_buf);

        const hex = try hash_mod.toHex(self.alloc, hash);
        defer self.alloc.free(hex);

        try AtomicFile.write(self.alloc, self.dir, path, hex);
    }

    /// Read the hash stored in `refs/heads/<branch>`.
    ///
    /// Returns `null` when the branch ref file does not exist.
    pub fn readBranch(self: RefStore, branch: BranchName) !?Hash {
        var path_buf: [256]u8 = undefined;
        const path = try branch.refPath(&path_buf);

        const bytes = self.dir.readFileAlloc(self.alloc, path, 128) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.alloc.free(bytes);

        return try hash_mod.fromHex(std.mem.trim(u8, bytes, " \t\r\n"));
    }
};

test "resolveHead - detached HEAD with malformed hex propagates an error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);

    try AtomicFile.write(allocator, tmp.dir, "HEAD", "not-a-valid-hash");

    if (store.resolveHead()) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "resolveHead - empty HEAD file is treated as corrupt, not missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);

    try AtomicFile.write(allocator, tmp.dir, "HEAD", "");

    if (store.resolveHead()) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "resolveHead - symbolic ref with malformed hex in target file errors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);
    const main = try BranchName.parse("main");

    try store.writeHeadRef(main);
    try AtomicFile.write(allocator, tmp.dir, "refs/heads/main", "zzz-not-hex-zzz");

    if (store.resolveHead()) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "headBranch - symbolic ref with empty branch name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);

    // Pathological but syntactically valid per head_ref_prefix stripping.
    // Note: headBranch doesn't go through BranchName.parse, so this still
    // returns "" rather than erroring — that asymmetry is worth knowing about.
    try AtomicFile.write(allocator, tmp.dir, "HEAD", head_ref_prefix);

    const branch = try store.headBranch();
    try std.testing.expect(branch != null);
    defer allocator.free(branch.?);
    try std.testing.expectEqualStrings("", branch.?);
}

test "updateBranch overwrites previous hash on the same branch" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);
    const main = try BranchName.parse("main");

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0x11);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0x22);

    try store.updateBranch(main, hash_a);
    const first = try store.readBranch(main);
    try std.testing.expect(first != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&first.?));

    try store.updateBranch(main, hash_b);
    const second = try store.readBranch(main);
    try std.testing.expect(second != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_b), std.mem.asBytes(&second.?));
    try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&first.?), std.mem.asBytes(&second.?)));
}

test "readBranch returns null for a branch that was never created" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);
    const never = try BranchName.parse("never-existed");

    const result = try store.readBranch(never);
    try std.testing.expectEqual(@as(?Hash, null), result);
}

test "switching HEAD from detached to symbolic changes headBranch result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);
    const main = try BranchName.parse("main");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x55);

    try store.writeDetachedHead(mock_hash);
    try std.testing.expectEqual(@as(?[]u8, null), try store.headBranch());

    try store.writeHeadRef(main);
    const branch = try store.headBranch();
    try std.testing.expect(branch != null);
    defer allocator.free(branch.?);
    try std.testing.expectEqualStrings("main", branch.?);
}

test "switching branches via writeHeadRef changes what resolveHead follows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);
    const main = try BranchName.parse("main");
    const develop = try BranchName.parse("develop");

    var hash_main: Hash = undefined;
    @memset(std.mem.asBytes(&hash_main), 0x66);
    var hash_dev: Hash = undefined;
    @memset(std.mem.asBytes(&hash_dev), 0x77);

    try store.writeHeadRef(main);
    try store.updateBranch(main, hash_main);

    try store.writeHeadRef(develop);
    try store.updateBranch(develop, hash_dev);

    const resolved = try store.resolveHead();
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_dev), std.mem.asBytes(&resolved.?));
    try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&hash_main), std.mem.asBytes(&resolved.?)));

    try store.writeHeadRef(main);
    const resolved_main = try store.resolveHead();
    try std.testing.expect(resolved_main != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_main), std.mem.asBytes(&resolved_main.?));
}

test "updateBranch handles deeply nested branch names with multiple path segments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);
    const nested = try BranchName.parse("release/2026/q3-hardening");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x88);

    try store.updateBranch(nested, mock_hash);

    const read_hash = try store.readBranch(nested);
    try std.testing.expect(read_hash != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));

    try store.writeHeadRef(nested);
    const resolved = try store.resolveHead();
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}

test "hash round-trip preserves non-uniform byte patterns" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);
    const main = try BranchName.parse("main");

    var mock_hash: Hash = undefined;
    for (std.mem.asBytes(&mock_hash), 0..) |*b, i| {
        b.* = @truncate(i);
    }

    try store.updateBranch(main, mock_hash);
    const read_hash = try store.readBranch(main);
    try std.testing.expect(read_hash != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));
}

test "distinct branches with distinct hashes do not clobber each other" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);
    const main = try BranchName.parse("main");
    const develop = try BranchName.parse("develop");
    const feature_x = try BranchName.parse("feature/x");

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0x99);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0xEE);
    var hash_c: Hash = undefined;
    @memset(std.mem.asBytes(&hash_c), 0xFF);

    try store.updateBranch(main, hash_a);
    try store.updateBranch(develop, hash_b);
    try store.updateBranch(feature_x, hash_c);

    const ra = try store.readBranch(main);
    const rb = try store.readBranch(develop);
    const rc = try store.readBranch(feature_x);

    try std.testing.expect(ra != null and rb != null and rc != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&ra.?));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_b), std.mem.asBytes(&rb.?));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_c), std.mem.asBytes(&rc.?));
}

test "writeHeadRef followed by writeDetachedHead correctly overwrites symbolic state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = RefStore.init(allocator, tmp.dir);
    const main = try BranchName.parse("main");

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x12);

    try store.writeHeadRef(main);

    const branch = try store.headBranch();
    try std.testing.expect(branch != null);
    if (branch) |b| allocator.free(b);

    try store.writeDetachedHead(mock_hash);

    const branch_detached = try store.headBranch();
    defer if (branch_detached) |b| allocator.free(b);
    try std.testing.expectEqual(@as(?[]u8, null), branch_detached);

    const resolved = try store.resolveHead();
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}
