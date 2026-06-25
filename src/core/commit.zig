const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const tree = @import("tree.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

const identity = @import("./commit/identity.zig");
const IdentityInfo = identity.IdentityInfo;
const Identity = identity.Identity;

const message = @import("./commit/message.zig");
const Message = message.Message;
const MessageInfo = message.MessageInfo;

const snapshot = @import("./commit/snapshot.zig");
const Snapshot = snapshot.Snapshot;
const snapshotInfo = snapshot.SnapshotInfo;

const commitMetadata = @import("./commit/metadata.zig");
const CommitMetadata = commitMetadata.CommitMetadata;
const CommitMetadataInfo = commitMetadata.CommitMetadataInfo;

const refs = @import("./refs.zig");
pub const COMMIT_MAGIC = 0x4E_4F_44_55;

pub const MAX_PARENTS: u8 = 255;

pub const CommitInfo = struct {
    snapshot: snapshotInfo,

    author: IdentityInfo,

    metadata: CommitMetadataInfo = .{},
    message: MessageInfo,

    pub fn validate(self: @This()) !void {
        try self.snapshot.validate();
        try self.author.validate();
        try self.metadata.validate();
        try self.message.validate();
    }
};

pub const Commit = struct {
    /// Object identifier of this commit.
    hash: Hash,

    /// Repository state represented by this commit.
    snapshot: Snapshot,

    /// Author of the commit.
    author: Identity,

    metadata: CommitMetadata,

    message: Message,

    pub fn deinit(
        self: *Commit,
        alloc: std.mem.Allocator,
    ) void {
        self.snapshot.deinit(alloc);
        self.author.deinit(alloc);
        self.metadata.deinit(alloc);
        self.message.deinit(alloc);

        self.* = undefined;
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
    try info.validate();

    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const writer = &buf.writer;

    try writer.writeInt(
        u32,
        COMMIT_MAGIC,
        .little,
    );

    try info.snapshot.serialize(writer);

    try info.author.serialize(writer);

    try info.metadata.serialize(writer);

    try info.message.serialize(writer);

    return store.put(
        .commit,
        buf.written(),
    );
}

/// High-level helper: build the root tree from the index, then write the
/// commit.  Returns the commit hash.
pub fn buildAndWrite(
    alloc: std.mem.Allocator,
    store: *const Store,
    index: *const index_mod.Index,
    info: CommitInfo,
) !Hash {
    const tree_hash = try tree.writeFromIndex(
        alloc,
        store,
        index.entries.items,
    );

    var commit_info = info;
    commit_info.snapshot.tree = tree_hash;

    return write(
        alloc,
        store,
        commit_info,
    );
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

    if (obj.obj_type != .commit)
        return error.WrongObjectType;

    var reader = std.Io.Reader.fixed(obj.payload);

    const magic = try reader.takeInt(u32, .little);

    if (magic != COMMIT_MAGIC)
        return error.CorruptCommit;

    var deserialized_snapshot = try Snapshot.deserialize(
        alloc,
        &reader,
    );
    errdefer deserialized_snapshot.deinit(alloc);

    var author = try Identity.deserialize(
        alloc,
        &reader,
    );
    errdefer author.deinit(alloc);

    var metadata = try CommitMetadataInfo.deserialize(
        alloc,
        &reader,
    );
    errdefer metadata.deinit(alloc);

    var deserialized_message = try Message.deserialize(
        alloc,
        &reader,
    );
    errdefer deserialized_message.deinit(alloc);

    return .{
        .hash = commit_hash,
        .snapshot = deserialized_snapshot,
        .author = author,
        .metadata = metadata,
        .message = deserialized_message,
    };
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

    var objects_dir = try tmp.dir.makeOpenPath(
        "objects",
        .{},
    );
    defer objects_dir.close();

    var store = Store{
        .dir = objects_dir,
        .alloc = alloc,
    };

    // Valid tree object
    const tree_hash = try store.put(
        .tree,
        &[_]u8{0} ** 4,
    );

    const commit_hash = try write(
        alloc,
        &store,
        .{
            .snapshot = .{
                .tree = tree_hash,
                .parents = &.{},
            },

            .author = .{
                .name = "Bruce Wayne",
                .email = "bruce@wayne.corp",
            },

            .metadata = .{
                .timestamp_ms = 1_700_000_000_000,
                .intent = .feature,
                .labels = &.{
                    "core",
                    "storage",
                },
            },

            .message = .{
                .title = "Initial commit",
                .body = "Create the initial repository structure.",
            },
        },
    );

    var c = try read(
        alloc,
        &store,
        commit_hash,
    );
    defer c.deinit(alloc);

    try std.testing.expectEqualSlices(
        u8,
        &tree_hash,
        &c.snapshot.tree,
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        c.snapshot.parents.len,
    );

    try std.testing.expectEqualStrings(
        "Bruce Wayne",
        c.author.name,
    );

    try std.testing.expectEqualStrings(
        "bruce@wayne.corp",
        c.author.email,
    );

    try std.testing.expectEqual(
        @as(i64, 1_700_000_000_000),
        c.metadata.timestamp_ms,
    );

    try std.testing.expectEqual(
        commitMetadata.Intent.feature,
        c.metadata.intent,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        c.metadata.labels.len,
    );

    try std.testing.expectEqualStrings(
        "core",
        c.metadata.labels[0],
    );

    try std.testing.expectEqualStrings(
        "storage",
        c.metadata.labels[1],
    );

    try std.testing.expectEqualStrings(
        "Initial commit",
        c.message.title,
    );

    try std.testing.expectEqualStrings(
        "Create the initial repository structure.",
        c.message.body,
    );

    try std.testing.expectEqualSlices(
        u8,
        &commit_hash,
        &c.hash,
    );
}

test "commit with parents" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();

    var store = Store{
        .dir = objects_dir,
        .alloc = alloc,
    };

    const tree_hash = try store.put(
        .tree,
        &[_]u8{0} ** 4,
    );

    // Root commit
    const parent_hash = try write(alloc, &store, .{
        .snapshot = .{
            .tree = tree_hash,
            .parents = &.{},
        },

        .author = .{
            .name = "Alan Turing",
            .email = "alan@nodus.dev",
        },
        .metadata = .{
            .timestamp_ms = 1_000,
            .intent = .feature,
            .labels = &.{},
        },
        .message = .{
            .title = "root",
            .body = "",
        },
    });

    // Child commit
    const child_hash = try write(alloc, &store, .{
        .snapshot = .{
            .tree = tree_hash,
            .parents = &.{parent_hash},
        },

        .author = .{
            .name = "Alan Turing",
            .email = "alan@nodus.dev",
        },
        .metadata = .{
            .timestamp_ms = 2_000,
            .intent = .feature,
            .labels = &.{},
        },
        .message = .{
            .title = "second",
            .body = "",
        },
    });

    var c = try read(
        alloc,
        &store,
        child_hash,
    );
    defer c.deinit(alloc);

    try std.testing.expectEqual(
        @as(usize, 1),
        c.snapshot.parents.len,
    );

    try std.testing.expectEqualSlices(
        u8,
        &parent_hash,
        &c.snapshot.parents[0],
    );

    try std.testing.expectEqualStrings(
        "second",
        c.message.title,
    );

    try std.testing.expectEqualStrings(
        "Alan Turing",
        c.author.name,
    );

    try std.testing.expectEqualStrings(
        "alan@nodus.dev",
        c.author.email,
    );
}

test "commit is deterministic for same inputs" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();

    var store = Store{
        .dir = objects_dir,
        .alloc = alloc,
    };

    const tree_hash = try store.put(
        .tree,
        &[_]u8{0} ** 4,
    );

    const h1 = try write(alloc, &store, .{ .snapshot = .{
        .tree = tree_hash,
        .parents = &.{},
    }, .author = .{
        .name = "Test User",
        .email = "test@nodus.dev",
    }, .metadata = .{
        .timestamp_ms = 42,
        .intent = .feature,
        .labels = &.{
            "core",
            "storage",
        },
    }, .message = .{
        .title = "msg",
        .body = "deterministic commit",
    } });

    const h2 = try write(alloc, &store, .{
        .snapshot = .{
            .tree = tree_hash,
            .parents = &.{},
        },
        .author = .{
            .name = "Test User",
            .email = "test@nodus.dev",
        },
        .metadata = .{
            .timestamp_ms = 42,
            .intent = .feature,
            .labels = &.{
                "core",
                "storage",
            },
        },
        .message = .{
            .title = "msg",
            .body = "deterministic commit",
        },
    });

    try std.testing.expectEqualSlices(
        u8,
        &h1,
        &h2,
    );
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

    const result = try refs.resolveHead(alloc, tmp.dir);
    try std.testing.expectEqual(@as(?Hash, null), result);
}

