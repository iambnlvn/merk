const std = @import("std");
const merkle_mod = @import("merkle");
const storage = @import("storage");
const crypto = @import("crypto");
const Hash = crypto.Hash;

const repo_mod = @import("./repo.zig");
const Repository = repo_mod.Repository;
const commit_mod = @import("../commit.zig");

const MemoryFs = storage.MemoryFs;
const OsFs = storage.OsFs;
fn testRequest(title: []const u8, timestamp_ms: i64) repo_mod.CommitRequest {
    return .{
        .author_name = "bnlvn",
        .author_email = "bnlvn@merk.dev",
        .author_timestamp_ms = timestamp_ms,
        .intent = .feature,
        .title = title,
    };
}

/// Append entries directly to `repo.staging` and save — bypasses `add`'s
/// worktree read (`Index.addFile` goes through `std.fs.cwd()`, so
/// exercising it needs a real tmpDir; these tests only need entries to
/// exist for commit/status/reset to operate on).
fn stageFakeEntry(repo: *Repository, path: []const u8, content: []const u8) !void {
    try repo.staging.put(.{
        .path = try repo.alloc.dupe(u8, path),
        .blob_hash = crypto.blake3(content),
        .size = content.len,
        .mode = 0o100644,
        .mtime = 1,
    });
    try repo.staging.save();
}

test "Repository.init sets up an empty repo focused on main, and refuses a second init" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try std.testing.expectEqualStrings("main", repo.channel.raw);
    try std.testing.expectEqual(@as(usize, 0), repo.staging.count());

    try std.testing.expectError(error.AlreadyInitialized, Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{}));
}

test "Repository.init with force reinitializes over an existing repo instead of erroring" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    {
        const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
        const repo = init_res.repository;
        defer repo.deinit();
        try stageFakeEntry(repo, "a.txt", "one");
        try std.testing.expectEqual(@as(usize, 1), repo.staging.count());
    }

    const reinit_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{ .force = true });
    const reinit = reinit_res.repository;
    defer reinit.deinit();

    try std.testing.expectEqualStrings("main", reinit.channel.raw);
    try std.testing.expectEqual(@as(usize, 0), reinit.staging.count());
}

test "Repository.open fails on a directory with no Focus yet" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    try std.testing.expectError(error.NotARepository, Repository.open(alloc, mem_fs.fs(), "/tmp/does-not-matter"));
}

test "Repository.open round-trips an initialized repo's current track" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    {
        const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
        defer init_res.repository.deinit();
    }

    const reopened = try Repository.open(alloc, mem_fs.fs(), "/tmp/does-not-matter");
    defer reopened.deinit();
    try std.testing.expectEqualStrings("main", reopened.channel.raw);
}

test "commit advances the current track and status goes clean against HEAD" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "hello");

    var pre_status = try repo.status();
    defer pre_status.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), pre_status.staged.len);
    try std.testing.expectEqual(merkle_mod.ChangeKind.added, pre_status.staged[0].kind);

    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    const h = try repo.current();
    try std.testing.expect(h != null);
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));

    var post_status = try repo.status();
    defer post_status.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), post_status.staged.len);
}

test "commit chains parents across two commits and log walks both" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    const c2 = try repo.commit(testRequest("add b.txt", 2000));

    var walk = (try repo.log(.all)).?;
    defer walk.deinit();

    var seen: std.ArrayList(Hash) = .empty;
    defer seen.deinit(alloc);
    while (try walk.next()) |h| try seen.append(alloc, h);

    try std.testing.expectEqual(@as(usize, 2), seen.items.len);
    try std.testing.expect(merkle_mod.hashEq(seen.items[0], c2));
    try std.testing.expect(merkle_mod.hashEq(seen.items[1], c1));
}

test "reset soft moves the track without touching the staging area" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    _ = try repo.commit(testRequest("add b.txt", 2000));

    try repo.reset(.{ .target = c1, .mode = .soft });

    const h = try repo.current();
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));
    // Soft reset leaves the staging area (still holding both entries) alone.
    try std.testing.expectEqual(@as(usize, 2), repo.staging.count());
}

test "reset mixed rebuilds the staging area to match the target commit's snapshot" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    _ = try repo.commit(testRequest("add b.txt", 2000));

    // .mixed is ResetOptions' default, so the mode field can be omitted.
    try repo.reset(.{ .target = c1 });

    try std.testing.expectEqual(@as(usize, 1), repo.staging.count());
    try std.testing.expectEqualStrings("a.txt", repo.staging.allEntries()[0].path);

    const h = try repo.current();
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));
}

