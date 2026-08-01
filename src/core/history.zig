const std = @import("std");
const merk = @import("merk");
const hash_mod = merk.crypto.hash;
const io = merk.io;
const merkle_mod = merk.merkle;
const object_mod = @import("object/object.zig");
const commit_mod = @import("commit.zig");
const refs_mod = @import("./refs/refs.zig");

const Hash = hash_mod.Hash;
const Store = object_mod.Store;
const EntryChange = merkle_mod.EntryChange;
const ChangeKind = merkle_mod.ChangeKind;

pub const Commit = commit_mod.Commit;
pub const CommitBuilder = commit_mod.CommitBuilder;
pub const CommitRequest = commit_mod.CommitRequest;
pub const ParentInfo = commit_mod.parent.ParentInfo;
pub const ParentKind = commit_mod.ParentKind;

pub const ReferenceStore = refs_mod.ReferenceStore;
pub const TrackName = refs_mod.TrackName;
pub const Focus = refs_mod.Focus;

/// Should a `RevWalk` descend into a given parent edge?
pub const EdgeFilter = enum {
    /// Follow every parent edge, regardless of kind.
    all,
    /// Follow only `.normal` and `.merge` edges. `.cherry_pick`,
    /// `.rebase`, and `.revert` edges are real edges (the commit graph
    /// still has them, and `.all` still walks them) but are not
    /// considered part of the mainline
    mainline_only,

    fn follows(self: EdgeFilter, kind: ParentKind) bool {
        return switch (self) {
            .all => true,
            .mainline_only => kind == .normal or kind == .merge,
        };
    }
};

pub const RevWalk = struct {
    alloc: std.mem.Allocator,
    store: *const Store,
    filter: EdgeFilter,
    frontier: std.ArrayList(TimestampedHash),
    seen: std.AutoHashMapUnmanaged(Hash, void) = .empty,

    const TimestampedHash = struct { hash: Hash, timestamp_ms: i64 };

    pub fn init(alloc: std.mem.Allocator, store: *const Store, start: Hash, filter: EdgeFilter) !RevWalk {
        var self = RevWalk{
            .alloc = alloc,
            .store = store,
            .filter = filter,
            .frontier = .empty,
        };
        try self.push(start);
        return self;
    }

    pub fn deinit(self: *RevWalk) void {
        self.frontier.deinit(self.alloc);
        self.seen.deinit(self.alloc);
    }

    /// Returns the next commit hash in newest-first order, or null when
    /// traversal is exhausted
    pub fn next(self: *RevWalk) !?Hash {
        if (self.frontier.items.len == 0) return null;

        // Linear scan for the max-timestamp entry. A single repo's live
        // frontier (commits with unvisited children) is small in
        // practice;
        //?:profile to see if we should swap for `std.PriorityQueue`
        var best_idx: usize = 0;
        for (self.frontier.items, 0..) |item, i| {
            if (item.timestamp_ms > self.frontier.items[best_idx].timestamp_ms) best_idx = i;
        }
        const current = self.frontier.swapRemove(best_idx);

        var c = try commit_mod.read(self.alloc, self.store, current.hash);
        defer c.deinit(self.alloc);

        for (c.parents) |p| {
            if (!self.filter.follows(p.kind)) continue;
            try self.push(p.hash);
        }

        return current.hash;
    }

    fn push(self: *RevWalk, commit_hash: Hash) !void {
        if (self.seen.contains(commit_hash)) return;
        try self.seen.put(self.alloc, commit_hash, {});

        var c = try commit_mod.read(self.alloc, self.store, commit_hash);
        defer c.deinit(self.alloc);

        try self.frontier.append(self.alloc, .{ .hash = commit_hash, .timestamp_ms = c.metadata.timestamp_ms });
    }
};

pub const PathChangeEntry = struct {
    commit_hash: Hash,
    kind: ChangeKind,
    timestamp_ms: i64,
};

const PATH_RECORD_LEN: usize = @sizeOf(Hash) + 1 + 8;

