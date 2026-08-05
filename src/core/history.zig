const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const crypto = @import("crypto");
const storage = @import("storage");
const merkle_mod = @import("merkle");

const commit_mod = @import("commit.zig");
const refs_mod = @import("refs.zig");
const Store = @import("object.zig").Store;

const PageStore = merkle_mod.PageStore;
const diffRoots = merkle_mod.diffRoots;
const hashEq = merkle_mod.hashEq;
const Hash = crypto.Hash;
const EntryChange = merkle_mod.EntryChange;
const ChangeKind = merkle_mod.ChangeKind;
const Entry = merkle_mod.Entry;
const Vfs = storage.Vfs;
const MemoryFs = storage.MemoryFs;

const CommitBuilder = commit_mod.CommitBuilder;
const CommitRequest = commit_mod.CommitRequest;
const ParentInfo = commit_mod.parent.ParentInfo;
const ParentKind = commit_mod.ParentKind;
const ReferenceStore = refs_mod.ReferenceStore;
const ChannelName = refs_mod.ChannelName;
const Current = refs_mod.Current;

/// Controls which parent edges a `RevWalk` is willing to descend into.
pub const EdgeFilter = enum {
    /// Follow every parent edge, regardless of kind.
    all,
    /// Follow only `.normal` and `.merge` edges. `.cherry_pick`,
    /// `.rebase`, and `.revert` edges are real edges (the commit graph
    /// still has them, and `.all` still walks them) but are not
    /// considered part of the mainline.
    mainline_only,

    /// Returns true if an edge of the given `kind` should be followed
    /// under this filter.
    fn follows(self: EdgeFilter, kind: ParentKind) bool {
        return switch (self) {
            .all => true,
            .mainline_only => kind == .normal or kind == .merge,
        };
    }
};

/// Newest-first traversal of a commit graph, starting from a single
/// commit and walking backward through parent edges selected by an
/// `EdgeFilter`. Each call to `next()` returns the commit with the
/// largest timestamp currently on the frontier.
pub const RevWalk = struct {
    alloc: Allocator,
    store: *const Store,
    filter: EdgeFilter,
    /// Commits that have been discovered (via a followed parent edge)
    /// but not yet emitted by `next()`.
    frontier: ArrayList(TimestampedHash),
    /// Every commit hash ever pushed onto the frontier, so a commit
    /// reachable via more than one edge is only visited once.
    seen: std.AutoHashMapUnmanaged(Hash, void) = .empty,

    const TimestampedHash = struct { hash: Hash, timestamp_ms: i64 };

    /// Creates a walk rooted at `start`. `start` itself is pushed onto
    /// the frontier immediately, so it will be the first result of
    /// `next()` (assuming nothing else beats it on timestamp, which
    /// nothing can, since it's the only entry).
    pub fn init(alloc: Allocator, store: *const Store, start: Hash, filter: EdgeFilter) !RevWalk {
        var self = RevWalk{
            .alloc = alloc,
            .store = store,
            .filter = filter,
            .frontier = .empty,
        };
        try self.push(start);
        return self;
    }

    /// Releases the walk's internal bookkeeping structures. Does not
    /// touch the underlying `Store`.
    pub fn deinit(self: *RevWalk) void {
        self.frontier.deinit(self.alloc);
        self.seen.deinit(self.alloc);
    }

    /// Pops the highest-timestamp commit off the frontier, pushes its
    /// followed parents, and returns its hash. Returns null once the
    /// frontier is exhausted.
    pub fn next(self: *RevWalk) !?Hash {
        if (self.frontier.items.len == 0) return null;

        // Linear scan for the max-timestamp entry. A single repo's live
        // frontier (commits with unvisited children) is small in
        // practice;
        //?:profile to see if we should swap for `std.PriorityQueue`
        var newest_index: usize = 0;
        for (self.frontier.items, 0..) |candidate, index| {
            if (candidate.timestamp_ms > self.frontier.items[newest_index].timestamp_ms) newest_index = index;
        }
        const current = self.frontier.swapRemove(newest_index);

        var current_commit = try commit_mod.read(self.alloc, self.store, current.hash);
        defer current_commit.deinit(self.alloc);

        for (current_commit.parents) |parent_info| {
            if (!self.filter.follows(parent_info.kind)) continue;
            try self.push(parent_info.hash);
        }

        return current.hash;
    }

    /// Adds `commit_hash` to the frontier if it hasn't been seen before.
    /// Reads the commit just far enough to record its timestamp, which
    /// is what `next()` uses to decide traversal order.
    fn push(self: *RevWalk, commit_hash: Hash) !void {
        if (self.seen.contains(commit_hash)) return;
        try self.seen.put(self.alloc, commit_hash, {});

        var pushed_commit = try commit_mod.read(self.alloc, self.store, commit_hash);
        defer pushed_commit.deinit(self.alloc);

        try self.frontier.append(self.alloc, .{
            .hash = commit_hash,
            .timestamp_ms = pushed_commit.metadata.timestamp_ms,
        });
    }
};

