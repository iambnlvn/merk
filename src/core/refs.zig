const std = @import("std");
const hash_mod = @import("hash.zig");
//TODO: WIP
pub const Hash = hash_mod.Hash;

/// HEAD contents:
///
/// Symbolic:
///     ref: refs/heads/main
///
/// Detached:
///     a1b2c3d4...
///
const head_ref_prefix = "ref: refs/heads/";

fn writeFile(
    dir: std.fs.Dir,
    path: []const u8,
    contents: []const u8,
) !void {
    const parent = std.fs.path.dirname(path);

    if (parent) |parent_path| {
        try dir.makePath(parent_path);
    }

    var file = try dir.createFile(
        path,
        .{
            .truncate = true,
        },
    );
    defer file.close();

    try file.writeAll(contents);
}

/// Resolve HEAD to a commit hash.
///
/// Returns:
/// - null if HEAD does not exist
/// - null if symbolic ref exists but points to a non-existent branch
pub fn resolveHead(
    alloc: std.mem.Allocator,
    nodus_dir: std.fs.Dir,
) !?Hash {
    const head_bytes =
        nodus_dir.readFileAlloc(
            alloc,
            "HEAD",
            256,
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

    defer alloc.free(head_bytes);

    const trimmed =
        std.mem.trim(
            u8,
            head_bytes,
            " \t\r\n",
        );

    // Symbolic HEAD
    if (std.mem.startsWith(
        u8,
        trimmed,
        head_ref_prefix,
    )) {
        const ref_path =
            std.mem.trimLeft(
                u8,
                trimmed["ref: ".len..],
                " ",
            );

        const ref_bytes =
            nodus_dir.readFileAlloc(
                alloc,
                ref_path,
                128,
            ) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };

        defer alloc.free(ref_bytes);

        const hex =
            std.mem.trim(
                u8,
                ref_bytes,
                " \t\r\n",
            );

        return try hash_mod.fromHex(hex);
    }

    // Detached HEAD
    return try hash_mod.fromHex(trimmed);
}

/// Write HEAD as:
///
///     ref: refs/heads/main
///
pub fn writeHeadRef(
    nodus_dir: std.fs.Dir,
    branch: []const u8,
) !void {
    var buf: [256]u8 = undefined;

    const contents =
        try std.fmt.bufPrint(
            &buf,
            "ref: refs/heads/{s}",
            .{branch},
        );

    try writeFile(
        nodus_dir,
        "HEAD",
        contents,
    );
}

/// Write HEAD directly to a commit hash
/// (detached HEAD state).
pub fn writeDetachedHead(
    alloc: std.mem.Allocator,
    nodus_dir: std.fs.Dir,
    hash: Hash,
) !void {
    const hex = try hash_mod.toHex(alloc, hash);
    defer alloc.free(hex);

    try writeFile(
        nodus_dir,
        "HEAD",
        hex,
    );
}

/// Update:
///
///     refs/heads/<branch>
///
pub fn updateBranch(
    alloc: std.mem.Allocator,
    nodus_dir: std.fs.Dir,
    branch: []const u8,
    hash: Hash,
) !void {
    var path_buf: [256]u8 = undefined;

    const path =
        try std.fmt.bufPrint(
            &path_buf,
            "refs/heads/{s}",
            .{branch},
        );

    const hex = try hash_mod.toHex(alloc, hash);
    defer alloc.free(hex);

    try writeFile(
        nodus_dir,
        path,
        hex,
    );
}