test "writeHeadRef and updateRef and resolveHead round-trip" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();

    var store = Store{
        .dir = objects_dir,
        .alloc = alloc,
    };

    const tree_hash = try store.put(
        .tree,
        &[_]u8{0} ** 4,
    );

    const commit_hash = try write(alloc, &store, .{
        .snapshot = .{
            .tree = tree_hash,
            .parents = &.{},
        },
        .author = .{
            .name = "dev",
            .email = "dev@nodus.local",
        },
        .metadata = .{
            .timestamp_ms = 1,
            .intent = .chore,
            .labels = &.{},
        },
        .message = .{
            .title = "init",
            .body = "",
        },
    });

    try refs.writeHeadRef(tmp.dir, "main");
    try refs.updateRef(alloc, tmp.dir, "main", commit_hash);

    const resolved = try refs.resolveHead(
        alloc,
        tmp.dir,
    );

    try std.testing.expect(resolved != null);

    try std.testing.expectEqualSlices(
        u8,
        &commit_hash,
        &resolved.?,
    );

    const branch = try refs.headBranch(
        alloc,
        tmp.dir,
    );
    defer if (branch) |b| alloc.free(b);

    try std.testing.expect(branch != null);

    try std.testing.expectEqualStrings(
        "main",
        branch.?,
    );
}