/// One recorded change to a single path, as an entry in that path's
/// history log.
pub const PathChangeEntry = struct {
    commit_hash: Hash,
    kind: ChangeKind,
    timestamp_ms: i64,
};

/// On-disk size in bytes of one serialized `PathChangeEntry`: a hash,
/// a one-byte `ChangeKind`, and an 8-byte little-endian timestamp.
const PATH_RECORD_LEN: usize = @sizeOf(Hash) + 1 + 8;

/// Per-path append-only change log. Each path gets its own log file,
/// keyed by the blake3 hash of the path, sharded two levels deep so no
/// single directory ends up with an unmanageable number of entries.
pub const PathHistory = struct {
    alloc: Allocator,
    fs: Vfs,
    /// Directory path-history logs live under, e.g. "merk/history/paths"
    paths_dir: []const u8,

    pub fn init(alloc: Allocator, fs: Vfs, paths_dir: []const u8) PathHistory {
        return .{ .alloc = alloc, .fs = fs, .paths_dir = paths_dir };
    }

    /// Record every change touched by one commit. Call this once per
    /// commit, right after computing that commit's `EntryChange` list
    /// against its mainline parent's snapshot — a diff `History.commit`
    /// already has to do to know what it's committing.
    pub fn recordCommit(
        self: PathHistory,
        commit_hash: Hash,
        timestamp_ms: i64,
        changes: []const EntryChange,
    ) !void {
        for (changes) |change| {
            try self.append(change.path, .{
                .commit_hash = commit_hash,
                .kind = change.kind,
                .timestamp_ms = timestamp_ms,
            });
        }
    }

    /// Full change history for one path, oldest first. Caller owns the
    /// returned slice — free with `self.alloc.free(...)`.
    pub fn log(self: PathHistory, path: []const u8) ![]PathChangeEntry {
        const file_path = try self.logPath(path);
        defer self.alloc.free(file_path);

        const maybe_bytes = try self.fs.readFile(self.alloc, file_path);
        if (maybe_bytes == null) return self.alloc.alloc(PathChangeEntry, 0);
        const bytes = maybe_bytes.?;
        defer self.alloc.free(bytes);

        if (bytes.len % PATH_RECORD_LEN != 0) return error.CorruptPathHistory;
        const record_count = bytes.len / PATH_RECORD_LEN;

        const entries = try self.alloc.alloc(PathChangeEntry, record_count);
        errdefer self.alloc.free(entries);

        var record_index: usize = 0;
        while (record_index < record_count) : (record_index += 1) {
            const record_start = record_index * PATH_RECORD_LEN;
            const record_bytes = bytes[record_start .. record_start + PATH_RECORD_LEN];

            const hash_bytes = record_bytes[0..@sizeOf(Hash)];
            var commit_hash: Hash = undefined;
            @memcpy(&commit_hash, hash_bytes);

            const kind_byte = record_bytes[@sizeOf(Hash)];
            const kind = std.meta.intToEnum(ChangeKind, kind_byte) catch return error.CorruptPathHistory;

            const timestamp_start = @sizeOf(Hash) + 1;
            const timestamp_bytes = record_bytes[timestamp_start .. timestamp_start + 8];
            const timestamp_ms = std.mem.readInt(i64, timestamp_bytes, .little);

            entries[record_index] = .{
                .commit_hash = commit_hash,
                .kind = kind,
                .timestamp_ms = timestamp_ms,
            };
        }
        return entries;
    }

    /// Serializes `record` and appends it to the log file for `path`,
    /// creating the file (and its content) from scratch if this is the
    /// path's first recorded change.
    fn append(self: PathHistory, path: []const u8, record: PathChangeEntry) !void {
        const file_path = try self.logPath(path);
        defer self.alloc.free(file_path);

        const existing_bytes = try self.fs.readFile(self.alloc, file_path);
        defer if (existing_bytes) |bytes| self.alloc.free(bytes);

        const existing_len = if (existing_bytes) |bytes| bytes.len else 0;
        const combined_bytes = try self.alloc.alloc(u8, existing_len + PATH_RECORD_LEN);
        defer self.alloc.free(combined_bytes);

        if (existing_bytes) |bytes| @memcpy(combined_bytes[0..existing_len], bytes);

        const hash_start = existing_len;
        const hash_end = hash_start + @sizeOf(Hash);
        @memcpy(combined_bytes[hash_start..hash_end], &record.commit_hash);

        const kind_offset = hash_end;
        combined_bytes[kind_offset] = @intFromEnum(record.kind);

        const timestamp_start = kind_offset + 1;
        const timestamp_end = timestamp_start + 8;
        std.mem.writeInt(i64, @as(*[8]u8, @ptrCast(combined_bytes[timestamp_start..timestamp_end].ptr)), record.timestamp_ms, .little);
        try self.fs.writeFile(self.alloc, file_path, combined_bytes);
    }

    /// Computes the sharded log-file path for `path`: the blake3 hash
    /// of `path`, split into two one-byte directory levels (to keep
    /// any single directory small) followed by the full hex hash as
    /// the filename.
    fn logPath(self: PathHistory, path: []const u8) ![]u8 {
        const path_hash = crypto.blake3(path);
        var hex_buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{path_hash}) catch unreachable;

        if (self.paths_dir.len == 0) {
            return std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}", .{ hex[0..2], hex[2..4], hex });
        }
        return std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}/{s}", .{ self.paths_dir, hex[0..2], hex[2..4], hex });
    }
};

