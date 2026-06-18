const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const tree = @import("tree.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

pub const COMMIT_MAGIC = 0x4E_4F_44_55;
pub const COMMIT_VERSION: u8 = 1;
pub const MAX_PARENTS: u8 = 255;

/// Identity string: "Name <email>"  (caller-owned, not validated)
pub const Identity = []const u8;

pub const CommitInfo = struct {
    /// Pre-built root tree hash. Use `tree.writeFromIndex` to obtain it
    tree_hash: Hash,
    /// 0–255 parent hashes. Empty slice = initial commit
    parents: []const Hash,
    author: Identity,
    message: []const u8,
    /// Unix milliseconds. Pass 0 to use the current wall clock.
    timestamp_ms: i64,
    /// Name of the branch this commit belongs to
    /// Empty slice is acceptable (detached HEAD)
    branch: []const u8,
};

pub const Commit = struct {
    hash: Hash,
    tree_hash: Hash,
    /// Caller owns this slice and every element inside it
    parents: []Hash,
    /// Caller owns this slice
    author: []u8,
    /// Caller owns this slice
    message: []u8,
    timestamp_ms: i64,
    /// Caller owns this slice
    branch: []u8,

    pub fn deinit(self: *Commit, alloc: std.mem.Allocator) void {
        alloc.free(self.parents);
        alloc.free(self.author);
        alloc.free(self.message);
        alloc.free(self.branch);
    }
};

/// Write a commit object to the store and return its hash
///
/// The caller must supply a fully-built CommitInfo; use `buildAndWrite` when
/// you want nodus to derive the tree from the current index automatically
pub fn write(
    alloc: std.mem.Allocator,
    store: *const Store,
    info: CommitInfo,
) !Hash {
    if (info.parents.len > MAX_PARENTS)
        return error.TooManyParents;
    if (info.author.len > std.math.maxInt(u16))
        return error.FieldTooLong;
    if (info.message.len > std.math.maxInt(u16))
        return error.FieldTooLong;
    if (info.branch.len > std.math.maxInt(u16))
        return error.FieldTooLong;

    const ts: i64 = if (info.timestamp_ms != 0)
        info.timestamp_ms
    else
        std.time.milliTimestamp();

    var buf: std.io.Writer.Allocating = std.io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeInt(u32, COMMIT_MAGIC, .little);
    try w.writeByte(COMMIT_VERSION);
    try w.writeAll(&info.tree_hash);

    try w.writeByte(@intCast(info.parents.len));
    for (info.parents) |p| try w.writeAll(&p);

    try w.writeInt(u16, @intCast(info.author.len), .little);
    try w.writeAll(info.author);

    try w.writeInt(u16, @intCast(info.message.len), .little);
    try w.writeAll(info.message);

    try w.writeInt(i64, ts, .little);

    try w.writeInt(u16, @intCast(info.branch.len), .little);
    try w.writeAll(info.branch);

    return store.put(.commit, buf.written());
}

/// High-level helper: build the root tree from the index, then write the
/// commit.  Returns the commit hash.
pub fn buildAndWrite(
    alloc: std.mem.Allocator,
    store: *const Store,
    index: *const index_mod.Index,
    parents: []const Hash,
    author: Identity,
    message: []const u8,
    branch: []const u8,
) !Hash {
    const tree_hash = try tree.writeFromIndex(alloc, store, index.entries.items);
    return write(alloc, store, .{
        .tree_hash = tree_hash,
        .parents = parents,
        .author = author,
        .message = message,
        .timestamp_ms = 0,
        .branch = branch,
    });
}

/// Read and decode a commit object from the store.
/// Caller owns the returned Commit and must call `.deinit()`.
pub fn read(
    alloc: std.mem.Allocator,
    store: *const Store,
    commit_hash: Hash,
) !Commit {
    const obj = try store.get(commit_hash);
    defer alloc.free(obj.payload);

    if (obj.obj_type != .commit) return error.WrongObjectType;

    var reader = std.Io.Reader.fixed(obj.payload);

    const magic = try reader.takeInt(u32, .little);
    if (magic != COMMIT_MAGIC) return error.CorruptCommit;

    const version = try reader.takeByte();
    if (version != COMMIT_VERSION) return error.UnsupportedCommitVersion;

    var commit_tree_hash: Hash = undefined;
    @memcpy(&commit_tree_hash, try reader.take(32));

    const parent_count = try reader.takeByte();
    const parents = try alloc.alloc(Hash, parent_count);
    errdefer alloc.free(parents);
    for (parents) |*p| @memcpy(p, try reader.take(32));

    const author_len = try reader.takeInt(u16, .little);
    const author_raw = try reader.take(author_len);
    const author = try alloc.dupe(u8, author_raw);
    errdefer alloc.free(author);

    const msg_len = try reader.takeInt(u16, .little);
    const msg_raw = try reader.take(msg_len);
    const message = try alloc.dupe(u8, msg_raw);
    errdefer alloc.free(message);

    const ts = try reader.takeInt(i64, .little);

    const branch_len = try reader.takeInt(u16, .little);
    const branch_raw = try reader.take(branch_len);
    const branch = try alloc.dupe(u8, branch_raw);
    errdefer alloc.free(branch);

    return .{
        .hash = commit_hash,
        .tree_hash = commit_tree_hash,
        .parents = parents,
        .author = author,
        .message = message,
        .timestamp_ms = ts,
        .branch = branch,
    };
}

/// Resolve HEAD to a commit hash, or null for an empty repo.
/// HEAD file format: "refs/heads/<branch>" or a bare 64-char hex hash
pub fn resolveHead(
    alloc: std.mem.Allocator,
    nodus_dir: std.fs.Dir,
) !?Hash {
    const head_bytes = nodus_dir.readFileAlloc(alloc, "HEAD", 256) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(head_bytes);

    const trimmed = std.mem.trim(u8, head_bytes, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "refs/")) {
        // Symbolic ref: read the pointed-to ref file
        const ref_bytes = nodus_dir.readFileAlloc(alloc, trimmed, 128) catch |err| switch (err) {
            error.FileNotFound => return null, // branch exists but has no commits yet
            else => return err,
        };
        defer alloc.free(ref_bytes);
        const hex = std.mem.trim(u8, ref_bytes, " \t\r\n");
        return try hash_mod.fromHex(hex);
    }

    // Detached HEAD: bare hash
    return try hash_mod.fromHex(trimmed);
}

