//  Thin merkle-tree adapter over diff_algorithms.zig: turns two
//  snapshot-root hashes into per-path EntryChanges via
//  merk.merkle.diffRoots, then runs the content-diff engine over just
//  the paths that changed. All the pruning (identical page hashes never
//  read from disk) lives in merk.merkle.diffRoots — this file's only
//  job is turning its output into content-level line/word diffs by
//  fetching just the changed blobs.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const crypto = @import("crypto");
const merkle_mod = @import("merkle");
const MemoryFs = @import("storage").MemoryFs;

const Store = @import("../object.zig").Store;
const commit_mod = @import("./../commit.zig"); // TODO!: expose what we need from commit.zig only
const diff_algorithms = @import("diff_algorithms.zig");

const Hash = crypto.Hash;
const PageStore = merkle_mod.PageStore;
const Entry = merkle_mod.Entry;
const diffRoots = merkle_mod.diffRoots;
const freeChanges = merkle_mod.freeChanges;
const build = merkle_mod.build;

const CommitDiff = diff_algorithms.CommitDiff;
const FileDiff = diff_algorithms.FileDiff;
const Algorithm = diff_algorithms.Algorithm;

/// Diff two snapshot roots — hashes of merkle B-tree pages built by
/// `merk.merkle.build` (what `Index.save`/`History.commit` produce).
/// `old_root == null` means "empty tree" (the root-commit case): every
/// entry in `new_root` shows up as added.
pub fn diffSnapshotRoots(
    alloc: Allocator,
    store: *const Store,
    page_store: *const PageStore,
    old_root: ?Hash,
    new_root: Hash,
    algo: Algorithm,
) !CommitDiff {
    const normalized_old = old_root orelse crypto.zero_hash;
    const changes = try diffRoots(alloc, page_store, normalized_old, new_root);
    defer freeChanges(alloc, changes);

    var file_diffs: ArrayList(FileDiff) = .empty;
    var blobs: ArrayList([]u8) = .empty;
    errdefer {
        for (file_diffs.items) |*f| f.deinit(alloc);
        file_diffs.deinit(alloc);
        for (blobs.items) |b| alloc.free(b);
        blobs.deinit(alloc);
    }

    for (changes) |c| {
        const old_src = if (c.old_blob_hash) |h| blk: {
            const obj = try store.get(h);
            try blobs.append(alloc, obj.payload);
            break :blk obj.payload;
        } else "";

        const new_src = if (c.new_blob_hash) |h| blk: {
            const obj = try store.get(h);
            try blobs.append(alloc, obj.payload);
            break :blk obj.payload;
        } else "";

        try file_diffs.append(alloc, try diff_algorithms.diffFileWith(alloc, c.path, old_src, new_src, algo));
    }

    return .{
        .files = try file_diffs.toOwnedSlice(alloc),
        .line_diff_hash = .{0} ** 32,
        .word_diff_hash = .{0} ** 32,
        .blobs = try blobs.toOwnedSlice(alloc),
    };
}

/// Diff the snapshot of `new_commit` against the snapshot of `old_commit`.
/// Pass `null` for `old_commit` to diff against an empty tree, e.g. for
/// the root commit, where there is no parent to compare against.
pub fn diffCommits(
    alloc: Allocator,
    store: *const Store,
    page_store: *const PageStore,
    old_commit: ?Hash,
    new_commit: Hash,
    algo: Algorithm,
) !CommitDiff {
    var new_c = try commit_mod.read(alloc, store, new_commit);
    defer new_c.deinit(alloc);

    var old_root: ?Hash = null;
    var old_c: ?commit_mod.Commit = null;
    defer if (old_c) |*c| c.deinit(alloc);

    if (old_commit) |oc| {
        old_c = try commit_mod.read(alloc, store, oc);
        old_root = old_c.?.snapshot;
    }

    return diffSnapshotRoots(alloc, store, page_store, old_root, new_c.snapshot, algo);
}

