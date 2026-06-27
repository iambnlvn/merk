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

test "resolveHead - missing HEAD file handles gracefully" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try resolveHead(allocator, tmp.dir);
    try std.testing.expectEqual(@as(?Hash, null), result);
}

test "writeDetachedHead and resolveHead detached lifecycle" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0xAA);

    // Write the detached head state
    try writeDetachedHead(allocator, tmp.dir, mock_hash);

    // headBranch should return null when detached
    const branch = try headBranch(allocator, tmp.dir);
    try std.testing.expectEqual(@as(?[]u8, null), branch);

    // Resolve HEAD directly back to the mock hash
    const resolved = try resolveHead(allocator, tmp.dir);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}

test "resolveHead - symbolic ref pointing to a non-existent branch" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Point HEAD symbolically to a branch that has no file yet
    try writeHeadRef(tmp.dir, "main");

    // headBranch should still parse the name "main" successfully
    const branch = try headBranch(allocator, tmp.dir);
    try std.testing.expect(branch != null);
    defer allocator.free(branch.?);
    try std.testing.expectEqualStrings("main", branch.?);

    // resolveHead should return null gracefully because refs/heads/main doesn't exist
    const resolved = try resolveHead(allocator, tmp.dir);
    try std.testing.expectEqual(@as(?Hash, null), resolved);
}

test "Symbolic branch ref full lifecycle forwarding" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0xBB);

    //  Link HEAD to a development branch
    try writeHeadRef(tmp.dir, "develop");

    //  Commit a hash onto the branch target
    try updateBranch(allocator, tmp.dir, "develop", mock_hash);

    //  Confirm reading the branch directly works
    const read_hash = try readBranch(allocator, tmp.dir, "develop");
    try std.testing.expect(read_hash != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));

    // Confirm resolveHead correctly follows the symbolic link to find the hash
    const resolved = try resolveHead(allocator, tmp.dir);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));
}

test "updateRef and deep directories layout verification" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0xCC);

    // updateRef handles deeper nested names like "feature/auth-fix" safely
    try updateRef(allocator, tmp.dir, "feature/auth-fix", mock_hash);

    const read_hash = try readBranch(allocator, tmp.dir, "feature/auth-fix");
    try std.testing.expect(read_hash != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&read_hash.?));
}

test "Whitespace and newline parsing robustness" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mock_hash: Hash = undefined;
    @memset(std.mem.asBytes(&mock_hash), 0xDD);

    // Manually inject annoying whitespace padding into the symbolic HEAD layout
    try writeFile(tmp.dir, "HEAD", "  ref: refs/heads/feature-xyz   \n\r");

    //  Manually write the hash with aggressive padding, tabs, and line breaks
    const hex = try hash_mod.toHex(allocator, mock_hash);
    defer allocator.free(hex);

    var dirty_hex_buf: [128]u8 = undefined;
    const dirty_hex = try std.fmt.bufPrint(&dirty_hex_buf, "\t\n  {s} \r\n", .{hex});
    try writeFile(tmp.dir, "refs/heads/feature-xyz", dirty_hex);

    // Assert your trim functions perfectly sanitize the input boundaries
    const resolved = try resolveHead(allocator, tmp.dir);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&mock_hash), std.mem.asBytes(&resolved.?));

    const branch = try headBranch(allocator, tmp.dir);
    try std.testing.expect(branch != null);
    defer allocator.free(branch.?);
    try std.testing.expectEqualStrings("feature-xyz", branch.?);
}