/// Top-level history facade: writes commits, advances branch refs, and
/// keeps the per-path change logs in sync. Composes a `Store` (object
/// storage), a `ReferenceStore` (branch heads), and a `PathHistory`
/// (per-path logs) into one entry point.
pub const History = struct {
    alloc: Allocator,
    fs: Vfs,
    history_dir: []const u8,
    store: *const Store,
    ref_store: ReferenceStore,
    path_history: PathHistory,
    page_store: *const PageStore,

    pub fn init(
        alloc: Allocator,
        fs: Vfs,
        history_dir: []const u8,
        store: *const Store,
        page_store: *const PageStore,
    ) !History {
        const paths_dir = if (history_dir.len == 0)
            try alloc.dupe(u8, "paths")
        else
            try std.fmt.allocPrint(alloc, "{s}/paths", .{history_dir});

        return .{
            .alloc = alloc,
            .fs = fs,
            .history_dir = history_dir,
            .store = store,
            // `ReferenceStore` is unprefixed by design (see refs.zig: "fs
            // is expected to provide the repository's reference root").
            // `Current` and `references/Channels/*` sit at the repo root,
            // independent of `history_dir` — only path-history logs live
            // under `history_dir`.
            .ref_store = ReferenceStore.init(alloc, fs),
            .path_history = PathHistory.init(alloc, fs, paths_dir),
            .page_store = page_store,
        };
    }

    /// Releases resources owned by `History` itself. Does not touch the
    /// `Store`, `PageStore`, or filesystem, which are all borrowed.
    pub fn deinit(self: *History) void {
        self.alloc.free(self.path_history.paths_dir);
    }

    /// Writes a new commit object with the given `tree_root` and
    /// `parents`, records its path-level changes (diffed against the
    /// mainline parent's snapshot, or the zero tree if there is no
    /// mainline parent), advances `branch` to point at it, and returns
    /// the new commit's hash.
    pub fn commit(
        self: *History,
        branch: ChannelName,
        tree_root: Hash,
        parents: []const ParentInfo,
        request: CommitRequest,
    ) !Hash {
        var builder = try CommitBuilder.fromRequest(self.alloc, tree_root, request);
        defer builder.deinit();
        for (parents) |parent_info| {
            _ = try builder.parentWithKind(parent_info.hash, parent_info.kind);
        }

        const new_hash = try builder.write(self.store);

        const parent_tree = try self.mainlineTreeRoot(parents);
        const changes = try diffRoots(self.alloc, self.page_store, parent_tree, tree_root);
        defer merkle_mod.freeChanges(self.alloc, changes);

        const timestamp_ms = request.committer_timestamp_ms orelse request.author_timestamp_ms;
        try self.path_history.recordCommit(new_hash, timestamp_ms, changes);

        try self.ref_store.updateChannel(branch, new_hash);
        return new_hash;
    }

    /// Newest-first history of `branch`, following edges per `filter`.
    /// Returns null if `branch` has no commits yet.
    pub fn log(self: *History, branch: ChannelName, filter: EdgeFilter) !?RevWalk {
        const head = (try self.ref_store.readChannel(branch)) orelse return null;
        return try RevWalk.init(self.alloc, self.store, head, filter);
    }

    /// Full recorded history of a single path, oldest first.
    pub fn pathLog(self: *History, path: []const u8) ![]PathChangeEntry {
        return self.path_history.log(path);
    }

    /// Finds the snapshot tree of `parents`' mainline ancestor (the
    /// first `.normal` or `.merge` parent), which is what a new
    /// commit's changes should be diffed against. Returns the zero
    /// hash if there is no mainline parent (e.g. a root commit, or a
    /// commit whose only parent is a `.cherry_pick`/`.rebase`/`.revert`
    /// edge).
    fn mainlineTreeRoot(self: *History, parents: []const ParentInfo) !Hash {
        for (parents) |parent_info| {
            if (parent_info.kind == .normal or parent_info.kind == .merge) {
                var parent_commit = try commit_mod.read(self.alloc, self.store, parent_info.hash);
                defer parent_commit.deinit(self.alloc);
                return parent_commit.snapshot;
            }
        }
        return crypto.zero_hash;
    }
};