test "diffCommits reports the added path between two commit snapshots" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    const c2 = try repo.commit(testRequest("add b.txt", 2000));

    var c1_commit = try commit_mod.read(alloc, &repo.store, c1);
    defer c1_commit.deinit(alloc);
    var c2_commit = try commit_mod.read(alloc, &repo.store, c2);
    defer c2_commit.deinit(alloc);

    const changes = try repo.diffCommits(c1_commit.snapshot, c2_commit.snapshot);
    defer merkle_mod.freeChanges(alloc, changes);

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("b.txt", changes[0].path);
    try std.testing.expectEqual(merkle_mod.ChangeKind.added, changes[0].kind);
}

test "add stages a real worktree file and status reports it, then commit clears it" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "hi there" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);

    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"hello.txt"});

    var st = try repo.status();
    defer st.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), st.staged.len);
    try std.testing.expectEqualStrings("hello.txt", st.staged[0].path);
    try std.testing.expectEqual(@as(usize, 0), st.unstaged.len);

    _ = try repo.commit(testRequest("add hello.txt", 1000));

    var post = try repo.status();
    defer post.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), post.staged.len);
    try std.testing.expectEqual(@as(usize, 0), post.unstaged.len);
}

test "add rejects absolute paths and paths that escape the repo root" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try std.testing.expectError(error.AbsolutePath, repo.add(&.{"/etc/passwd"}));
    try std.testing.expectError(error.PathEscapesRoot, repo.add(&.{"../outside.txt"}));
}

test "restorePaths rewrites a modified worktree file back to the staged blob" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "hi there" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"hello.txt"});

    // Simulate an unwanted edit made after staging
    try worktree_tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "an unwanted edit" });

    try repo.restorePaths(&.{"hello.txt"});

    const restored = try worktree_tmp.dir.readFileAlloc(alloc, "hello.txt", 1024);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("hi there", restored);
}

test "restorePaths errors on an untracked path without touching anything" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try std.testing.expectError(error.NotTracked, repo.restorePaths(&.{"never-added.txt"}));
}

test "restorePaths rejects path traversal attempts" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try std.testing.expectError(error.PathEscapesRoot, repo.restorePaths(&.{"../outside.txt"}));
}

test "restorePaths automatically creates missing parent directories" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    // Create a file in a nested subdirectory, stage it, then delete the subdirectory
    try worktree_tmp.dir.makePath("nested/deep");
    try worktree_tmp.dir.writeFile(.{ .sub_path = "nested/deep/file.txt", .data = "nested content" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"nested/deep/file.txt"});

    // Delete the nested directory structure completely from the worktree
    try worktree_tmp.dir.deleteTree("nested");

    // Restore paths should automatically recreate missing parent directories and write the file
    try repo.restorePaths(&.{"nested/deep/file.txt"});

    const restored = try worktree_tmp.dir.readFileAlloc(alloc, "nested/deep/file.txt", 1024);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("nested content", restored);
}

test "restorePaths errors when target path is occupied by a directory" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "conflict.txt", .data = "original data" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"conflict.txt"});

    // Delete the file and replace it with a directory of the exact same name
    try worktree_tmp.dir.deleteFile("conflict.txt");
    try worktree_tmp.dir.makeDir("conflict.txt");

    try std.testing.expectError(error.IsADirectory, repo.restorePaths(&.{"conflict.txt"}));
}

test "restorePaths successfully overwrites read-only files" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "locked.txt", .data = "initial content" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"locked.txt"});

    // Modify content and simulate a read-only permission restriction on Unix systems
    try worktree_tmp.dir.writeFile(.{ .sub_path = "locked.txt", .data = "unwanted modification" });

    const full_path = try std.fs.path.join(alloc, &.{ worktree_root, "locked.txt" });
    defer alloc.free(full_path);

    var locked_file = try std.fs.cwd().openFile(full_path, .{ .mode = .read_write });
    defer locked_file.close();
    // Set file permissions to read-only (chmod 444 equivalent)
    try locked_file.chmod(0o444);

    // Restoration should bypass or handle the read-only constraint cleanly by unlinking
    try repo.restorePaths(&.{"locked.txt"});

    const restored = try worktree_tmp.dir.readFileAlloc(alloc, "locked.txt", 1024);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("initial content", restored);
}

