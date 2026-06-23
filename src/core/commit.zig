const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const tree = @import("tree.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

pub const COMMIT_MAGIC = 0x4E_4F_44_55;

pub const MAX_PARENTS: u8 = 255;

// pub const Identity = struct {
//     name: []u8,
//     email: []u8,

//     pub fn deinit(self: *Identity, alloc: std.mem.Allocator) void {
//         alloc.free(self.name);
//         alloc.free(self.email);
//     }
// };

pub const IdentityError = error{
    EmptyName,
    EmptyEmail,

    NameTooLong,
    EmailTooLong,

    NameContainsIllegalCharacters,
    EmailContainsIllegalCharacters,

    MissingEmailAtSign,
    InvalidEmailBounds,
};

pub const IdentityInfo = struct {
    name: []const u8,
    email: []const u8,

    pub fn validate(self: IdentityInfo) IdentityError!void {
        const trimmed_name =
            std.mem.trim(u8, self.name, " \t\r\n");

        const trimmed_email =
            std.mem.trim(u8, self.email, " \t\r\n");

        if (trimmed_name.len == 0)
            return error.EmptyName;

        if (trimmed_email.len == 0)
            return error.EmptyEmail;

        if (trimmed_name.len > std.math.maxInt(u16))
            return error.NameTooLong;

        if (trimmed_email.len > std.math.maxInt(u16))
            return error.EmailTooLong;

        // Prevent header/object injection.
        const illegal_name_chars = &[_]u8{
            '\n',
            '\r',
            '<',
            '>',
            '\x00',
        };

        if (std.mem.indexOfAny(
            u8,
            trimmed_name,
            illegal_name_chars,
        ) != null) {
            return error.NameContainsIllegalCharacters;
        }

        // Emails must not contain whitespace,
        // control chars, or angle brackets.
        const illegal_email_chars = &[_]u8{
            ' ',
            '\t',
            '\n',
            '\r',
            '<',
            '>',
            '\x00',
        };

        if (std.mem.indexOfAny(
            u8,
            trimmed_email,
            illegal_email_chars,
        ) != null) {
            return error.EmailContainsIllegalCharacters;
        }

        const at_idx =
            std.mem.indexOfScalar(
                u8,
                trimmed_email,
                '@',
            ) orelse return error.MissingEmailAtSign;

        if (at_idx == 0 or at_idx == trimmed_email.len - 1)
            return error.InvalidEmailBounds;

        if (std.mem.indexOfScalar(
            u8,
            trimmed_email[at_idx + 1 ..],
            '@',
        ) != null) {
            return error.EmailContainsIllegalCharacters;
        }
    }

    pub fn serialize(
        self: IdentityInfo,
        writer: anytype,
    ) !void {
        try self.validate();

        const trimmed_name =
            std.mem.trim(u8, self.name, " \t\r\n");

        const trimmed_email =
            std.mem.trim(u8, self.email, " \t\r\n");

        try writer.writeInt(
            u16,
            @intCast(trimmed_name.len),
            .little,
        );
        try writer.writeAll(trimmed_name);

        try writer.writeInt(
            u16,
            @intCast(trimmed_email.len),
            .little,
        );
        try writer.writeAll(trimmed_email);
    }
};

/// The allocated, owned identity variant stored inside a deserialized Commit object.
pub const Identity = struct {
    name: []u8,
    email: []u8,

    pub fn initDupe(
        alloc: std.mem.Allocator,
        info: IdentityInfo,
    ) !Identity {
        try info.validate();

        const trimmed_name =
            std.mem.trim(u8, info.name, " \t\r\n");

        const trimmed_email =
            std.mem.trim(u8, info.email, " \t\r\n");

        const name = try alloc.dupe(
            u8,
            trimmed_name,
        );
        errdefer alloc.free(name);

        const email = try alloc.dupe(
            u8,
            trimmed_email,
        );
        errdefer alloc.free(email);

        return .{
            .name = name,
            .email = email,
        };
    }

    pub fn deserialize(
        alloc: std.mem.Allocator,
        reader: anytype,
    ) !Identity {
        const name_len = try reader.takeInt(u16, .little);

        const name = try alloc.dupe(
            u8,
            try reader.take(name_len),
        );
        errdefer alloc.free(name);

        const email_len = try reader.takeInt(u16, .little);

        const email = try alloc.dupe(
            u8,
            try reader.take(email_len),
        );
        errdefer alloc.free(email);

        const info = IdentityInfo{
            .name = name,
            .email = email,
        };

        try info.validate();

        return .{
            .name = name,
            .email = email,
        };
    }

    pub fn deinit(
        self: *Identity,
        alloc: std.mem.Allocator,
    ) void {
        alloc.free(self.name);
        alloc.free(self.email);

        self.* = undefined;
    }
};
pub const Intent = enum {
    feature,
    bugfix,
    refactor,
    docs,
    @"test",
    release,
    chore,
};

pub const MessageInfo = struct {
    title: []const u8,
    body: []const u8 = "",

    pub fn validate(self: MessageInfo) !void {
        if (self.title.len == 0) return error.EmptyCommitMessage;
    }
};

pub const Message = struct {
    title: []u8,
    body: []u8,

    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const CommitInfo = struct {
    /// Root tree snapshot.
    tree_hash: Hash,

    /// Empty slice for initial commit.
    parents: []const Hash,

    author: IdentityInfo,

    /// Pass 0 to use current wall clock.
    timestamp_ms: i64,

    intent: Intent = .chore,

    /// Optional labels such as:
    /// ["cli", "diff", ""]
    labels: []const []const u8 = &.{},

    message: MessageInfo,
};

pub const Commit = struct {
    hash: Hash,

    tree_hash: Hash,

    /// Owned by caller.
    parents: []Hash,

    author: Identity,

    timestamp_ms: i64,

    intent: Intent,

    /// Owned by caller.
    labels: [][]u8,

    message: Message,

    pub fn deinit(self: *Commit, alloc: std.mem.Allocator) void {
        alloc.free(self.parents);

        self.author.deinit(alloc);

        for (self.labels) |label| {
            alloc.free(label);
        }
        alloc.free(self.labels);

        self.message.deinit(alloc);
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

    try info.author.validate();

    try info.message.validate();

    if (info.labels.len > std.math.maxInt(u16))
        return error.FieldTooLong;

    for (info.labels) |label| {
        if (label.len > std.math.maxInt(u16))
            return error.FieldTooLong;
    }

    const ts: i64 = if (info.timestamp_ms != 0)
        info.timestamp_ms
    else
        std.time.milliTimestamp();

    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const w = &buf.writer;

    try w.writeInt(u32, COMMIT_MAGIC, .little);

    try w.writeAll(&info.tree_hash);

    try w.writeByte(@intCast(info.parents.len));

    for (info.parents) |parent| {
        try w.writeAll(&parent);
    }

    try info.author.serialize(w);

    try w.writeInt(i64, ts, .little);
    try w.writeByte(@intFromEnum(info.intent));

    try w.writeInt(
        u16,
        @intCast(info.labels.len),
        .little,
    );

    for (info.labels) |label| {
        try w.writeInt(
            u16,
            @intCast(label.len),
            .little,
        );
        try w.writeAll(label);
    }

    try w.writeInt(
        u16,
        @intCast(info.message.title.len),
        .little,
    );
    try w.writeAll(info.message.title);

    try w.writeInt(
        u32,
        @intCast(info.message.body.len),
        .little,
    );
    try w.writeAll(info.message.body);

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
    commit_info.tree_hash = tree_hash;

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

    var tree_hash: Hash = undefined;
    @memcpy(&tree_hash, try reader.take(32));

    const parent_count = try reader.takeByte();

    const parents = try alloc.alloc(Hash, parent_count);
    errdefer alloc.free(parents);

    for (parents) |*parent| {
        @memcpy(parent, try reader.take(32));
    }

    var author = try Identity.deserialize(
        alloc,
        &reader,
    );
    errdefer author.deinit(alloc);

    const timestamp_ms = try reader.takeInt(
        i64,
        .little,
    );

    const intent_raw = try reader.takeByte();

    const intent: Intent = std.meta.intToEnum(
        Intent,
        intent_raw,
    ) catch return error.CorruptCommit;

    const label_count = try reader.takeInt(
        u16,
        .little,
    );

    const labels = try alloc.alloc(
        []u8,
        label_count,
    );

    var labels_initialized: usize = 0;

    errdefer {
        for (labels[0..labels_initialized]) |label| {
            alloc.free(label);
        }

        alloc.free(labels);
    }

    while (labels_initialized < label_count) : (labels_initialized += 1) {
        const len = try reader.takeInt(
            u16,
            .little,
        );

        labels[labels_initialized] = try alloc.dupe(
            u8,
            try reader.take(len),
        );
    }

    const title_len = try reader.takeInt(
        u16,
        .little,
    );

    const title = try alloc.dupe(
        u8,
        try reader.take(title_len),
    );
    errdefer alloc.free(title);

    const body_len = try reader.takeInt(
        u32,
        .little,
    );

    const body = try alloc.dupe(
        u8,
        try reader.take(body_len),
    );
    errdefer alloc.free(body);

    var commit = Commit{
        .hash = commit_hash,

        .tree_hash = tree_hash,

        .parents = parents,

        .author = author,

        .timestamp_ms = timestamp_ms,

        .intent = intent,

        .labels = labels,

        .message = undefined,
    };

    errdefer commit.deinit(alloc);

    commit.message = .{
        .title = title,
        .body = body,
    };
    return commit;
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

    var store = Store{
        .dir = objects_dir,
        .alloc = alloc,
    };

    // Valid tree object
    const tree_hash = try store.put(
        .tree,
        &[_]u8{0} ** 4,
    );

    const commit_hash = try write(alloc, &store, .{
        .tree_hash = tree_hash,
        .parents = &.{},
        .author = .{
            .name = "Bruce Wayne",
            .email = "bruce@wayne.corp",
        },
        .timestamp_ms = 1_700_000_000_000,
        .intent = .feature,
        .labels = &.{
            "core",
            "storage",
        },
        .message = .{
            .title = "Initial commit",
            .body = "Create the initial repository structure.",
        },
    });

    var c = try read(
        alloc,
        &store,
        commit_hash,
    );
    defer c.deinit(alloc);

    try std.testing.expectEqualSlices(
        u8,
        &tree_hash,
        &c.tree_hash,
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        c.parents.len,
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
        c.timestamp_ms,
    );

    try std.testing.expectEqual(
        Intent.feature,
        c.intent,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        c.labels.len,
    );

    try std.testing.expectEqualStrings(
        "core",
        c.labels[0],
    );

    try std.testing.expectEqualStrings(
        "storage",
        c.labels[1],
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
        .tree_hash = tree_hash,
        .parents = &.{},
        .author = .{
            .name = "Alan Turing",
            .email = "alan@nodus.dev",
        },
        .timestamp_ms = 1_000,
        .intent = .feature,
        .labels = &.{},
        .message = .{
            .title = "root",
            .body = "",
        },
    });

    // Child commit
    const child_hash = try write(alloc, &store, .{
        .tree_hash = tree_hash,
        .parents = &.{parent_hash},
        .author = .{
            .name = "Alan Turing",
            .email = "alan@nodus.dev",
        },
        .timestamp_ms = 2_000,
        .intent = .feature,
        .labels = &.{},
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
        c.parents.len,
    );

    try std.testing.expectEqualSlices(
        u8,
        &parent_hash,
        &c.parents[0],
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

    const h1 = try write(alloc, &store, .{ .tree_hash = tree_hash, .parents = &.{}, .author = .{
        .name = "Test User",
        .email = "test@nodus.dev",
    }, .timestamp_ms = 42, .intent = .feature, .labels = &.{
        "core",
        "storage",
    }, .message = .{
        .title = "msg",
        .body = "deterministic commit",
    } });

    const h2 = try write(alloc, &store, .{
        .tree_hash = tree_hash,
        .parents = &.{},
        .author = .{
            .name = "Test User",
            .email = "test@nodus.dev",
        },
        .timestamp_ms = 42,
        .intent = .feature,
        .labels = &.{
            "core",
            "storage",
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

    const result = try resolveHead(alloc, tmp.dir);
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
        .tree_hash = tree_hash,
        .parents = &.{},
        .author = .{
            .name = "dev",
            .email = "dev@nodus.local",
        },
        .timestamp_ms = 1,
        .intent = .chore,
        .labels = &.{},
        .message = .{
            .title = "init",
            .body = "",
        },
    });

    try writeHeadRef(tmp.dir, "main");
    try updateRef(alloc, tmp.dir, "main", commit_hash);

    const resolved = try resolveHead(
        alloc,
        tmp.dir,
    );

    try std.testing.expect(resolved != null);

    try std.testing.expectEqualSlices(
        u8,
        &commit_hash,
        &resolved.?,
    );

    const branch = try headBranch(
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
            .tree_hash = undefined, // overwritten internally

            .parents = &.{},

            .author = .{
                .name = "Test Author",
                .email = "test@nodus.dev",
            },

            .timestamp_ms = 0,

            .intent = .feature,

            .labels = &.{
                "core",
                "storage",
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
        c.parents.len,
    );

    const tree_obj = try store.get(
        c.tree_hash,
    );
    defer alloc.free(tree_obj.payload);

    try std.testing.expectEqual(
        object.ObjectType.tree,
        tree_obj.obj_type,
    );
}