/// Write HEAD as a symbolic reference to a branch
pub fn writeHeadRef(nodus_dir: std.fs.Dir, branch: []const u8) !void {
    var buf: [256]u8 = undefined;
    const ref = try std.fmt.bufPrint(&buf, "refs/heads/{s}", .{branch});
    try writeFile(nodus_dir, "HEAD", ref);
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

/// Convenience: resolve HEAD branch name from "refs/heads/<branch>".
/// Returns null if HEAD is detached or missing.
pub fn headBranch(
    alloc: std.mem.Allocator,
    nodus_dir: std.fs.Dir,
) !?[]u8 {
    const head_bytes = nodus_dir.readFileAlloc(alloc, "HEAD", 256) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(head_bytes);

    const trimmed = std.mem.trim(u8, head_bytes, " \t\r\n");
    const prefix = "refs/heads/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    return @as(?[]u8, try alloc.dupe(u8, trimmed[prefix.len..]));
}

fn writeFile(dir: std.fs.Dir, path: []const u8, content: []const u8) !void {
    const f = try dir.createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

test "commit write and read round-trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    // We need a valid tree hash — store a dummy tree object
    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4); // empty tree (count=0)

    const commit_hash = try write(alloc, &store, .{
        .tree_hash = tree_hash,
        .parents = &.{},
        .author = "Bruce Wayne <bruce@wayne.corp>",
        .message = "initial commit",
        .timestamp_ms = 1_700_000_000_000,
        .branch = "main",
    });

    var c = try read(alloc, &store, commit_hash);
    defer c.deinit(alloc);

    try std.testing.expectEqualSlices(u8, &tree_hash, &c.tree_hash);
    try std.testing.expectEqual(@as(usize, 0), c.parents.len);
    try std.testing.expectEqualStrings("Bruce Wayne <bruce@wayne.corp>", c.author);
    try std.testing.expectEqualStrings("initial commit", c.message);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), c.timestamp_ms);
    try std.testing.expectEqualStrings("main", c.branch);
    try std.testing.expectEqualSlices(u8, &commit_hash, &c.hash);
}