/// Diff `new_commit` against its first parent. If `new_commit` has no
/// parents (a root commit), diffs against an empty tree. For a merge
/// commit (more than one `ParentInfo`), this is a first-parent diff —
/// same convention `git show` uses by default — not a diff against
/// every parent.
pub fn diffCommitAgainstParent(
    alloc: Allocator,
    store: *const Store,
    page_store: *const PageStore,
    new_commit: Hash,
    algo: Algorithm,
) !CommitDiff {
    var new_c = try commit_mod.read(alloc, store, new_commit);
    defer new_c.deinit(alloc);

    const old_root: ?Hash = if (new_c.parents.len > 0) blk: {
        var parent_c = try commit_mod.read(alloc, store, new_c.parents[0].hash);
        defer parent_c.deinit(alloc);
        break :blk parent_c.snapshot;
    } else null;

    return diffSnapshotRoots(alloc, store, page_store, old_root, new_c.snapshot, algo);
}

const io = @import("storage");

const FileSeed = struct { path: []const u8, content: []const u8 };

fn buildRoot(
    alloc: Allocator,
    page_store: *const PageStore,
    store: *const Store,
    seeds: []const FileSeed,
) !Hash {
    var entries: ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(alloc);
        entries.deinit(alloc);
    }
    for (seeds) |seed| {
        const blob_hash = try store.put(.blob, seed.content);
        try entries.append(alloc, .{
            .path = try alloc.dupe(u8, seed.path),
            .blob_hash = blob_hash,
            .size = seed.content.len,
            .mode = 0o100644,
            .mtime = 1,
        });
    }
    return build(alloc, page_store, entries.items);
}

fn findFileDiff(cd: *const CommitDiff, path: []const u8) ?*const FileDiff {
    for (cd.files) |*fd| {
        if (std.mem.eql(u8, fd.path, path)) return fd;
    }
    return null;
}

test "diffSnapshotRoots reports modified, added, and removed files via merkle pruning" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();
    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const page_store = PageStore.init(alloc, mem_fs.fs(), "index/pages");

    const old_root = try buildRoot(alloc, &page_store, &store, &.{
        .{ .path = "a.txt", .content = "hello\nworld\n" },
        .{ .path = "b.txt", .content = "keep me\n" },
        .{ .path = "gone.txt", .content = "bye\n" },
    });
    const new_root = try buildRoot(alloc, &page_store, &store, &.{
        .{ .path = "a.txt", .content = "hello\nearth\n" },
        .{ .path = "b.txt", .content = "keep me\n" },
        .{ .path = "new.txt", .content = "fresh\n" },
    });

    var cd = try diffSnapshotRoots(alloc, &store, &page_store, old_root, new_root, .histogram);
    defer cd.deinit(alloc);

    try testing.expectEqual(@as(usize, 3), cd.files.len);

    const a = findFileDiff(&cd, "a.txt") orelse return error.MissingFile;
    try testing.expectEqual(@as(u32, 1), a.lines_added);
    try testing.expectEqual(@as(u32, 1), a.lines_removed);

    const gone = findFileDiff(&cd, "gone.txt") orelse return error.MissingFile;
    try testing.expectEqual(@as(u32, 0), gone.lines_added);
    try testing.expectEqual(@as(u32, 1), gone.lines_removed);

    const new_file = findFileDiff(&cd, "new.txt") orelse return error.MissingFile;
    try testing.expectEqual(@as(u32, 1), new_file.lines_added);
    try testing.expectEqual(@as(u32, 0), new_file.lines_removed);
}