pub const PathHistory = struct {
    alloc: std.mem.Allocator,
    fs: io.FileSystem,
    /// Directory path-history logs live under, e.g. "merk/history/paths"
    paths_dir: []const u8,

    pub fn init(alloc: std.mem.Allocator, fs: io.FileSystem, paths_dir: []const u8) PathHistory {
        return .{ .alloc = alloc, .fs = fs, .paths_dir = paths_dir };
    }

    /// Record every change touched by one commit. Call this once per
    /// commit, right after computing that commit's `EntryChange` list
    /// against its mainline parent's snapshot — a diff `History.commit`
    /// already has to do to know what it's committing
    pub fn recordCommit(
        self: PathHistory,
        commit_hash: Hash,
        timestamp_ms: i64,
        changes: []const EntryChange,
    ) !void {
        for (changes) |c| {
            try self.append(c.path, .{ .commit_hash = commit_hash, .kind = c.kind, .timestamp_ms = timestamp_ms });
        }
    }

    /// Full change history for one path, oldest first. Caller owns the
    /// returned slice — free with `self.alloc.free(...)`
    pub fn log(self: PathHistory, path: []const u8) ![]PathChangeEntry {
        const file_path = try self.logPath(path);
        defer self.alloc.free(file_path);

        const bytes = (try self.fs.readFile(self.alloc, file_path)) orelse
            return self.alloc.alloc(PathChangeEntry, 0);
        defer self.alloc.free(bytes);

        if (bytes.len % PATH_RECORD_LEN != 0) return error.CorruptPathHistory;
        const n = bytes.len / PATH_RECORD_LEN;

        const out = try self.alloc.alloc(PathChangeEntry, n);
        errdefer self.alloc.free(out);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = bytes[i * PATH_RECORD_LEN ..][0..PATH_RECORD_LEN];
            var h: Hash = undefined;
            @memcpy(&h, rec[0..@sizeOf(Hash)]);
            const kind = std.meta.intToEnum(ChangeKind, rec[@sizeOf(Hash)]) catch return error.CorruptPathHistory;
            const ts = std.mem.readInt(i64, rec[@sizeOf(Hash) + 1 ..][0..8], .little);
            out[i] = .{ .commit_hash = h, .kind = kind, .timestamp_ms = ts };
        }
        return out;
    }

    fn append(self: PathHistory, path: []const u8, rec: PathChangeEntry) !void {
        const file_path = try self.logPath(path);
        defer self.alloc.free(file_path);

        const existing = try self.fs.readFile(self.alloc, file_path);
        defer if (existing) |e| self.alloc.free(e);

        const old_len = if (existing) |e| e.len else 0;
        const buf = try self.alloc.alloc(u8, old_len + PATH_RECORD_LEN);
        defer self.alloc.free(buf);

        if (existing) |e| @memcpy(buf[0..old_len], e);

        @memcpy(buf[old_len..][0..@sizeOf(Hash)], &rec.commit_hash);
        buf[old_len + @sizeOf(Hash)] = @intFromEnum(rec.kind);
        std.mem.writeInt(i64, buf[old_len + @sizeOf(Hash) + 1 ..][0..8], rec.timestamp_ms, .little);

        try self.fs.writeFile(self.alloc, file_path, buf);
    }

    fn logPath(self: PathHistory, path: []const u8) ![]u8 {
        const h = hash_mod.blake3(path);
        var hex_buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{h}) catch unreachable;

        if (self.paths_dir.len == 0) {
            return std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}", .{ hex[0..2], hex[2..4], hex });
        }
        return std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}/{s}", .{ self.paths_dir, hex[0..2], hex[2..4], hex });
    }
};

pub const History = struct {
    alloc: std.mem.Allocator,
    fs: io.FileSystem,
    history_dir: []const u8,
    store: *const Store,
    ref_store: ReferenceStore,
    path_history: PathHistory,
    page_store: *const merkle_mod.PageStore,

    pub fn init(
        alloc: std.mem.Allocator,
        fs: io.FileSystem,
        history_dir: []const u8,
        store: *const Store,
        page_store: *const merkle_mod.PageStore,
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
            // `focus` and `references/tracks/*` sit at the repo root,
            // independent of `history_dir` — only path-history logs live
            // under `history_dir`.
            .ref_store = ReferenceStore.init(alloc, fs),
            .path_history = PathHistory.init(alloc, fs, paths_dir),
            .page_store = page_store,
        };
    }

    pub fn deinit(self: *History) void {
        self.alloc.free(self.path_history.paths_dir);
    }

    pub fn commit(
        self: *History,
        branch: TrackName,
        tree_root: Hash,
        parents: []const ParentInfo,
        request: CommitRequest,
    ) !Hash {
        var builder = try CommitBuilder.fromRequest(self.alloc, tree_root, request);
        defer builder.deinit();
        for (parents) |p| _ = try builder.parentWithKind(p.hash, p.kind);

        const new_hash = try builder.write(self.store);

        const parent_tree = try self.mainlineTreeRoot(parents);
        const changes = try merkle_mod.diffRoots(self.alloc, self.page_store, parent_tree, tree_root);
        defer merkle_mod.freeChanges(self.alloc, changes);

        const timestamp_ms = request.committer_timestamp_ms orelse request.author_timestamp_ms;
        try self.path_history.recordCommit(new_hash, timestamp_ms, changes);

        try self.ref_store.updateTrack(branch, new_hash);
        return new_hash;
    }

    /// Newest-first history of `branch`, following edges per `filter`.
    /// Returns null if `branch` has no commits yet
    pub fn log(self: *History, branch: TrackName, filter: EdgeFilter) !?RevWalk {
        const head = (try self.ref_store.readTrack(branch)) orelse return null;
        return try RevWalk.init(self.alloc, self.store, head, filter);
    }

    /// Full recorded history of a single path, oldest first
    pub fn pathLog(self: *History, path: []const u8) ![]PathChangeEntry {
        return self.path_history.log(path);
    }

    fn mainlineTreeRoot(self: *History, parents: []const ParentInfo) !Hash {
        for (parents) |p| {
            if (p.kind == .normal or p.kind == .merge) {
                var c = try commit_mod.read(self.alloc, self.store, p.hash);
                defer c.deinit(self.alloc);
                return c.snapshot;
            }
        }
        return hash_mod.zero_hash;
    }
};