/// Read:
///
///     refs/heads/<branch>
///
pub fn readBranch(
    alloc: std.mem.Allocator,
    nodus_dir: std.fs.Dir,
    branch: []const u8,
) !?Hash {
    var path_buf: [256]u8 = undefined;

    const path =
        try std.fmt.bufPrint(
            &path_buf,
            "refs/heads/{s}",
            .{branch},
        );

    const bytes =
        nodus_dir.readFileAlloc(
            alloc,
            path,
            128,
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

    defer alloc.free(bytes);

    return try hash_mod.fromHex(
        std.mem.trim(
            u8,
            bytes,
            " \t\r\n",
        ),
    );
}

/// Returns:
///
///     "main"
///
/// for:
///
///     ref: refs/heads/main
///
/// Returns null when detached.
pub fn headBranch(
    alloc: std.mem.Allocator,
    nodus_dir: std.fs.Dir,
) !?[]u8 {
    const head_bytes =
        nodus_dir.readFileAlloc(
            alloc,
            "HEAD",
            256,
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

    defer alloc.free(head_bytes);

    const trimmed =
        std.mem.trim(
            u8,
            head_bytes,
            " \t\r\n",
        );

    if (!std.mem.startsWith(
        u8,
        trimmed,
        head_ref_prefix,
    ))
        return null;

    return try alloc.dupe(
        u8,
        trimmed[head_ref_prefix.len..],
    );
}

/// Update a branch ref to point at commit_hash
pub fn updateRef(
    alloc: std.mem.Allocator,
    nodus_dir: std.fs.Dir,
    branch: []const u8,
    commit_hash: Hash,
) !void {
    const hex = try hash_mod.toHex(alloc, commit_hash);
    defer alloc.free(hex);

    // Ensure refs/heads/ directory exists
    try nodus_dir.makePath("refs/heads");

    const ref_path = try std.fmt.allocPrint(alloc, "refs/heads/{s}", .{branch});
    defer alloc.free(ref_path);

    try writeFile(nodus_dir, ref_path, hex);
}

test "resolveHead - detached HEAD with malformed hex propagates an error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Not valid hex at all, should error, not silently return null.
    // (null is reserved for "ref/file legitimately absent", not "corrupt data")
    try writeFile(tmp.dir, "HEAD", "not-a-valid-hash");

    if (resolveHead(allocator, tmp.dir)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "resolveHead - empty HEAD file is treated as corrupt, not missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // File exists but is zero-length after trimming,falls through to the
    // detached-HEAD branch and attempts to parse "" as hex
    try writeFile(tmp.dir, "HEAD", "");

    if (resolveHead(allocator, tmp.dir)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "resolveHead - symbolic ref with malformed hex in target file errors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeHeadRef(tmp.dir, "main");
    try writeFile(tmp.dir, "refs/heads/main", "zzz-not-hex-zzz");

    // Distinguish "branch ref missing" (null) from "branch ref present but
    // corrupt" (error) — resolveHead must not conflate the two
    if (resolveHead(allocator, tmp.dir)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "headBranch - symbolic ref with empty branch name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pathological but syntactically valid per head_ref_prefix stripping:
    // "ref: refs/heads/" with nothing after it.
    try writeFile(tmp.dir, "HEAD", head_ref_prefix);

    const branch = try headBranch(allocator, tmp.dir);
    try std.testing.expect(branch != null);
    defer allocator.free(branch.?);
    try std.testing.expectEqualStrings("", branch.?);
}

test "updateRef overwrites previous hash on the same branch" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0x11);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0x22);

    try updateRef(allocator, tmp.dir, "main", hash_a);
    const first = try readBranch(allocator, tmp.dir, "main");
    try std.testing.expect(first != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&first.?));

    // Simulate a second commit landing on the same branch
    try updateRef(allocator, tmp.dir, "main", hash_b);
    const second = try readBranch(allocator, tmp.dir, "main");
    try std.testing.expect(second != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_b), std.mem.asBytes(&second.?));
    try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&first.?), std.mem.asBytes(&second.?)));
}

test "updateRef and updateBranch are interchangeable on the same ref path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0x33);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0x44);

    // updateBranch doesn't call makePath explicitly — confirm it still
    // works standalone (relies on writeFile's own dirname/makePath)
    try updateBranch(allocator, tmp.dir, "shared", hash_a);
    const via_read_branch = try readBranch(allocator, tmp.dir, "shared");
    try std.testing.expect(via_read_branch != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&via_read_branch.?));

    // updateRef then reads back the same location, both functions must
    // agree on the "refs/heads/<branch>" path layout
    try updateRef(allocator, tmp.dir, "shared", hash_b);
    const via_update_ref = try readBranch(allocator, tmp.dir, "shared");
    try std.testing.expect(via_update_ref != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_b), std.mem.asBytes(&via_update_ref.?));
}

test "readBranch returns null for a branch that was never created" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No refs/heads/ directory exists at all yet
    const result = try readBranch(allocator, tmp.dir, "never-existed");
    try std.testing.expectEqual(@as(?Hash, null), result);
}