test "diffSnapshotRoots against a null old_root reports every entry as added" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();
    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const page_store = PageStore.init(alloc, mem_fs.fs(), "index/pages");

    const new_root = try buildRoot(alloc, &page_store, &store, &.{
        .{ .path = "a.txt", .content = "one\n" },
        .{ .path = "b.txt", .content = "two\n" },
    });

    var cd = try diffSnapshotRoots(alloc, &store, &page_store, null, new_root, .histogram);
    defer cd.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), cd.files.len);
    for (cd.files) |fd| {
        try testing.expectEqual(@as(u32, 1), fd.lines_added);
        try testing.expectEqual(@as(u32, 0), fd.lines_removed);
    }
}

test "diffCommits resolves commit hashes to snapshot roots before diffing" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();
    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const page_store = PageStore.init(alloc, mem_fs.fs(), "index/pages");

    const root1 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "v1\n" }});
    var b1 = commit_mod.CommitBuilder.init(alloc, root1);
    defer b1.deinit();
    _ = b1.author("Dev", "dev@nodus.dev", 1);
    _ = b1.intent(.feature);
    _ = b1.title("first");
    const c1 = try b1.write(&store);

    const root2 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "v2\n" }});
    var b2 = commit_mod.CommitBuilder.init(alloc, root2);
    defer b2.deinit();
    _ = try b2.parent(c1);
    _ = b2.author("Dev", "dev@nodus.dev", 2);
    _ = b2.intent(.feature);
    _ = b2.title("second");
    const c2 = try b2.write(&store);

    var cd = try diffCommits(alloc, &store, &page_store, c1, c2, .histogram);
    defer cd.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), cd.files.len);
    try testing.expectEqualStrings("a.txt", cd.files[0].path);
    try testing.expectEqual(@as(u32, 1), cd.files[0].lines_added);
    try testing.expectEqual(@as(u32, 1), cd.files[0].lines_removed);
}

test "diffCommitAgainstParent treats a root commit as a diff against the empty tree" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();
    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const page_store = PageStore.init(alloc, mem_fs.fs(), "index/pages");

    const root1 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "hello\n" }});
    var b1 = commit_mod.CommitBuilder.init(alloc, root1);
    defer b1.deinit();
    _ = b1.author("Dev", "dev@nodus.dev", 1);
    _ = b1.intent(.feature);
    _ = b1.title("root");
    const c1 = try b1.write(&store);

    var cd = try diffCommitAgainstParent(alloc, &store, &page_store, c1, .histogram);
    defer cd.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), cd.files.len);
    try testing.expectEqualStrings("a.txt", cd.files[0].path);
    try testing.expectEqual(@as(u32, 1), cd.files[0].lines_added);
    try testing.expectEqual(@as(u32, 0), cd.files[0].lines_removed);
}

test "diffCommitAgainstParent uses the first (mainline) parent's snapshot" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();
    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const page_store = PageStore.init(alloc, mem_fs.fs(), "index/pages");

    const root1 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "v1\n" }});
    var b1 = commit_mod.CommitBuilder.init(alloc, root1);
    defer b1.deinit();
    _ = b1.author("Dev", "dev@nodus.dev", 1);
    _ = b1.intent(.feature);
    _ = b1.title("first");
    const c1 = try b1.write(&store);

    const root2 = try buildRoot(alloc, &page_store, &store, &.{.{ .path = "a.txt", .content = "v2\n" }});
    var b2 = commit_mod.CommitBuilder.init(alloc, root2);
    defer b2.deinit();
    _ = try b2.parent(c1);
    _ = b2.author("Dev", "dev@nodus.dev", 2);
    _ = b2.intent(.feature);
    _ = b2.title("second");
    const c2 = try b2.write(&store);

    var cd = try diffCommitAgainstParent(alloc, &store, &page_store, c2, .histogram);
    defer cd.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), cd.files.len);
    try testing.expectEqualStrings("a.txt", cd.files[0].path);
    try testing.expectEqual(@as(u32, 1), cd.files[0].lines_added);
    try testing.expectEqual(@as(u32, 1), cd.files[0].lines_removed);
}

test {
    testing.refAllDecls(@This());
}
