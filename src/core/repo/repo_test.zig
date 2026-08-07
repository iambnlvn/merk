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

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    defer repo.deinit();

    try std.testing.expectEqualStrings("main", repo.current_track.raw);
    try std.testing.expectEqual(@as(usize, 0), repo.staging.count());

    try std.testing.expectError(error.AlreadyInitialized, Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{}));
}

test "Repository.init with force reinitializes over an existing repo instead of erroring" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    {
        const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
        defer repo.deinit();
        try stageFakeEntry(repo, "a.txt", "one");
        try std.testing.expectEqual(@as(usize, 1), repo.staging.count());
    }

    const reinit = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{ .force = true });
    defer reinit.deinit();

    try std.testing.expectEqualStrings("main", reinit.current_track.raw);
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
        const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
        defer repo.deinit();
    }

    const reopened = try Repository.open(alloc, mem_fs.fs(), "/tmp/does-not-matter");
    defer reopened.deinit();
    try std.testing.expectEqualStrings("main", reopened.current_track.raw);
}

test "commit advances the current track and status goes clean against HEAD" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "hello");

    var pre_status = try repo.status();
    defer pre_status.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), pre_status.staged.len);
    try std.testing.expectEqual(merkle_mod.ChangeKind.added, pre_status.staged[0].kind);

    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    const h = try repo.head();
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

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
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

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    _ = try repo.commit(testRequest("add b.txt", 2000));

    try repo.reset(.{ .target = c1, .mode = .soft });

    const h = try repo.head();
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));
    // Soft reset leaves the staging area (still holding both entries) alone.
    try std.testing.expectEqual(@as(usize, 2), repo.staging.count());
}

test "reset mixed rebuilds the staging area to match the target commit's snapshot" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    _ = try repo.commit(testRequest("add b.txt", 2000));

    // .mixed is ResetOptions' default, so the mode field can be omitted.
    try repo.reset(.{ .target = c1 });

    try std.testing.expectEqual(@as(usize, 1), repo.staging.count());
    try std.testing.expectEqualStrings("a.txt", repo.staging.allEntries()[0].path);

    const h = try repo.head();
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));
}

test "diffCommits reports the added path between two commit snapshots" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
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

    const repo = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
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

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
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
    const repo = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
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

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    defer repo.deinit();

    try std.testing.expectError(error.NotTracked, repo.restorePaths(&.{"never-added.txt"}));
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
    const repo = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
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
    const repo = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
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
    const repo = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
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

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    const c2 = try repo.commit(testRequest("add b.txt", 2000));

    const result = try repo.uncommit();
    try std.testing.expect(merkle_mod.hashEq(result.undone, c2));
    try std.testing.expect(result.new_head != null);
    try std.testing.expect(merkle_mod.hashEq(result.new_head.?, c1));

    const h = try repo.head();
    try std.testing.expect(merkle_mod.hashEq(h.?, c1));
    // Soft undo: staging area still holds both entries, ready to re-commit
    try std.testing.expectEqual(@as(usize, 2), repo.staging.count());
}

test "uncommit on the root commit deletes the track ref, returning to 'no commits'" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    const result = try repo.uncommit();
    try std.testing.expect(merkle_mod.hashEq(result.undone, c1));
    try std.testing.expectEqual(@as(?Hash, null), result.new_head);

    try std.testing.expectEqual(@as(?Hash, null), try repo.head());

    // Re-committing goes through the same root-commit path as the first time
    const c1_again = try repo.commit(testRequest("add a.txt again", 3000));
    try std.testing.expect(try repo.head() != null);
    _ = c1_again;
}

test "uncommit errors with NoCommits when the track has never been committed to" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
    defer repo.deinit();

    try std.testing.expectError(error.NoCommits, repo.uncommit());
}

test "resolveRev accepts a full hash and rejects garbage" {
    const alloc = std.testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const repo = try Repository.init(alloc, mem_fs.fs(), "/tmp/does-not-matter", .{});
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