fn makeTree(alloc: std.mem.Allocator, store: *const merkle_mod.PageStore, paths: []const []const u8) !Hash {
    var entries: std.ArrayList(merkle_mod.Entry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(alloc);
        entries.deinit(alloc);
    }
    for (paths) |p| {
        try entries.append(alloc, .{
            .path = try alloc.dupe(u8, p),
            .blob_hash = hash_mod.blake3(p),
            .size = 1,
            .mode = 0o100644,
            .mtime = 1,
        });
    }
    return merkle_mod.build(alloc, store, entries.items);
}

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
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const obj_store = Store.init(alloc, tfs.fs(), "objects");
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

    var visited: std.ArrayList(Hash) = .empty;
    defer visited.deinit(alloc);
    while (try walk.next()) |h| try visited.append(alloc, h);

    try std.testing.expectEqual(@as(usize, 3), visited.items.len);
    for (visited.items) |h| try std.testing.expect(!merkle_mod.hashEq(h, stray_hash));

    var walk_all = try RevWalk.init(alloc, &obj_store, head_hash, .all);
    defer walk_all.deinit();
    var visited_all: std.ArrayList(Hash) = .empty;
    defer visited_all.deinit(alloc);
    while (try walk_all.next()) |h| try visited_all.append(alloc, h);
    try std.testing.expectEqual(@as(usize, 4), visited_all.items.len);
}

test "RevWalk with mainline_only still follows a merge's typed second parent" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const obj_store = Store.init(alloc, tfs.fs(), "objects");
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

    var visited: std.ArrayList(Hash) = .empty;
    defer visited.deinit(alloc);
    while (try walk.next()) |h| try visited.append(alloc, h);

    // merge, base, and branch (via the .merge-typed edge) should all show
    try std.testing.expectEqual(@as(usize, 3), visited.items.len);
    var saw_branch = false;
    for (visited.items) |h| {
        if (merkle_mod.hashEq(h, branch_hash)) saw_branch = true;
    }
    try std.testing.expect(saw_branch);
}

test "History.commit records path history and advances the branch ref" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const obj_store = Store.init(alloc, tfs.fs(), "objects");
    const page_store = merkle_mod.PageStore.init(alloc, tfs.fs(), "index/pages");

    var history = try History.init(alloc, tfs.fs(), "history", &obj_store, &page_store);
    defer history.deinit();

    const main = try TrackName.parse("main");

    const tree1 = try makeTree(alloc, &page_store, &.{"a.txt"});
    const c1 = try history.commit(main, tree1, &.{}, testRequest("add a.txt", 1000));

    const tree2 = try makeTree(alloc, &page_store, &.{ "a.txt", "b.txt" });
    const c2 = try history.commit(
        main,
        tree2,
        &.{.{ .hash = c1, .kind = .normal }},
        testRequest("add b.txt", 2000),
    );

    const head = try history.ref_store.readTrack(main);
    try std.testing.expect(head != null);
    try std.testing.expect(merkle_mod.hashEq(head.?, c2));

    const b_history = try history.pathLog("b.txt");
    defer alloc.free(b_history);
    try std.testing.expectEqual(@as(usize, 1), b_history.len);
    try std.testing.expectEqual(ChangeKind.added, b_history[0].kind);
    try std.testing.expect(merkle_mod.hashEq(b_history[0].commit_hash, c2));

    const a_history = try history.pathLog("a.txt");
    defer alloc.free(a_history);
    try std.testing.expectEqual(@as(usize, 1), a_history.len);
    try std.testing.expectEqual(ChangeKind.added, a_history[0].kind);
    try std.testing.expect(merkle_mod.hashEq(a_history[0].commit_hash, c1));

    var walk = (try history.log(main, .all)).?;
    defer walk.deinit();
    var count: usize = 0;
    while (try walk.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "History.commit on a commit with only a cherry-pick parent diffs against the zero tree" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();

    const obj_store = Store.init(alloc, tfs.fs(), "objects");
    const page_store = merkle_mod.PageStore.init(alloc, tfs.fs(), "index/pages");

    var history = try History.init(alloc, tfs.fs(), "history", &obj_store, &page_store);
    defer history.deinit();

    const donor_branch = try TrackName.parse("donor-branch");
    const main = try TrackName.parse("main");

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
    try std.testing.expectEqual(@as(usize, 2), donor_history.len);
    try std.testing.expectEqual(ChangeKind.added, donor_history[1].kind);
    try std.testing.expect(merkle_mod.hashEq(donor_history[1].commit_hash, c1));
}
