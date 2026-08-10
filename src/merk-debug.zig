//! Debug/test harness for `Repository` — exercises the whole system
//! directly, bypassing the CLI entirely. Not part of the normal build;
//! wire it up as its own executable target (see notes at the bottom of
//! this file) and run it standalone.
//!
//! Every step logs: current channel, HEAD, staging contents, disk
//! contents, and `status()`'s staged/unstaged view. The commit graph is
//! redrawn as ASCII after every commit-graph-changing operation.

const repo_mod = @import("./core/repository.zig");

const std = @import("std");
const storage = @import("storage");
const crypto = @import("crypto");
const merkle_mod = @import("merkle");
const commit_mod = @import("core/commit.zig");
const CommitRequest = @import("./core/commit.zig").CommitRequest;
const Repository = repo_mod.Repository;
const OsFs = storage.OsFs;
const Hash = crypto.Hash;

const SANDBOX = ".merk-debug";
const CONTROL_DIR = SANDBOX ++ "/control";
const WORKTREE_DIR = SANDBOX ++ "/worktree";

var out_buf: [16384]u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) std.debug.print("\n!! MEMORY LEAK DETECTED !!\n", .{});
    }
    const alloc = gpa.allocator();

    std.fs.cwd().deleteTree(SANDBOX) catch {};
    try std.fs.cwd().makePath(CONTROL_DIR);
    try std.fs.cwd().makePath(WORKTREE_DIR);
    defer std.fs.cwd().deleteTree(SANDBOX) catch {};

    var control_dir = try std.fs.cwd().openDir(CONTROL_DIR, .{});
    defer control_dir.close();
    var worktree_dir = try std.fs.cwd().openDir(WORKTREE_DIR, .{});
    defer worktree_dir.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worktree_root = try worktree_dir.realpath(".", &path_buf);

    var control_fs = OsFs.init(control_dir);

    header("PHASE 0 — init");
    const init_res = try Repository.init(alloc, control_fs.fs(), worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();
    print("action: {s}\n", .{@tagName(init_res.action)});
    try logState(alloc, repo);

    // PHASE 1 — add + first commit
    header("PHASE 1 — write a.txt=\"hello\", add, commit A");
    try worktree_dir.writeFile(.{ .sub_path = "a.txt", .data = "hello" });
    try repo.add(&.{"a.txt"});
    try logState(alloc, repo);

    const c1 = try repo.commit(request("add a.txt", 1000));
    const c1_hex = try hex(alloc, c1);
    defer alloc.free(c1_hex);
    print("commit A = {s}\n", .{c1_hex});
    try logState(alloc, repo);
    try drawTree(alloc, repo);

    // PHASE 2 — the staleness scenario: edit after commit, no re-add

    header("PHASE 2 — edit a.txt -> \"hello world\" on disk, WITHOUT re-adding");
    try worktree_dir.writeFile(.{ .sub_path = "a.txt", .data = "hello world" });
    try logState(alloc, repo);
    print("^ note: staging still says \"hello\" — status() should show\n", .{});
    print("  a.txt as clean in `staged` but modified in `unstaged`.\n", .{});

    // PHASE 3 — second commit, second file

    header("PHASE 3 — add b.txt, commit B");
    try worktree_dir.writeFile(.{ .sub_path = "b.txt", .data = "two" });
    try repo.add(&.{"b.txt"});
    const c2 = try repo.commit(request("add b.txt", 2000));
    const c2_hex = try hex(alloc, c2);
    defer alloc.free(c2_hex);
    print("commit B = {s}\n", .{c2_hex});
    try logState(alloc, repo);
    try drawTree(alloc, repo);

    // PHASE 4 — diffing

    header("PHASE 4 — diffCommits(A, B) and diffStaged()");
    var ca = try commit_mod.read(alloc, &repo.store, c1);
    defer ca.deinit(alloc);
    var cb = try commit_mod.read(alloc, &repo.store, c2);
    defer cb.deinit(alloc);

    const commit_diff = try repo.diffCommits(ca.snapshot, cb.snapshot);
    defer merkle_mod.freeChanges(alloc, commit_diff);
    print("diffCommits(A -> B): {d} change(s)\n", .{commit_diff.len});
    for (commit_diff) |ch| print("  {s} {s}\n", .{ @tagName(ch.kind), ch.path });

    const staged_diff = try repo.diffStaged();
    defer merkle_mod.freeChanges(alloc, staged_diff);
    print("diffStaged() (HEAD=B vs current staging): {d} change(s)\n", .{staged_diff.len});
    for (staged_diff) |ch| print("  {s} {s}\n", .{ @tagName(ch.kind), ch.path });

    // PHASE 5 — reset, all three modes (soft/mixed/hard), each
    // demonstrated then undone back to B so later phases start clean.

    header("PHASE 5a — reset(target=A, .soft)");
    try repo.reset(.{ .target = c1, .mode = .soft });
    try logState(alloc, repo);
    print("^ ref moved to A, staging/worktree untouched (still B's content)\n", .{});

    header("PHASE 5a-undo — reset back to B, .soft, to restore starting point");
    try repo.reset(.{ .target = c2, .mode = .soft });
    try logState(alloc, repo);

    header("PHASE 5b — reset(target=A, .mixed)");
    try repo.reset(.{ .target = c1, .mode = .mixed });
    try logState(alloc, repo);
    print("^ staging rebuilt to match A's tree (b.txt should be GONE from staging)\n", .{});

    header("PHASE 5c — reset(target=A, .hard)");
    try repo.reset(.{ .target = c1, .mode = .hard });
    try logState(alloc, repo);
    print("^ worktree rewritten to match A too — check a.txt content below\n", .{});
    try logWorktreeFile(worktree_dir, alloc, "a.txt");

    header("PHASE 5-restore — reset forward to B again, .hard, for later phases");
    try repo.reset(.{ .target = c2, .mode = .hard });
    try worktree_dir.writeFile(.{ .sub_path = "b.txt", .data = "two" }); // write BEFORE add
    try repo.add(&.{"b.txt"});
    try logState(alloc, repo);

    // PHASE 6 — reset error case: bad target must not move the ref

    header("PHASE 6 — reset with a bogus target hash (should fail, ref must not move)");
    const head_before = try repo.current();
    const bogus: Hash = crypto.blake3("this is not a real commit");
    const reset_result = repo.reset(.{ .target = bogus, .mode = .mixed });
    if (reset_result) |_| {
        print("UNEXPECTED: reset with a bogus target succeeded!\n", .{});
    } else |err| {
        print("got expected error: {s}\n", .{@errorName(err)});
    }
    const head_after = try repo.current();
    const before_hex = try hexOpt(alloc, head_before);
    defer alloc.free(before_hex);
    const after_hex = try hexOpt(alloc, head_after);
    defer alloc.free(after_hex);
    print(
        "HEAD before={s} after={s} (should be equal)\n",
        .{ before_hex, after_hex },
    );

    // PHASE 7 — restorePaths

    header("PHASE 7 — restorePaths: corrupt a.txt on disk, then restore from staging");
    try worktree_dir.writeFile(.{ .sub_path = "a.txt", .data = "OOPS UNWANTED EDIT" });
    try logWorktreeFile(worktree_dir, alloc, "a.txt");
    try repo.restorePaths(&.{"a.txt"});
    print("after restorePaths:\n", .{});
    try logWorktreeFile(worktree_dir, alloc, "a.txt");

    // PHASE 8 — uncommit, each mode, on isolated fresh mini-repos so
    // the destructive ones don't interfere with each other.

    header("PHASE 8 — uncommit modes (each on a fresh isolated repo)");
    try demoUncommit(alloc, .soft, "8a");
    try demoUncommit(alloc, .mixed, "8b");
    try demoUncommit(alloc, .hard_confirmed, "8c");
    try demoUncommit(alloc, .keep, "8d");
    try demoUncommitKeepRefusesOnMissingFile(alloc, "8e");
    try demoUncommitHardRootRefusesWithoutConfirm(alloc, "8f");

    header("DONE");
    print("all phases completed.\n", .{});
}