test "commit with parents" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    // First commit
    const parent_hash = try write(alloc, &store, .{
        .tree_hash = tree_hash,
        .parents = &.{},
        .author = "Alan Turing <alan@nodus.dev>",
        .message = "root",
        .timestamp_ms = 1_000,
        .branch = "main",
    });

    // Child commit referencing parent
    const child_hash = try write(alloc, &store, .{
        .tree_hash = tree_hash,
        .parents = &.{parent_hash},
        .author = "Alan Turing <alan@nodus.dev>",
        .message = "second",
        .timestamp_ms = 2_000,
        .branch = "main",
    });

    var c = try read(alloc, &store, child_hash);
    defer c.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), c.parents.len);
    try std.testing.expectEqualSlices(u8, &parent_hash, &c.parents[0]);
    try std.testing.expectEqualStrings("second", c.message);
}

test "commit is deterministic for same inputs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);

    const h1 = try write(alloc, &store, .{
        .tree_hash = tree_hash,
        .parents = &.{},
        .author = "test",
        .message = "msg",
        .timestamp_ms = 42,
        .branch = "main",
    });
    const h2 = try write(alloc, &store, .{
        .tree_hash = tree_hash,
        .parents = &.{},
        .author = "test",
        .message = "msg",
        .timestamp_ms = 42,
        .branch = "main",
    });

    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "wrong object type returns error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    // Store a blob, try to read it as commit
    const blob_hash = try store.put(.blob, "not a commit");
    try std.testing.expectError(error.WrongObjectType, read(alloc, &store, blob_hash));
}

test "resolveHead returns null when HEAD missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try resolveHead(alloc, tmp.dir);
    try std.testing.expectEqual(@as(?Hash, null), result);
}

test "writeHeadRef and updateRef and resolveHead round-trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const tree_hash = try store.put(.tree, &[_]u8{0} ** 4);
    const commit_hash = try write(alloc, &store, .{
        .tree_hash = tree_hash,
        .parents = &.{},
        .author = "dev",
        .message = "init",
        .timestamp_ms = 1,
        .branch = "main",
    });

    try writeHeadRef(tmp.dir, "main");
    try updateRef(alloc, tmp.dir, "main", commit_hash);

    const resolved = try resolveHead(alloc, tmp.dir);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualSlices(u8, &commit_hash, &resolved.?);

    const branch = try headBranch(alloc, tmp.dir);
    defer if (branch) |b| alloc.free(b);
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("main", branch.?);
}

test "buildAndWrite creates tree then commit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Set up minimal store + index
    var objects_dir = try tmp.dir.makeOpenPath(".nodus/objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    // Put a blob so the index entry is valid
    const blob_hash = try store.put(.blob, "hello nodus");

    // Index.deinit closes its .dir handle, so we must not close nodus_dir ourselves.
    const nodus_dir = try tmp.dir.openDir(".nodus", .{});

    var idx = index_mod.Index{ .alloc = alloc, .dir = nodus_dir, .entries = .empty };
    defer idx.deinit();

    try idx.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "hello.txt"),
        .blob_hash = blob_hash,
        .size = 11,
        .mode = 0o100644,
        .mtime = 0,
    });

    const commit_hash = try buildAndWrite(
        alloc,
        &store,
        &idx,
        &.{},
        "Test Author <test@nodus.dev>",
        "add hello.txt",
        "main",
    );

    var c = try read(alloc, &store, commit_hash);
    defer c.deinit(alloc);

    try std.testing.expectEqualStrings("add hello.txt", c.message);
    try std.testing.expectEqualStrings("main", c.branch);
    try std.testing.expectEqual(@as(usize, 0), c.parents.len);

    // Verify the tree object was created in the store
    const tree_obj = try store.get(c.tree_hash);
    defer alloc.free(tree_obj.payload);
    try std.testing.expectEqual(object.ObjectType.tree, tree_obj.obj_type);
}