test "restorePaths errors when blob hash is missing from object store" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "ghost.txt", .data = "some content" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"ghost.txt"});

    const entry = repo.staging.lookup("ghost.txt").?;
    const blob_hash = entry.blob_hash;

    // delete the backing blob file directly via the store's on-disk
    // layout: "objects/xx/yy/<64-char hex hash>" (see Store.objectPath /
    // ComponentDir.shardedPath).
    var hex_buf: [64]u8 = undefined;
    const hex = try std.fmt.bufPrint(&hex_buf, "{x}", .{blob_hash});

    const shard_path = try std.fmt.allocPrint(
        alloc,
        "objects/{s}/{s}/{s}",
        .{ hex[0..2], hex[2..4], hex },
    );

    defer alloc.free(shard_path);

    try control_tmp.dir.deleteFile(shard_path);

    // attempting to restore should now fail because the underlying blob is missing
    try std.testing.expectError(error.BlobMissing, repo.restorePaths(&.{"ghost.txt"}));
}
test "removePaths deletes the worktree file by default, --cached leaves it" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "a" });
    try worktree_tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "b" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{ "a.txt", "b.txt" });

    try repo.removePaths(&.{"a.txt"}, .{ .cached = true });
    try std.testing.expect(repo.staging.lookup("a.txt") == null);
    // --cached: worktree file survives.
    try worktree_tmp.dir.access("a.txt", .{});

    try repo.removePaths(&.{"b.txt"}, .{});
    try std.testing.expect(repo.staging.lookup("b.txt") == null);
    try std.testing.expectError(error.FileNotFound, worktree_tmp.dir.access("b.txt", .{}));
}

test "movePath renames on disk and in the staging area, preserving content" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "old.txt", .data = "content" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"old.txt"});
    try repo.movePath("old.txt", "new.txt", .{});

    try std.testing.expect(repo.staging.lookup("old.txt") == null);
    try std.testing.expect(repo.staging.lookup("new.txt") != null);
    try std.testing.expectError(error.FileNotFound, worktree_tmp.dir.access("old.txt", .{}));

    const moved = try worktree_tmp.dir.readFileAlloc(alloc, "new.txt", 1024);
    defer alloc.free(moved);
    try std.testing.expectEqualStrings("content", moved);
}

test "movePath refuses an already-tracked destination without force" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "a" });
    try worktree_tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "b" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{ "a.txt", "b.txt" });

    try std.testing.expectError(error.DestinationTracked, repo.movePath("a.txt", "b.txt", .{}));
    // force lets it through and overwrites the tracked destination.
    try repo.movePath("a.txt", "b.txt", .{ .force = true });
    try std.testing.expect(repo.staging.lookup("a.txt") == null);
}

test "uncommit on a normal commit moves the track to its parent" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    const c2 = try repo.commit(testRequest("add b.txt", 2000));

    const result = try repo.uncommit(.{});
    try std.testing.expect(merkle_mod.hashEq(result.undone, c2));
    try std.testing.expect(result.new_current != null);
    try std.testing.expect(merkle_mod.hashEq(result.new_current.?, c1));

    const h = try repo.current();
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));
    // Soft undo: staging area still holds both entries, ready to re-commit
    try std.testing.expectEqual(@as(usize, 2), repo.staging.count());
}

test "uncommit on the root commit deletes the track ref, returning to 'no commits'" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    const result = try repo.uncommit(.{});
    try std.testing.expect(merkle_mod.hashEq(result.undone, c1));
    try std.testing.expectEqual(@as(?Hash, null), result.new_current);

    try std.testing.expectEqual(@as(?Hash, null), try repo.current());

    // Re-committing goes through the same root-commit path as the first time
    const c1_again = try repo.commit(testRequest("add a.txt again", 3000));
    try std.testing.expect(try repo.current() != null);
    _ = c1_again;
}

test "uncommit errors with NoCommits when the track has never been committed to" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try std.testing.expectError(error.NoCommits, repo.uncommit(.{}));
}

test "uncommit keep preserves a post-commit worktree edit as the new staged content" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "hello" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"hello.txt"});
    const c1 = try repo.commit(testRequest("add hello.txt", 1000));

    // Edit made after the commit — this is the change `.keep` must preserve.
    try worktree_tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "hello world" });

    const result = try repo.uncommit(.{ .mode = .keep });
    try std.testing.expect(merkle_mod.hashEq(result.undone, c1));
    try std.testing.expectEqual(@as(?Hash, null), result.new_current);
    try std.testing.expectEqual(@as(?Hash, null), try repo.current());

    try std.testing.expectEqual(@as(usize, 1), repo.staging.count());
    const entry = repo.staging.lookup("hello.txt").?;

    // Verify by content through the store, not by hand-computing the
    // hash — `addFile`/`store.putReader` hash type+size+content (or
    // similar object framing), not raw `blake3(content)`, so those two
    // will never be equal. Content round-trip is what actually matters.
    const obj = try repo.store.get(entry.blob_hash);
    defer alloc.free(obj.payload);
    try std.testing.expectEqualStrings("hello world", obj.payload);

    // Also confirm it's NOT still pointing at the original "hello" blob.
    try std.testing.expect(!merkle_mod.hashEq(entry.blob_hash, crypto.blake3("hello")));
}