// Uncommit demos — isolated sandboxes per mode, since .mixed/.hard/.keep
// are all destructive to staging/worktree and shouldn't share state.

const UncommitDemoMode = enum { soft, mixed, hard_confirmed, keep };

fn demoUncommit(alloc: std.mem.Allocator, mode: UncommitDemoMode, label: []const u8) !void {
    header2(label, "uncommit demo: ", @tagName(mode));

    var sandbox: Sandbox = undefined;
    try isolatedSandbox(&sandbox, label);
    defer sandbox.cleanup();

    const init_res = try Repository.init(alloc, sandbox.control_fs.fs(), sandbox.worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try sandbox.worktree_dir.writeFile(.{ .sub_path = "a.txt", .data = "hello" });
    try repo.add(&.{"a.txt"});
    const c1 = try repo.commit(request("add a.txt", 1000));
    const c1_hex = try hex(alloc, c1);
    defer alloc.free(c1_hex);
    print("committed A = {s}\n", .{c1_hex});

    // The edit-after-commit scenario, same as PHASE 2, so `.keep` has
    // something meaningful to preserve.
    try sandbox.worktree_dir.writeFile(.{ .sub_path = "a.txt", .data = "hello world" });

    const opts: repo_mod.Repository.UncommitOptions = switch (mode) {
        .soft => .{ .mode = .soft },
        .mixed => .{ .mode = .mixed },
        .hard_confirmed => .{ .mode = .hard, .confirm_root_hard = true },
        .keep => .{ .mode = .keep },
    };

    const result = try repo.uncommit(opts);
    const undone_hex = try hex(alloc, result.undone);
    defer alloc.free(undone_hex);
    const new_head_hex = try hexOpt(alloc, result.new_current);
    defer alloc.free(new_head_hex);
    print("undone={s} new_head={s}\n", .{ undone_hex, new_head_hex });

    try logState(alloc, repo);
    try logWorktreeFile(sandbox.worktree_dir, alloc, "a.txt");
}

fn demoUncommitKeepRefusesOnMissingFile(alloc: std.mem.Allocator, label: []const u8) !void {
    header2(label, "uncommit demo: ", "keep, tracked file deleted from disk (must refuse)");

    var sandbox: Sandbox = undefined;
    try isolatedSandbox(&sandbox, label);
    defer sandbox.cleanup();

    const init_res = try Repository.init(alloc, sandbox.control_fs.fs(), sandbox.worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try sandbox.worktree_dir.writeFile(.{ .sub_path = "a.txt", .data = "one" });
    try repo.add(&.{"a.txt"});
    _ = try repo.commit(request("add a.txt", 1000));

    // Deliberate cleanup deletion — the case `.keep` must not silently paper over.
    try sandbox.worktree_dir.deleteFile("a.txt");

    const result = repo.uncommit(.{ .mode = .keep });
    if (result) |_| {
        print("UNEXPECTED: uncommit(.keep) succeeded despite a missing tracked file!\n", .{});
    } else |err| {
        print("got expected error: {s}\n", .{@errorName(err)});
    }
    try logState(alloc, repo);
    print("^ ref/staging must be UNCHANGED from before the call\n", .{});
}

fn demoUncommitHardRootRefusesWithoutConfirm(alloc: std.mem.Allocator, label: []const u8) !void {
    header2(label, "uncommit demo: ", "hard on root commit WITHOUT confirm_root_hard (must refuse)");

    var sandbox: Sandbox = undefined;
    try isolatedSandbox(&sandbox, label);
    defer sandbox.cleanup();

    const init_res = try Repository.init(alloc, sandbox.control_fs.fs(), sandbox.worktree_root, .{});
    const repo = init_res.repository;
    defer repo.deinit();

    try sandbox.worktree_dir.writeFile(.{ .sub_path = "a.txt", .data = "one" });
    try repo.add(&.{"a.txt"});
    _ = try repo.commit(request("add a.txt", 1000));

    const result = repo.uncommit(.{ .mode = .hard }); // confirm_root_hard defaults to false
    if (result) |_| {
        print("UNEXPECTED: root hard-uncommit succeeded without confirmation!\n", .{});
    } else |err| {
        print("got expected error: {s}\n", .{@errorName(err)});
    }
    try logState(alloc, repo);
    print("^ a.txt should still exist on disk, HEAD should still be A\n", .{});
    try logWorktreeFile(sandbox.worktree_dir, alloc, "a.txt");
}

// Isolated sandbox helper for the uncommit demos

const Sandbox = struct {
    root_buf: [256]u8 = undefined,
    root: []const u8 = &.{},
    control_dir: std.fs.Dir,
    worktree_dir: std.fs.Dir,
    control_fs: OsFs,
    worktree_root: []const u8 = &.{},
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn cleanup(self: *Sandbox) void {
        self.control_dir.close();
        self.worktree_dir.close();
        std.fs.cwd().deleteTree(self.root) catch {};
    }
};

fn isolatedSandbox(self: *Sandbox, label: []const u8) !void {
    self.root = try std.fmt.bufPrint(&self.root_buf, "{s}-{s}", .{ SANDBOX, label });

    const control_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/control", .{self.root});
    defer std.heap.page_allocator.free(control_path);
    const worktree_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/worktree", .{self.root});
    defer std.heap.page_allocator.free(worktree_path);

    std.fs.cwd().deleteTree(self.root) catch {};
    try std.fs.cwd().makePath(control_path);
    try std.fs.cwd().makePath(worktree_path);

    self.control_dir = try std.fs.cwd().openDir(control_path, .{});
    self.worktree_dir = try std.fs.cwd().openDir(worktree_path, .{});
    self.control_fs = OsFs.init(self.control_dir);
    self.worktree_root = try self.worktree_dir.realpath(".", &self.path_buf);
}

fn request(title: []const u8, ts: i64) CommitRequest {
    return .{
        .author_name = "debug-harness",
        .author_email = "debug@merk.local",
        .author_timestamp_ms = ts,
        .intent = .feature,
        .title = title,
    };
}

fn header(title: []const u8) void {
    print("\n{s}\n{s}\n", .{ title, "=" ** 70 });
}

fn header2(label: []const u8, prefix: []const u8, suffix: []const u8) void {
    print("\n[{s}] {s}{s}\n{s}\n", .{ label, prefix, suffix, "-" ** 70 });
}

fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn hex(alloc: std.mem.Allocator, h: Hash) ![]const u8 {
    return crypto.toHex(alloc, h);
}

fn hexOpt(alloc: std.mem.Allocator, h: ?Hash) ![]const u8 {
    return if (h) |hh| hex(alloc, hh) else try alloc.dupe(u8, "(none)");
}

/// Full state dump: channel, HEAD, staging entries, status() staged/
/// unstaged. This is the "log the state of everything" primitive every
/// phase above calls after a mutating operation.
fn logState(alloc: std.mem.Allocator, repo: *Repository) !void {
    const h = try repo.current();
    print("  channel: {s}\n", .{repo.channel.raw});
    const head_hex = try hexOpt(alloc, h);
    defer alloc.free(head_hex);
    print("  HEAD:    {s}\n", .{head_hex});

    print("  staging ({d} entries):\n", .{repo.staging.count()});
    for (repo.staging.allEntries()) |e| {
        const short = try hex(alloc, e.blob_hash);
        defer alloc.free(short);
        print("    {s}  blob={s}...  size={d}\n", .{ e.path, short[0..@min(12, short.len)], e.size });
    }

    var st = try repo.status();
    defer st.deinit(alloc);
    print("  status.staged ({d}):\n", .{st.staged.len});
    for (st.staged) |ch| print("    {s} {s}\n", .{ @tagName(ch.kind), ch.path });
    print("  status.unstaged ({d}):\n", .{st.unstaged.len});
    for (st.unstaged) |u| print("    {s} {s}\n", .{ @tagName(u.state), u.path });
}
fn logWorktreeFile(dir: std.fs.Dir, alloc: std.mem.Allocator, path: []const u8) !void {
    const content = dir.readFileAlloc(alloc, path, 1 << 20) catch |err| {
        print("  disk[{s}]: <error reading: {s}>\n", .{ path, @errorName(err) });
        return;
    };
    defer alloc.free(content);
    print("  disk[{s}] = \"{s}\"\n", .{ path, content });
}

/// Walks the full commit graph via `repo.log(.all)` and draws it as a
/// simple top-to-bottom ASCII chain. Handles linear history (the only
/// shape this harness ever produces); a real multi-parent renderer would
/// need to channel the drawing on `ParentKind`/multiple parents, which
/// isn't exercised here since `uncommit` refuses merge commits anyway.
fn drawTree(alloc: std.mem.Allocator, repo: *Repository) !void {
    print("\n  commit graph ({s}):\n", .{repo.channel.raw});
    var walk = (try repo.log(.all)) orelse {
        print("    (no commits yet)\n", .{});
        return;
    };
    defer walk.deinit();

    var hashes: std.ArrayList(Hash) = .empty;
    defer hashes.deinit(alloc);
    while (try walk.next()) |h| try hashes.append(alloc, h);

    // `log` walks newest-first; draw oldest-at-top like a normal history.
    var i: usize = hashes.items.len;
    while (i > 0) {
        i -= 1;
        const h = hashes.items[i];
        var c = try commit_mod.read(alloc, &repo.store, h);
        defer c.deinit(alloc);

        const short = try hex(alloc, h);
        defer alloc.free(short);

        const is_head = i == 0;
        const connector = if (i == hashes.items.len - 1) "  o " else "  |\n  o ";
        print("{s}{s}  \"{s}\"{s}\n", .{
            connector,
            short[0..8],
            c.message.title,
            if (is_head) "   <- HEAD" else "",
        });
    }
    print("\n", .{});
}
