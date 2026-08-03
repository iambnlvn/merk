//! wip, might rewrite this entirely

const std = @import("std");
const merk = @import("merk");
const merkle_mod = merk.merkle;
const hash_mod = merk.crypto.hash;
const io = merk.io;

const object_mod = @import("object/object.zig");
const index_mod = @import("index.zig");
const commit_mod = @import("commit.zig");
const history_mod = @import("history.zig");
const refs_mod = @import("./refs/refs.zig");

const Hash = hash_mod.Hash;
const Store = object_mod.Store;
const Index = index_mod.Index;
const History = history_mod.History;
const ReferenceStore = refs_mod.ReferenceStore;
const TrackName = refs_mod.TrackName;
const CommitRequest = commit_mod.CommitRequest;
const ParentInfo = commit_mod.parent.ParentInfo;
const EntryChange = merkle_mod.EntryChange;
const WorktreeState = merkle_mod.WorktreeState;
const Intent = commit_mod.Intent;

pub const RepositoryError = error{
    AlreadyInitialized,
    NotARepository,
    /// Focus points directly at a commit rather than a track. Every
    /// mutating command here (`add`/`commit`/`reset`) needs a track to
    /// advance, so detached Focus is out of scope for this facade —
    /// surface it to the caller instead of guessing which track to use.
    DetachedFocus,
};

pub const ResetMode = enum {
    /// Move the track pointer only. Index and worktree untouched.
    soft,
    /// Move the track pointer and reset the index to match. Worktree untouched.
    mixed,
    /// Move the track pointer, reset the index, and overwrite tracked
    /// worktree files to match. Does not delete files newly untracked
    /// by the reset — that needs a worktree walk this layer doesn't do.
    hard,
};

/// One entry's worktree-vs-index status, for `Status.unstaged`.
pub const WorktreeEntryStatus = struct {
    path: []const u8,
    state: WorktreeState,
};

/// Result of `Repository.status`. `staged` is index-vs-HEAD (what a
/// commit right now would record); `unstaged` is worktree-vs-index
/// (what `add` would pick up). Free with `.deinit`.
///
/// NOTE: `unstaged` only covers currently-tracked paths — it can report
/// `.modified`/`.deleted` but not brand-new untracked files, since that
/// needs a worktree directory walk this layer doesn't own.
pub const Status = struct {
    staged: []EntryChange,
    unstaged: []WorktreeEntryStatus,

    pub fn deinit(self: *Status, alloc: std.mem.Allocator) void {
        merkle_mod.freeChanges(alloc, self.staged);
        alloc.free(self.unstaged);
        self.* = undefined;
    }
};