/// Test helper: builds a tree object from a flat list of paths, each
/// getting a synthetic one-byte blob keyed by its own path hash.
fn makeTree(alloc: Allocator, store: *const PageStore, paths: []const []const u8) !Hash {
    var entries: ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }
    for (paths) |path| {
        try entries.append(alloc, .{
            .path = try alloc.dupe(u8, path),
            .blob_hash = crypto.blake3(path),
            .size = 1,
            .mode = 0o100644,
            .mtime = 1,
        });
    }
    return merkle_mod.build(alloc, store, entries.items);
}

/// Test helper: builds a minimal `CommitRequest` with a fixed author.
fn testRequest(title: []const u8, timestamp_ms: i64) CommitRequest {
    return .{
        .author_name = "bnlvn",
        .author_email = "bnlvn@merk.dev",
        .author_timestamp_ms = timestamp_ms,
        .intent = .feature,
        .title = title,
    };
}

test "RevWalk with mainline_only skips cherry-pick edges but keeps typed merge parents" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const obj_store = Store.init(alloc, mem_fs.fs(), "objects");
    const tree_hash = try obj_store.put(.tree, &[_]u8{0} ** 4);

    var root_b = CommitBuilder.init(alloc, tree_hash);
    defer root_b.deinit();
    _ = root_b.author("bnlvn", "bnlvn@merk.dev", 100);
    _ = root_b.intent(.chore);
    _ = root_b.title("root");
    const root_hash = try root_b.write(&obj_store);

    var mainline_b = CommitBuilder.init(alloc, tree_hash);
    defer mainline_b.deinit();
    _ = try mainline_b.parent(root_hash);
    _ = mainline_b.author("bnlvn", "bnlvn@merk.dev", 200);
    _ = mainline_b.intent(.feature);
    _ = mainline_b.title("mainline");
    const mainline_hash = try mainline_b.write(&obj_store);

    // A commit reached only via a cherry-pick edge.
    var stray_b = CommitBuilder.init(alloc, tree_hash);
    defer stray_b.deinit();
    _ = stray_b.author("bnlvn", "bnlvn@merk.dev", 150);
    _ = stray_b.intent(.fix);
    _ = stray_b.title("stray");
    const stray_hash = try stray_b.write(&obj_store);

    var head_b = CommitBuilder.init(alloc, tree_hash);
    defer head_b.deinit();
    _ = try head_b.parentWithKind(mainline_hash, .normal);
    _ = try head_b.parentWithKind(stray_hash, .cherry_pick);
    _ = head_b.author("bnlvn", "bnlvn@merk.dev", 300);
    _ = head_b.intent(.chore);
    _ = head_b.title("head");
    const head_hash = try head_b.write(&obj_store);

    var walk = try RevWalk.init(alloc, &obj_store, head_hash, .mainline_only);
    defer walk.deinit();

    var visited: ArrayList(Hash) = .empty;
    defer visited.deinit(alloc);
    while (try walk.next()) |visited_hash| try visited.append(alloc, visited_hash);

    try testing.expectEqual(@as(usize, 3), visited.items.len);
    for (visited.items) |visited_hash| try testing.expect(!hashEq(visited_hash, stray_hash));

    var walk_all = try RevWalk.init(alloc, &obj_store, head_hash, .all);
    defer walk_all.deinit();
    var visited_all: ArrayList(Hash) = .empty;
    defer visited_all.deinit(alloc);
    while (try walk_all.next()) |visited_hash| try visited_all.append(alloc, visited_hash);
    try testing.expectEqual(@as(usize, 4), visited_all.items.len);
}