test "uncommit keep errors with TrackedPathsMissing and touches nothing when a tracked file was deleted" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "one" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"a.txt"});
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    // Simulate a deliberate refactor/cleanup deletion after the commit.
    try worktree_tmp.dir.deleteFile("a.txt");

    try std.testing.expectError(error.TrackedPathsMissing, repo.uncommit(.{ .mode = .keep }));

    // Nothing moved: ref, staging, and the (already-deleted) file's
    // tracked status are all exactly as they were before the call.
    const h = try repo.current();
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));
    try std.testing.expectEqual(@as(usize, 1), repo.staging.count());
    try std.testing.expect(repo.staging.lookup("a.txt") != null);
}

test "uncommit mixed with a parent rebuilds staging to match the parent's committed tree" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    const c2 = try repo.commit(testRequest("add b.txt", 2000));

    const result = try repo.uncommit(.{ .mode = .mixed });
    try std.testing.expect(merkle_mod.hashEq(result.undone, c2));
    try std.testing.expect(merkle_mod.hashEq(result.new_current.?, c1));

    const h = try repo.current();
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));
    try std.testing.expectEqual(@as(usize, 1), repo.staging.count());
    try std.testing.expectEqualStrings("a.txt", repo.staging.allEntries()[0].path);
}

test "uncommit mixed on the root commit clears staging entirely (no parent tree to rebuild from)" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    const result = try repo.uncommit(.{ .mode = .mixed });
    try std.testing.expect(merkle_mod.hashEq(result.undone, c1));
    try std.testing.expectEqual(@as(?Hash, null), result.new_current);

    try std.testing.expectEqual(@as(?Hash, null), try repo.current());
    try std.testing.expectEqual(@as(usize, 0), repo.staging.count());
}

test "uncommit hard with a parent rewrites the worktree to match the parent's content" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "one" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"a.txt"});
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try worktree_tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "two" });
    try repo.add(&.{"b.txt"});
    _ = try repo.commit(testRequest("add b.txt", 2000));

    const result = try repo.uncommit(.{ .mode = .hard });
    try std.testing.expect(merkle_mod.hashEq(result.new_current.?, c1));

    // Staging rebuilt from c1's tree: only a.txt is tracked now.
    try std.testing.expectEqual(@as(usize, 1), repo.staging.count());
    try std.testing.expect(repo.staging.lookup("a.txt") != null);
    try std.testing.expect(repo.staging.lookup("b.txt") == null);

    // reset(.hard)'s worktree rewrite only writes currently-staged
    // entries; it doesn't delete files that fell out of staging, so
    // b.txt is expected to still exist on disk, just untracked.
    const a_content = try worktree_tmp.dir.readFileAlloc(alloc, "a.txt", 1024);
    defer alloc.free(a_content);
    try std.testing.expectEqualStrings("one", a_content);
}

test "uncommit hard on the root commit requires confirm_root_hard and otherwise touches nothing" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "one" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"a.txt"});
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try std.testing.expectError(
        error.RootHardUncommitRequiresConfirmation,
        repo.uncommit(.{ .mode = .hard }),
    );

    // Refused before touching the ref, staging, or the worktree file.
    const h = try repo.current();
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));
    try std.testing.expectEqual(@as(usize, 1), repo.staging.count());
    try worktree_tmp.dir.access("a.txt", .{});
}

test "uncommit hard on the root commit with confirm_root_hard deletes tracked files and clears state" {
    const alloc = std.testing.allocator;

    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var worktree_tmp = std.testing.tmpDir(.{});
    defer worktree_tmp.cleanup();

    try worktree_tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "one" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_tmp.dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_tmp.dir);
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try repo.add(&.{"a.txt"});
    _ = try repo.commit(testRequest("add a.txt", 1000));

    const result = try repo.uncommit(.{ .mode = .hard, .confirm_root_hard = true });
    try std.testing.expectEqual(@as(?Hash, null), result.new_current);

    try std.testing.expectEqual(@as(?Hash, null), try repo.current());
    try std.testing.expectEqual(@as(usize, 0), repo.staging.count());
    try std.testing.expectError(error.FileNotFound, worktree_tmp.dir.access("a.txt", .{}));
}

test "resolveRev accepts a full hash and rejects garbage" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const init_res = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    const hex = try crypto.toHex(alloc, c1);
    defer alloc.free(hex);

    const resolved = try repo.resolveRev(hex);
    try std.testing.expect(merkle_mod.hashEq(resolved, c1));

    try std.testing.expectError(error.RevNotFound, repo.resolveRev("deadbeef"));
}

test "describe covers every RepositoryError with a non-empty message" {
    // The switch inside `describe` is exhaustive over `RepositoryError`
    // at compile time; this just spot-checks a couple of variants
    // actually read sensibly.
    try std.testing.expect(repo_mod.describe(error.NotTracked).len > 0);
    try std.testing.expect(repo_mod.describe(error.AmbiguousRev).len > 0);
    try std.testing.expectEqualStrings(
        "path is not tracked",
        repo_mod.describe(error.NotTracked),
    );
}
