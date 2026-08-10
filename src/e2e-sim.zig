//!WIP
//! This is NOT a `zig test` unit test. It's a standalone program that
//! spawns the *actual compiled* `merk` binary against a real temp
//! directory on disk and drives it through a realistic session: init,
//! writing files, staging, committing, diffing, moving, restoring,
//! unstaging, logging, inspecting, write-tree, and uncommit (soft /
//! mixed / hard), plus a couple of expected-failure paths (double init,
//! missing -m, staging a nonexistent file, committing nothing).
//!

const std = @import("std");

var pass_count: usize = 0;
var fail_count: usize = 0;

fn printCmd(argv: []const []const u8) void {
    std.debug.print("\nmerk", .{});
    for (argv) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});
}

fn record(ok: bool, label: []const u8) void {
    if (ok) {
        pass_count += 1;
        std.debug.print("  PASS  {s}\n", .{label});
    } else {
        fail_count += 1;
        std.debug.print("  FAIL  {s}\n", .{label});
    }
}

const RunResult = std.process.Child.RunResult;

/// Spawns `bin` with `argv` inside `cwd`, prints the invocation and its
/// output as it happens, and returns the captured result. Caller owns
/// result.stdout / result.stderr (free with `alloc`).
fn cli(
    alloc: std.mem.Allocator,
    bin: []const u8,
    cwd: []const u8,
    argv: []const []const u8,
) !RunResult {
    var full_argv = std.ArrayList([]const u8).empty;
    defer full_argv.deinit(alloc);
    try full_argv.append(alloc, bin);
    try full_argv.appendSlice(alloc, argv);

    printCmd(argv);

    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = full_argv.items,
        .cwd = cwd,
        .max_output_bytes = 8 * 1024 * 1024,
    });

    if (res.stdout.len > 0) std.debug.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) std.debug.print("[stderr] {s}", .{res.stderr});

    return res;
}