test "RevWalk with mainline_only still follows a merge's typed second parent" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const obj_store = Store.init(alloc, mem_fs.fs(), "objects");
    const tree_hash = try obj_store.put(.tree, &[_]u8{0} ** 4);

    var base_b = CommitBuilder.init(alloc, tree_hash);
    defer base_b.deinit();
    _ = base_b.author("bnlvn", "bnlvn@merk.dev", 100);
    _ = base_b.intent(.chore);
    _ = base_b.title("base");
    const base_hash = try base_b.write(&obj_store);

    var branch_b = CommitBuilder.init(alloc, tree_hash);
    defer branch_b.deinit();
    _ = try branch_b.parent(base_hash);
    _ = branch_b.author("bnlvn", "bnlvn@merk.dev", 150);
    _ = branch_b.intent(.feature);
    _ = branch_b.title("side branch");
    const branch_hash = try branch_b.write(&obj_store);

    var merge_b = CommitBuilder.init(alloc, tree_hash);
    defer merge_b.deinit();
    _ = try merge_b.parentWithKind(base_hash, .normal);
    _ = try merge_b.parentWithKind(branch_hash, .merge);
    _ = merge_b.author("bnlvn", "bnlvn@merk.dev", 200);
    _ = merge_b.intent(.chore);
    _ = merge_b.title("merge branch");
    const merge_hash = try merge_b.write(&obj_store);

    var walk = try RevWalk.init(alloc, &obj_store, merge_hash, .mainline_only);
    defer walk.deinit();

    var visited: ArrayList(Hash) = .empty;
    defer visited.deinit(alloc);
    while (try walk.next()) |visited_hash| try visited.append(alloc, visited_hash);

    // merge, base, and branch (via the .merge-typed edge) should all show
    try testing.expectEqual(@as(usize, 3), visited.items.len);
    var saw_branch = false;
    for (visited.items) |visited_hash| {
        if (hashEq(visited_hash, branch_hash)) saw_branch = true;
    }
    try testing.expect(saw_branch);
}