test "buildAndWrite creates tree then commit" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var objects_dir = try tmp.dir.makeOpenPath(
        ".nodus/objects",
        .{},
    );
    defer objects_dir.close();

    var store = Store{
        .dir = objects_dir,
        .alloc = alloc,
    };

    const blob_hash = try store.put(
        .blob,
        "hello nodus",
    );

    const nodus_dir = try tmp.dir.openDir(
        ".nodus",
        .{},
    );

    var idx = index_mod.Index{
        .alloc = alloc,
        .dir = nodus_dir,
        .entries = .empty,
    };
    defer idx.deinit();

    try idx.entries.append(alloc, .{
        .path = try alloc.dupe(
            u8,
            "hello.txt",
        ),
        .blob_hash = blob_hash,
        .size = 11,
        .mode = 0o100644,
        .mtime = 0,
    });

    const commit_hash = try buildAndWrite(
        alloc,
        &store,
        &idx,
        .{
            .snapshot = .{
                .tree = undefined, // overwritten internally
                .parents = &.{},
            },

            .author = .{
                .name = "Test Author",
                .email = "test@nodus.dev",
            },

            .metadata = .{
                .timestamp_ms = 0,

                .intent = .feature,

                .labels = &.{
                    "core",
                    "storage",
                },
            },

            .message = .{
                .title = "add hello.txt",
                .body = "",
            },
        },
    );
    var c = try read(
        alloc,
        &store,
        commit_hash,
    );
    defer c.deinit(alloc);

    try std.testing.expectEqualStrings(
        "add hello.txt",
        c.message.title,
    );

    try std.testing.expectEqualStrings(
        "Test Author",
        c.author.name,
    );

    try std.testing.expectEqualStrings(
        "test@nodus.dev",
        c.author.email,
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        c.snapshot.parents.len,
    );

    const tree_obj = try store.get(
        c.snapshot.tree,
    );
    defer alloc.free(tree_obj.payload);

    try std.testing.expectEqual(
        object.ObjectType.tree,
        tree_obj.obj_type,
    );
}