test "switching HEAD from detached to symbolic changes headBranch result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x55);

    try writeDetachedHead(allocator, tmp.dir, mock_hash);
    try std.testing.expectEqual(@as(?[]u8, null), try headBranch(allocator, tmp.dir));

    // "checkout main" — re-attach HEAD to a branch
    try writeHeadRef(tmp.dir, "main");
    const branch = try headBranch(allocator, tmp.dir);
    try std.testing.expect(branch != null);
    defer allocator.free(branch.?);
    try std.testing.expectEqualStrings("main", branch.?);
}

test "switching branches via writeHeadRef changes what resolveHead follows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var hash_main: Hash = undefined;
    @memset(std.mem.asBytes(&hash_main), 0x66);
    var hash_dev: Hash = undefined;
    @memset(std.mem.asBytes(&hash_dev), 0x77);

    try writeHeadRef(tmp.dir, "main");
    try updateRef(allocator, tmp.dir, "main", hash_main);

    try writeHeadRef(tmp.dir, "develop");
    try updateRef(allocator, tmp.dir, "develop", hash_dev);

    // HEAD is now on "develop" — resolveHead must follow the 'current'
    // symbolic target, not whichever branch was written first
    const resolved = try resolveHead(allocator, tmp.dir);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_dev), std.mem.asBytes(&resolved.?));
    try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&hash_main), std.mem.asBytes(&resolved.?)));

    // Switch back,  main's hash must still be intact and independently reachable
    try writeHeadRef(tmp.dir, "main");
    const resolved_main = try resolveHead(allocator, tmp.dir);
    try std.testing.expect(resolved_main != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_main), std.mem.asBytes(&resolved_main.?));
}

test "updateRef handles deeply nested branch names with multiple path segments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x88);

    // Three levels deep, beyond the single-level "feature/auth-fix" case
    // already covered, stresses makePath's recursive directory creation
    try updateRef(allocator, tmp.dir, "release/2026/q3-hardening", mock_hash);

    const read_hash = try readBranch(allocator, tmp.dir, "release/2026/q3-hardening");
    try std.testing.expect(read_hash != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));

    // And it must be resolvable via the symbolic-HEAD path too.
    try writeHeadRef(tmp.dir, "release/2026/q3-hardening");
    const resolved = try resolveHead(allocator, tmp.dir);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}

test "hash round-trip preserves non-uniform byte patterns" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mock_hash: Hash = undefined;
    for (std.mem.asBytes(&mock_hash), 0..) |*b, i| {
        b.* = @truncate(i);
    }

    try updateRef(allocator, tmp.dir, "main", mock_hash);
    const read_hash = try readBranch(allocator, tmp.dir, "main");
    try std.testing.expect(read_hash != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));
}

test "distinct branches with distinct hashes do not clobber each other" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var hash_a: Hash = undefined;
    @memset(std.mem.asBytes(&hash_a), 0x99);
    var hash_b: Hash = undefined;
    @memset(std.mem.asBytes(&hash_b), 0xEE);
    var hash_c: Hash = undefined;
    @memset(std.mem.asBytes(&hash_c), 0xFF);

    try updateRef(allocator, tmp.dir, "main", hash_a);
    try updateRef(allocator, tmp.dir, "develop", hash_b);
    try updateRef(allocator, tmp.dir, "feature/x", hash_c);

    const ra = try readBranch(allocator, tmp.dir, "main");
    const rb = try readBranch(allocator, tmp.dir, "develop");
    const rc = try readBranch(allocator, tmp.dir, "feature/x");

    try std.testing.expect(ra != null and rb != null and rc != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_a), std.mem.asBytes(&ra.?));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_b), std.mem.asBytes(&rb.?));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&hash_c), std.mem.asBytes(&rc.?));
}

test "writeHeadRef followed by writeDetachedHead correctly overwrites symbolic state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0x12);

    try writeHeadRef(tmp.dir, "main");

    const branch = try headBranch(allocator, tmp.dir);
    try std.testing.expect(branch != null);
    if (branch) |b| allocator.free(b);

    // Detach HEAD directly onto a commit — must fully replace the
    // symbolic "ref: refs/heads/main" contents, not append/merge with it.
    try writeDetachedHead(allocator, tmp.dir, mock_hash);

    const branch_detached = try headBranch(allocator, tmp.dir);
    defer if (branch_detached) |b| allocator.free(b);
    try std.testing.expectEqual(@as(?[]u8, null), branch_detached);

    const resolved = try resolveHead(allocator, tmp.dir);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}