test "History.commit records path history and advances the branch ref" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const obj_store = Store.init(alloc, mem_fs.fs(), "objects");
    const page_store = PageStore.init(alloc, mem_fs.fs(), "index/pages");

    var history = try History.init(alloc, mem_fs.fs(), "history", &obj_store, &page_store);
    defer history.deinit();

    const main = try ChannelName.parse("main");

    const tree1 = try makeTree(alloc, &page_store, &.{"a.txt"});
    const c1 = try history.commit(main, tree1, &.{}, testRequest("add a.txt", 1000));

    const tree2 = try makeTree(alloc, &page_store, &.{ "a.txt", "b.txt" });
    const c2 = try history.commit(
        main,
        tree2,
        &.{.{ .hash = c1, .kind = .normal }},
        testRequest("add b.txt", 2000),
    );

    const head = try history.ref_store.readChannel(main);
    try testing.expect(head != null);
    try testing.expect(hashEq(head.?, c2));

    const b_history = try history.pathLog("b.txt");
    defer alloc.free(b_history);
    try testing.expectEqual(@as(usize, 1), b_history.len);
    try testing.expectEqual(ChangeKind.added, b_history[0].kind);
    try testing.expect(hashEq(b_history[0].commit_hash, c2));

    const a_history = try history.pathLog("a.txt");
    defer alloc.free(a_history);
    try testing.expectEqual(@as(usize, 1), a_history.len);
    try testing.expectEqual(ChangeKind.added, a_history[0].kind);
    try testing.expect(hashEq(a_history[0].commit_hash, c1));

    var walk = (try history.log(main, .all)).?;
    defer walk.deinit();
    var count: usize = 0;
    while (try walk.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}

test "History.commit on a commit with only a cherry-pick parent diffs against the zero tree" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    const obj_store = Store.init(alloc, mem_fs.fs(), "objects");
    const page_store = PageStore.init(alloc, mem_fs.fs(), "index/pages");

    var history = try History.init(alloc, mem_fs.fs(), "history", &obj_store, &page_store);
    defer history.deinit();

    const donor_branch = try ChannelName.parse("donor-branch");
    const main = try ChannelName.parse("main");

    // A donor commit elsewhere in the object store, never on this branch
    const donor_tree = try makeTree(alloc, &page_store, &.{"donor.txt"});
    const donor_hash = try history.commit(donor_branch, donor_tree, &.{}, testRequest("donor commit", 500));

    const tree1 = try makeTree(alloc, &page_store, &.{"donor.txt"});
    const c1 = try history.commit(
        main,
        tree1,
        &.{.{ .hash = donor_hash, .kind = .cherry_pick }},
        testRequest("cherry-pick donor.txt", 1000),
    );

    const donor_history = try history.pathLog("donor.txt");
    defer alloc.free(donor_history);

    // Recorded twice: once for the original donor commit, once more as
    // `.added` on `main` since the cherry-pick edge isn't a mainline
    // ancestor to diff against
    try testing.expectEqual(@as(usize, 2), donor_history.len);
    try testing.expectEqual(ChangeKind.added, donor_history[1].kind);
    try testing.expect(hashEq(donor_history[1].commit_hash, c1));
}