pub const Repository = struct {
    alloc: std.mem.Allocator,
    fs: io.FileSystem,
    /// Worktree root (plain OS path, not `fs`-relative).
    root: []const u8,
    store: Store,
    page_store: merkle_mod.PageStore,
    index: Index,
    history: History,
    ref_store: ReferenceStore,
    /// Owned backing storage for `current_track.raw`.
    current_track_name: []u8,
    current_track: TrackName,

    /// Create a brand-new repository. `fs` must already be rooted at an
    /// empty (or nonexistent-focus) control directory. Fails with
    /// `error.AlreadyInitialized` if Focus is already set there.
    ///
    /// Returns `*Repository`: `History` holds raw `*const Store` /
    /// `*const PageStore` pointers, so `Repository` must live at one
    /// fixed heap address for its whole lifetime — never move or copy
    /// a `Repository` value once one of these has been created.
    pub fn init(alloc: std.mem.Allocator, fs: io.FileSystem, root: []const u8) !*Repository {
        const probe = ReferenceStore.init(alloc, fs);
        if (try probe.focusState()) |existing| {
            existing.deinit(alloc);
            return error.AlreadyInitialized;
        }

        const self = try openInternal(alloc, fs, root, "main");
        errdefer self.deinit();

        try self.index.save();
        try self.ref_store.setFocusToTrack(self.current_track);

        return self;
    }

    /// Open an existing repository. `error.NotARepository` if no Focus
    /// file exists yet; `error.DetachedFocus` if Focus points directly
    /// at a commit rather than a track (see `RepositoryError`). See
    /// `init`'s doc comment on why this returns `*Repository`.
    pub fn open(alloc: std.mem.Allocator, fs: io.FileSystem, root: []const u8) !*Repository {
        const ref_store = ReferenceStore.init(alloc, fs);
        const state = (try ref_store.focusState()) orelse return error.NotARepository;
        defer state.deinit(alloc);

        const track_name = switch (state) {
            .symbolic => |s| s,
            .detached => return error.DetachedFocus,
        };

        return openInternal(alloc, fs, root, track_name);
    }

    fn openInternal(alloc: std.mem.Allocator, fs: io.FileSystem, root: []const u8, track_name: []const u8) !*Repository {
        // Allocate first and fill fields in place: `&self.store` /
        // `&self.page_store` below must point at this struct's final,
        // permanent address, not at a local that vanishes when this
        // function returns (returning `Repository` by value would copy
        // it to a new address and leave History's pointers dangling —
        // that was the actual bug behind the earlier crash).
        const self = try alloc.create(Repository);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.fs = fs;
        self.store = Store.init(alloc, fs, "objects");
        self.page_store = merkle_mod.PageStore.init(alloc, fs, "index/pages");

        // fs is already rooted at the control directory, so the index's
        // own "index/..." layout needs no further prefix.
        self.index = Index.init(alloc, fs, "");
        errdefer self.index.deinit();
        try self.index.load();

        self.root = try alloc.dupe(u8, root);
        errdefer alloc.free(self.root);

        self.current_track_name = try alloc.dupe(u8, track_name);
        errdefer alloc.free(self.current_track_name);
        self.current_track = try TrackName.parse(self.current_track_name);

        self.ref_store = ReferenceStore.init(alloc, fs);

        self.history = try History.init(alloc, fs, "history", &self.store, &self.page_store);

        return self;
    }

    pub fn deinit(self: *Repository) void {
        self.index.deinit();
        self.history.deinit();
        self.alloc.free(self.root);
        self.alloc.free(self.current_track_name);
        self.alloc.destroy(self);
    }

    /// Stage a batch of repo-relative paths. Errors partway through
    /// leave already-staged paths staged — callers wanting all-or-nothing
    /// semantics should back up `self.index.entries` first.
    pub fn add(self: *Repository, paths: []const []const u8) !void {
        for (paths) |p| _ = try self.index.addFile(&self.store, self.root, p);
        try self.index.save();
    }

    /// Unstage a path (drop it from the index without touching the
    /// worktree file). Mirrors `git reset <path>`, not `checkout`.
    pub fn unstage(self: *Repository, path: []const u8) !void {
        try self.index.remove(path);
        try self.index.save();
    }

    /// Commit the currently-staged index as a child of the current
    /// track's HEAD (or as a root commit if the track has none yet).
    pub fn commit(self: *Repository, request: CommitRequest) !Hash {
        const head = try self.ref_store.readTrack(self.current_track);

        var parent_buf: [1]ParentInfo = undefined;
        const parents: []const ParentInfo = if (head) |h| blk: {
            parent_buf[0] = .{ .hash = h, .kind = .normal };
            break :blk parent_buf[0..1];
        } else &.{};

        return self.history.commit(self.current_track, self.index.index_root, parents, request);
    }

    pub fn status(self: *Repository) !Status {
        const head_snapshot = try self.headSnapshot();
        const staged = try self.index.diffAgainst(head_snapshot);
        errdefer merkle_mod.freeChanges(self.alloc, staged);

        var unstaged: std.ArrayList(WorktreeEntryStatus) = .empty;
        errdefer unstaged.deinit(self.alloc);
        for (self.index.entries.items) |entry| {
            const state = try self.index.stateOf(self.root, entry);
            if (state != .clean) try unstaged.append(self.alloc, .{ .path = entry.path, .state = state });
        }

        return .{ .staged = staged, .unstaged = try unstaged.toOwnedSlice(self.alloc) };
    }

    /// Diff between two arbitrary commits' snapshots. Caller frees with
    /// `merkle_mod.freeChanges`.
    pub fn diffCommits(self: *Repository, from: Hash, to: Hash) ![]EntryChange {
        return merkle_mod.diffRoots(self.alloc, &self.page_store, from, to);
    }

    /// Diff HEAD against the currently staged index — same data as
    /// `status().staged`, exposed directly for a plain `merk diff --staged`.
    pub fn diffStaged(self: *Repository) ![]EntryChange {
        return self.index.diffAgainst(try self.headSnapshot());
    }

    /// Move the current track to `target` per `mode`. See `ResetMode`
    /// for what each level touches.
    pub fn reset(self: *Repository, target: Hash, mode: ResetMode) !void {
        try self.ref_store.updateTrack(self.current_track, target);
        if (mode == .soft) return;

        var c = try commit_mod.read(self.alloc, &self.store, target);
        defer c.deinit(self.alloc);

        for (self.index.entries.items) |*e| e.deinit(self.alloc);
        self.index.entries.clearRetainingCapacity();
        try merkle_mod.collect(self.alloc, &self.page_store, c.snapshot, &self.index.entries);
        try self.index.save();

        if (mode == .hard) try self.writeEntriesToWorktree();
    }

    fn writeEntriesToWorktree(self: *Repository) !void {
        const dir = std.fs.cwd();
        for (self.index.entries.items) |entry| {
            const obj = try self.store.get(entry.blob_hash);
            defer self.alloc.free(obj.payload);

            const full_path = try std.fs.path.join(self.alloc, &.{ self.root, entry.path });
            defer self.alloc.free(full_path);

            if (std.fs.path.dirname(full_path)) |d| try dir.makePath(d);
            try dir.writeFile(.{ .sub_path = full_path, .data = obj.payload });
        }
    }

    pub fn log(self: *Repository, filter: history_mod.EdgeFilter) !?history_mod.RevWalk {
        return self.history.log(self.current_track, filter);
    }

    fn headSnapshot(self: *Repository) !Hash {
        const head = (try self.ref_store.readTrack(self.current_track)) orelse return hash_mod.zero_hash;
        var c = try commit_mod.read(self.alloc, &self.store, head);
        defer c.deinit(self.alloc);
        return c.snapshot;
    }
};