fn exitedZero(res: RunResult) bool {
    return switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn expectOk(res: RunResult, label: []const u8) void {
    record(exitedZero(res), label);
}

fn expectFail(res: RunResult, label: []const u8) void {
    record(!exitedZero(res), label);
}

fn expectOkAndContains(res: RunResult, needle: []const u8, label: []const u8) void {
    const ok = exitedZero(res) and std.mem.indexOf(u8, res.stdout, needle) != null;
    record(ok, label);
}

fn free(alloc: std.mem.Allocator, res: RunResult) void {
    alloc.free(res.stdout);
    alloc.free(res.stderr);
}

/// Writes `content` to `root/rel`, creating parent directories as needed.
fn writeFileIn(alloc: std.mem.Allocator, root: []const u8, rel: []const u8, content: []const u8) !void {
    const full = try std.fs.path.join(alloc, &.{ root, rel });
    defer alloc.free(full);
    if (std.fs.path.dirname(full)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    var file = try std.fs.cwd().createFile(full, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn readFileIn(alloc: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    const full = try std.fs.path.join(alloc, &.{ root, rel });
    defer alloc.free(full);
    var file = try std.fs.cwd().openFile(full, .{});
    defer file.close();
    return file.readToEndAlloc(alloc, 16 * 1024 * 1024);
}

fn fileExistsIn(root: []const u8, rel: []const u8, alloc: std.mem.Allocator) bool {
    const full = std.fs.path.join(alloc, &.{ root, rel }) catch return false;
    defer alloc.free(full);
    std.fs.cwd().access(full, .{}) catch return false;
    return true;
}

fn expectFileContains(alloc: std.mem.Allocator, root: []const u8, rel: []const u8, needle: []const u8, label: []const u8) void {
    const content = readFileIn(alloc, root, rel) catch {
        record(false, label);
        return;
    };
    defer alloc.free(content);
    record(std.mem.indexOf(u8, content, needle) != null, label);
}

fn expectExists(root: []const u8, rel: []const u8, alloc: std.mem.Allocator, label: []const u8) void {
    record(fileExistsIn(root, rel, alloc), label);
}

fn expectNotExists(root: []const u8, rel: []const u8, alloc: std.mem.Allocator, label: []const u8) void {
    record(!fileExistsIn(root, rel, alloc), label);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // program name

    const bin_arg = args.next() orelse {
        std.debug.print("usage: merk_e2e_sim <path-to-merk-binary> [--keep-tmp]\n", .{});
        std.process.exit(2);
    };

    var keep_tmp = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--keep-tmp")) keep_tmp = true;
    }

    const bin = try std.fs.cwd().realpathAlloc(alloc, bin_arg);
    defer alloc.free(bin);

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const rand = prng.random();
    const suffix = rand.int(u32);

    const root = try std.fmt.allocPrint(alloc, "/tmp/merk_e2e_{d}", .{suffix});
    defer alloc.free(root);
    try std.fs.makeDirAbsolute(root);
    defer if (!keep_tmp) std.fs.deleteTreeAbsolute(root) catch {};

    const root2 = try std.fmt.allocPrint(alloc, "/tmp/merk_e2e_root_{d}", .{suffix});
    defer alloc.free(root2);
    try std.fs.makeDirAbsolute(root2);
    defer if (!keep_tmp) std.fs.deleteTreeAbsolute(root2) catch {};

    std.debug.print("=== merk E2E simulation ===\n", .{});
    std.debug.print("binary: {s}\n", .{bin});
    std.debug.print("sandbox: {s}\n", .{root});

    {
        const r = try cli(alloc, bin, root, &.{"init"});
        defer free(alloc, r);
        expectOkAndContains(r, "Initialized merk repository", "init: fresh repo");
    }
    {
        const r = try cli(alloc, bin, root, &.{"init"});
        defer free(alloc, r);
        expectFail(r, "init: refuses to reinit without --force");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "init", "--force" });
        defer free(alloc, r);
        expectOkAndContains(r, "Reinitialized merk repository", "init --force: reinit succeeds");
    }

    try writeFileIn(alloc, root, "hello.txt", "Hello, merk!\n");
    try writeFileIn(alloc, root, "notes.md", "# Notes\n\nFirst line.\n");

    {
        const r = try cli(alloc, bin, root, &.{ "stage", "does-not-exist.txt" });
        defer free(alloc, r);
        expectFail(r, "stage: rejects a nonexistent path");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "stage", "hello.txt", "notes.md" });
        defer free(alloc, r);
        expectOk(r, "stage: hello.txt + notes.md");
    }
    {
        const r = try cli(alloc, bin, root, &.{"status"});
        defer free(alloc, r);
        expectOkAndContains(r, "Staged for next commit", "status: shows staged files");
    }
    {
        const r = try cli(alloc, bin, root, &.{"commit"});
        defer free(alloc, r);
        expectFail(r, "commit: rejects missing -m");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "commit", "-m", "Initial commit", "-i", "feature", "-l", "setup" });
        defer free(alloc, r);
        expectOkAndContains(r, "Commit created", "commit: initial commit");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "commit", "-m", "Nothing changed" });
        defer free(alloc, r);
        expectFail(r, "commit: refuses when nothing changed");
    }

    try writeFileIn(alloc, root, "hello.txt", "Hello, merk!\nSecond line.\n");

    {
        const r = try cli(alloc, bin, root, &.{"diff"});
        defer free(alloc, r);
        expectOk(r, "diff: working tree vs staging");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "stage", "hello.txt" });
        defer free(alloc, r);
        expectOk(r, "stage: update hello.txt");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "commit", "-m", "Update hello", "--trailer", "reviewed-by=Ada" });
        defer free(alloc, r);
        expectOkAndContains(r, "Commit created", "commit: update hello (with trailer)");
    }

    {
        const r = try cli(alloc, bin, root, &.{ "mv", "hello.txt", "archive/hello.txt" });
        defer free(alloc, r);
        expectOkAndContains(r, "renamed", "mv: hello.txt -> archive/hello.txt");
    }
    expectExists(root, "archive/hello.txt", alloc, "mv: destination file exists on disk");
    expectNotExists(root, "hello.txt", alloc, "mv: source file gone from disk");
    {
        const r = try cli(alloc, bin, root, &.{ "commit", "-m", "Move hello into archive" });
        defer free(alloc, r);
        expectOkAndContains(r, "Commit created", "commit: move");
    }

    // restore (working tree) — edit on disk without staging, then revert
    try writeFileIn(alloc, root, "notes.md", "scrambled\n");
    {
        const r = try cli(alloc, bin, root, &.{ "restore", "notes.md" });
        defer free(alloc, r);
        expectOkAndContains(r, "restored", "restore: reverts unstaged edit");
    }
    expectFileContains(alloc, root, "notes.md", "First line.", "restore: file content actually reverted");

    // unstage (git-rm-like) with --cached, and restore --staged (git-restore --staged-like)
    try writeFileIn(alloc, root, "temp.txt", "scratch\n");
    {
        const r = try cli(alloc, bin, root, &.{ "stage", "temp.txt" });
        defer free(alloc, r);
        expectOk(r, "stage: temp.txt");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "unstage", "--cached", "temp.txt" });
        defer free(alloc, r);
        expectOkAndContains(r, "removed (cached)", "unstage --cached: drops from staging only");
    }
    expectExists(root, "temp.txt", alloc, "unstage --cached: file still on disk");
    {
        const r = try cli(alloc, bin, root, &.{ "stage", "temp.txt" });
        defer free(alloc, r);
        expectOk(r, "stage: temp.txt again");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "restore", "--staged", "temp.txt" });
        defer free(alloc, r);
        expectOkAndContains(r, "unstaged", "restore --staged: unstages temp.txt");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "stage", "temp.txt" });
        defer free(alloc, r);
        expectOk(r, "stage: temp.txt a third time");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "unstage", "temp.txt" });
        defer free(alloc, r);
        expectOkAndContains(r, "removed temp.txt", "unstage (no --cached): drops from staging and disk");
    }
    expectNotExists(root, "temp.txt", alloc, "unstage: file actually deleted from disk");

    {
        const r = try cli(alloc, bin, root, &.{"write-tree"});
        defer free(alloc, r);
        const hex = std.mem.trim(u8, r.stdout, " \t\r\n");
        record(exitedZero(r) and hex.len == 64, "write-tree: prints a 64-char hex root");
    }
    {
        const r = try cli(alloc, bin, root, &.{"log"});
        defer free(alloc, r);
        expectOkAndContains(r, "commit ", "log: lists commits");
    }
    {
        const r = try cli(alloc, bin, root, &.{"inspect"});
        defer free(alloc, r);
        expectOkAndContains(r, "commit ", "inspect: HEAD vs parent");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "inspect", "--stat" });
        defer free(alloc, r);
        expectOk(r, "inspect --stat: change summary");
    }

    // uncommit: soft, then mixed, then hard — on non-root commits
    {
        const r = try cli(alloc, bin, root, &.{"uncommit"});
        defer free(alloc, r);
        expectOkAndContains(r, "undone", "uncommit (soft): undoes 'Move hello into archive'");
    }
    {
        const r = try cli(alloc, bin, root, &.{"status"});
        defer free(alloc, r);
        expectOkAndContains(r, "Staged for next commit", "status: soft-uncommitted change is still staged");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "commit", "-m", "Move hello into archive (redo)" });
        defer free(alloc, r);
        expectOkAndContains(r, "Commit created", "commit: redo the move");
    }
    {
        const r = try cli(alloc, bin, root, &.{ "uncommit", "--mixed" });
        defer free(alloc, r);
        expectOkAndContains(r, "undone", "uncommit --mixed: undoes the redo");
    }
    expectExists(root, "archive/hello.txt", alloc, "uncommit --mixed: working tree untouched, file still present");
    {
        const r = try cli(alloc, bin, root, &.{ "uncommit", "--hard" });
        defer free(alloc, r);
        expectOkAndContains(r, "undone", "uncommit --hard: undoes 'Update hello'");
    }
    expectNotExists(root, "archive/hello.txt", alloc, "uncommit --hard: working tree actually reverted");

    // -- Part B: root-commit hard-uncommit requires --yes (separate sandbox) --

    std.debug.print("\n--- Part B: root-commit --hard confirmation (sandbox: {s}) ---\n", .{root2});
    {
        const r = try cli(alloc, bin, root2, &.{"init"});
        defer free(alloc, r);
        expectOk(r, "[rootB] init");
    }
    try writeFileIn(alloc, root2, "only.txt", "only file\n");
    {
        const r = try cli(alloc, bin, root2, &.{ "stage", "only.txt" });
        defer free(alloc, r);
        expectOk(r, "[rootB] stage only.txt");
    }
    {
        const r = try cli(alloc, bin, root2, &.{ "commit", "-m", "Root commit" });
        defer free(alloc, r);
        expectOkAndContains(r, "root commit", "[rootB] commit: root commit created");
    }
    {
        const r = try cli(alloc, bin, root2, &.{ "uncommit", "--hard" });
        defer free(alloc, r);
        expectFail(r, "[rootB] uncommit --hard: refuses without --yes on root commit");
    }
    {
        const r = try cli(alloc, bin, root2, &.{ "uncommit", "--hard", "--yes" });
        defer free(alloc, r);
        expectOkAndContains(r, "no commits", "[rootB] uncommit --hard --yes: confirmed, root undone");
    }

    std.debug.print("\n=== summary: {d} passed, {d} failed (of {d}) ===\n", .{
        pass_count,
        fail_count,
        pass_count + fail_count,
    });

    if (fail_count > 0) std.process.exit(1);
}