fn testRequest(title: []const u8, timestamp_ms: i64) CommitRequest {
    return .{
        .author_name = "bnlvn",
        .author_email = "bnlvn@merk.dev",
        .author_timestamp_ms = timestamp_ms,
        .intent = .feature,
        .title = title,
    };
}

/// Append entries directly to `repo.index` and save — bypasses `add`'s
/// worktree read (`Index.addFile` goes through `std.fs.cwd()`, so
/// exercising it needs a real tmpDir; these tests only need entries to
/// exist for commit/status/reset to operate on).
fn stageFakeEntry(repo: *Repository, path: []const u8, content: []const u8) !void {
    try repo.index.entries.append(repo.alloc, .{
        .path = try repo.alloc.dupe(u8, path),
        .blob_hash = hash_mod.blake3(content),
        .size = content.len,
        .mode = 0o100644,
        .mtime = 1,
    });
    try repo.index.save();
}

test "Repository.init sets up an empty repo focused on main, and refuses a second init" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const repo = try Repository.init(alloc, tfs.fs(), "/tmp/does-not-matter");
    defer repo.deinit();

    try std.testing.expectEqualStrings("main", repo.current_track.raw);
    try std.testing.expectEqual(@as(usize, 0), repo.index.entries.items.len);

    try std.testing.expectError(error.AlreadyInitialized, Repository.init(alloc, tfs.fs(), "/tmp/does-not-matter"));
}

test "Repository.open fails on a directory with no Focus yet" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    try std.testing.expectError(error.NotARepository, Repository.open(alloc, tfs.fs(), "/tmp/does-not-matter"));
}

test "Repository.open round-trips an initialized repo's current track" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    {
        const repo = try Repository.init(alloc, tfs.fs(), "/tmp/does-not-matter");
        defer repo.deinit();
    }

    const reopened = try Repository.open(alloc, tfs.fs(), "/tmp/does-not-matter");
    defer reopened.deinit();
    try std.testing.expectEqualStrings("main", reopened.current_track.raw);
}

test "commit advances the current track and status goes clean against HEAD" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const repo = try Repository.init(alloc, tfs.fs(), "/tmp/does-not-matter");
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "hello");

    var pre_status = try repo.status();
    defer pre_status.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), pre_status.staged.len);
    try std.testing.expectEqual(merkle_mod.ChangeKind.added, pre_status.staged[0].kind);

    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    const head = try repo.ref_store.readTrack(repo.current_track);
    try std.testing.expect(head != null);
    try std.testing.expect(merkle_mod.hashEq(head.?, c1));

    var post_status = try repo.status();
    defer post_status.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), post_status.staged.len);
}

test "commit chains parents across two commits and log walks both" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const repo = try Repository.init(alloc, tfs.fs(), "/tmp/does-not-matter");
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

test "reset soft moves the track without touching the index" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const repo = try Repository.init(alloc, tfs.fs(), "/tmp/does-not-matter");
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    _ = try repo.commit(testRequest("add b.txt", 2000));

    try repo.reset(c1, .soft);

    const head = try repo.ref_store.readTrack(repo.current_track);
    try std.testing.expect(merkle_mod.hashEq(head.?, c1));
    // Soft reset leaves the index (still holding both entries) alone.
    try std.testing.expectEqual(@as(usize, 2), repo.index.entries.items.len);
}

test "reset mixed rebuilds the index to match the target commit's snapshot" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const repo = try Repository.init(alloc, tfs.fs(), "/tmp/does-not-matter");
    defer repo.deinit();

    try stageFakeEntry(repo, "a.txt", "one");
    const c1 = try repo.commit(testRequest("add a.txt", 1000));

    try stageFakeEntry(repo, "b.txt", "two");
    _ = try repo.commit(testRequest("add b.txt", 2000));

    try repo.reset(c1, .mixed);

    try std.testing.expectEqual(@as(usize, 1), repo.index.entries.items.len);
    try std.testing.expectEqualStrings("a.txt", repo.index.entries.items[0].path);

    const head = try repo.ref_store.readTrack(repo.current_track);
    try std.testing.expect(merkle_mod.hashEq(head.?, c1));
}

test "diffCommits reports the added path between two commit snapshots" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const repo = try Repository.init(alloc, tfs.fs(), "/tmp/does-not-matter");
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

    var control_fs = io.RealFs.init(control_tmp.dir);

    const repo = try Repository.init(alloc, control_fs.fs(), worktree_root);
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
