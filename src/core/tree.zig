const std = @import("std");
const hash_mod = @import("hash.zig");
const index_mod = @import("index.zig");
const object = @import("object.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

//
// Mirrors writeNode's wire format exactly (see writeTreeEntry below):
//   [4]  child_count (u32 little-endian)
//   per child:
//     [1]   kind        (EntryKind)
//     [2]   name_len    (u16 little-endian)
//     [n]   name bytes
//     [32]  hash
//     [8]   mode        (u64 little-endian)
//     [8]   size        (u64 little-endian)

pub const FlatEntry = struct {
    path: []u8,
    hash: Hash,
    mode: u64,
    size: u64,
};

/// Recursively read the tree at `root_hash` and flatten it into a sorted,
/// caller-owned slice of (path, blob_hash) entries, file entries only,
/// directories are walked but not themselves emitted. Paths use `/`
/// separators regardless of platform, matching index_mod.Entry.path.
pub fn readToFlatEntries(
    alloc: std.mem.Allocator,
    store: *const Store,
    root_hash: Hash,
) ![]FlatEntry {
    var out: std.ArrayList(FlatEntry) = .empty;
    errdefer {
        for (out.items) |e| alloc.free(e.path);
        out.deinit(alloc);
    }

    try walkTree(alloc, store, root_hash, "", &out);

    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(FlatEntry, slice, {}, struct {
        fn lt(_: void, a: FlatEntry, b: FlatEntry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return slice;
}

pub fn freeFlatEntries(alloc: std.mem.Allocator, entries: []FlatEntry) void {
    for (entries) |e| alloc.free(e.path);
    alloc.free(entries);
}

fn walkTree(
    alloc: std.mem.Allocator,
    store: *const Store,
    tree_hash: Hash,
    prefix: []const u8,
    out: *std.ArrayList(FlatEntry),
) !void {
    const obj = try store.get(tree_hash);
    defer alloc.free(obj.payload);
    if (obj.obj_type != .tree) return error.NotATree;

    var reader = std.Io.Reader.fixed(obj.payload);
    const child_count = try reader.takeInt(u32, .little);

    for (0..child_count) |_| {
        const kind_byte = try reader.takeByte();
        const kind: EntryKind = @enumFromInt(kind_byte);

        const name_len = try reader.takeInt(u16, .little);
        const name = try reader.take(name_len);

        var hash: Hash = undefined;
        @memcpy(&hash, try reader.take(hash.len));

        const mode = try reader.takeInt(u64, .little);
        const size = try reader.takeInt(u64, .little);

        const child_path = if (prefix.len == 0)
            try alloc.dupe(u8, name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, name });

        switch (kind) {
            .blob => {
                try out.append(alloc, .{
                    .path = child_path,
                    .hash = hash,
                    .mode = mode,
                    .size = size,
                });
            },
            .tree => {
                defer alloc.free(child_path);
                try walkTree(alloc, store, hash, child_path, out);
            },
        }
    }
}

pub const EntryKind = enum(u8) {
    blob = 1,
    tree = 2,
};

const FileChild = struct {
    name: []u8,
    hash: Hash,
    size: u64,
    mode: u64,
};

const DirChild = struct {
    name: []u8,
    node: *Node,
};

const TreeChild = struct {
    kind: EntryKind,
    name: []const u8,
    hash: Hash,
    mode: u64,
    size: u64,
};

const Node = struct {
    files: std.ArrayList(FileChild) = .empty,
    dirs: std.ArrayList(DirChild) = .empty,

    fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        for (self.files.items) |file| alloc.free(file.name);
        self.files.deinit(alloc);

        for (self.dirs.items) |dir| {
            alloc.free(dir.name);
            dir.node.deinit(alloc);
            alloc.destroy(dir.node);
        }
        self.dirs.deinit(alloc);
    }
};

pub fn writeFromIndex(
    alloc: std.mem.Allocator,
    store: *const Store,
    entries: []const index_mod.Entry,
) !Hash {
    var root: Node = .{};
    defer root.deinit(alloc);

    for (entries) |entry| {
        try insertEntry(alloc, &root, entry);
    }

    return writeNode(alloc, store, &root);
}

fn insertEntry(alloc: std.mem.Allocator, root: *Node, entry: index_mod.Entry) !void {
    var node = root;
    var parts = std.mem.splitScalar(u8, entry.path, '/');

    while (parts.next()) |raw_part| {
        if (raw_part.len == 0 or std.mem.eql(u8, raw_part, ".")) continue;
        if (std.mem.eql(u8, raw_part, "..")) return error.InvalidPath;

        const is_last = !hasMoreRealParts(parts.rest());
        if (is_last) {
            try addFile(alloc, node, raw_part, entry);
            return;
        }

        node = try getOrCreateDir(alloc, node, raw_part);
    }

    return error.InvalidPath;
}

fn hasMoreRealParts(rest: []const u8) bool {
    var parts = std.mem.splitScalar(u8, rest, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        return true;
    }
    return false;
}

fn addFile(alloc: std.mem.Allocator, node: *Node, name: []const u8, entry: index_mod.Entry) !void {
    if (findDir(node, name) != null) return error.DuplicateTreeEntry;

    for (node.files.items) |*file| {
        if (std.mem.eql(u8, file.name, name)) {
            file.hash = entry.blob_hash;
            file.size = entry.size;
            file.mode = entry.mode;
            return;
        }
    }

    try node.files.append(alloc, .{
        .name = try alloc.dupe(u8, name),
        .hash = entry.blob_hash,
        .size = entry.size,
        .mode = entry.mode,
    });
}

fn getOrCreateDir(alloc: std.mem.Allocator, node: *Node, name: []const u8) !*Node {
    if (findFile(node, name) != null) return error.DuplicateTreeEntry;

    if (findDir(node, name)) |dir| return dir.node;

    const child = try alloc.create(Node);
    errdefer alloc.destroy(child);
    child.* = .{};

    try node.dirs.append(alloc, .{
        .name = try alloc.dupe(u8, name),
        .node = child,
    });

    return child;
}

fn findFile(node: *const Node, name: []const u8) ?*const FileChild {
    for (node.files.items) |*file| {
        if (std.mem.eql(u8, file.name, name)) return file;
    }
    return null;
}

fn findDir(node: *const Node, name: []const u8) ?*const DirChild {
    for (node.dirs.items) |*dir| {
        if (std.mem.eql(u8, dir.name, name)) return dir;
    }
    return null;
}

fn writeNode(alloc: std.mem.Allocator, store: *const Store, node: *Node) !Hash {
    std.mem.sort(FileChild, node.files.items, {}, fileLessThan);
    std.mem.sort(DirChild, node.dirs.items, {}, dirLessThan);

    var children: std.ArrayList(TreeChild) = .empty;
    defer children.deinit(alloc);

    try children.ensureTotalCapacity(alloc, node.files.items.len + node.dirs.items.len);

    for (node.dirs.items) |dir| {
        const child_hash = try writeNode(alloc, store, dir.node);
        children.appendAssumeCapacity(.{
            .kind = .tree,
            .name = dir.name,
            .hash = child_hash,
            .mode = 0,
            .size = 0,
        });
    }

    for (node.files.items) |file| {
        children.appendAssumeCapacity(.{
            .kind = .blob,
            .name = file.name,
            .hash = file.hash,
            .mode = file.mode,
            .size = file.size,
        });
    }

    std.mem.sort(TreeChild, children.items, {}, treeChildLessThan);

    var encoded = std.io.Writer.Allocating.init(alloc);
    defer encoded.deinit();

    const writer = &encoded.writer;
    try writer.writeInt(u32, @intCast(children.items.len), .little);

    for (children.items) |child| {
        try writeTreeEntry(writer, child.kind, child.name, child.hash, child.mode, child.size);
    }

    return store.put(.tree, encoded.written());
}

fn writeTreeEntry(
    writer: anytype,
    kind: EntryKind,
    name: []const u8,
    hash: Hash,
    mode: u64,
    size: u64,
) !void {
    try writer.writeByte(@intFromEnum(kind));
    try writer.writeInt(u16, @intCast(name.len), .little);
    try writer.writeAll(name);
    try writer.writeAll(&hash);
    try writer.writeInt(u64, mode, .little);
    try writer.writeInt(u64, size, .little);
}

fn fileLessThan(_: void, lhs: FileChild, rhs: FileChild) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn dirLessThan(_: void, lhs: DirChild, rhs: DirChild) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn treeChildLessThan(_: void, lhs: TreeChild, rhs: TreeChild) bool {
    const order = std.mem.order(u8, lhs.name, rhs.name);
    return switch (order) {
        .lt => true,
        .gt => false,
        .eq => @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind),
    };
}

test "writeFromIndex stores recursive tree objects" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var objects_dir = try tmp_dir.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const main_hash = try store.put(.blob, "main");
    const lib_hash = try store.put(.blob, "lib");

    var entries: [2]index_mod.Entry = .{
        .{
            .path = try alloc.dupe(u8, "src/main.zig"),
            .blob_hash = main_hash,
            .size = 4,
            .mode = 0o100644,
            .mtime = 1,
        },
        .{
            .path = try alloc.dupe(u8, "./src/lib.zig"),
            .blob_hash = lib_hash,
            .size = 3,
            .mode = 0o100644,
            .mtime = 2,
        },
    };
    defer {
        alloc.free(entries[0].path);
        alloc.free(entries[1].path);
    }

    const root_hash = try writeFromIndex(alloc, &store, &entries);
    const root_obj = try store.get(root_hash);
    defer alloc.free(root_obj.payload);

    try std.testing.expectEqual(object.ObjectType.tree, root_obj.obj_type);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, root_obj.payload[0..4], .little));
}

test "writeFromIndex is deterministic regardless of index order" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var objects_dir = try tmp_dir.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const a_hash = try store.put(.blob, "a");
    const b_hash = try store.put(.blob, "b");

    var first: [2]index_mod.Entry = .{
        .{ .path = try alloc.dupe(u8, "b.txt"), .blob_hash = b_hash, .size = 1, .mode = 0o100644, .mtime = 1 },
        .{ .path = try alloc.dupe(u8, "a.txt"), .blob_hash = a_hash, .size = 1, .mode = 0o100644, .mtime = 1 },
    };
    var second: [2]index_mod.Entry = .{
        .{ .path = try alloc.dupe(u8, "a.txt"), .blob_hash = a_hash, .size = 1, .mode = 0o100644, .mtime = 1 },
        .{ .path = try alloc.dupe(u8, "b.txt"), .blob_hash = b_hash, .size = 1, .mode = 0o100644, .mtime = 1 },
    };
    defer {
        for (&first) |entry| alloc.free(entry.path);
        for (&second) |entry| alloc.free(entry.path);
    }

    const first_hash = try writeFromIndex(alloc, &store, &first);
    const second_hash = try writeFromIndex(alloc, &store, &second);
    try std.testing.expectEqualSlices(u8, &first_hash, &second_hash);
}

test "readToFlatEntries round-trips writeFromIndex" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var objects_dir = try tmp_dir.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const main_hash = try store.put(.blob, "main");
    const lib_hash = try store.put(.blob, "lib");

    var entries: [2]index_mod.Entry = .{
        .{ .path = try alloc.dupe(u8, "src/main.zig"), .blob_hash = main_hash, .size = 4, .mode = 0o100644, .mtime = 1 },
        .{ .path = try alloc.dupe(u8, "src/lib.zig"), .blob_hash = lib_hash, .size = 3, .mode = 0o100644, .mtime = 2 },
    };
    defer {
        alloc.free(entries[0].path);
        alloc.free(entries[1].path);
    }

    const root_hash = try writeFromIndex(alloc, &store, &entries);

    const flat = try readToFlatEntries(alloc, &store, root_hash);
    defer freeFlatEntries(alloc, flat);

    try std.testing.expectEqual(@as(usize, 2), flat.len);
    // Sorted by path: "src/lib.zig" < "src/main.zig"
    try std.testing.expectEqualStrings("src/lib.zig", flat[0].path);
    try std.testing.expectEqualSlices(u8, &lib_hash, &flat[0].hash);
    try std.testing.expectEqualStrings("src/main.zig", flat[1].path);
    try std.testing.expectEqualSlices(u8, &main_hash, &flat[1].hash);
}

test "writeFromIndex rejects duplicate file and directory collisions" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var objects_dir = try tmp_dir.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const blob_hash = try store.put(.blob, "content");

    var first: [2]index_mod.Entry = .{
        .{ .path = try alloc.dupe(u8, "src"), .blob_hash = blob_hash, .size = 7, .mode = 0o100644, .mtime = 1 },
        .{ .path = try alloc.dupe(u8, "src/main.zig"), .blob_hash = blob_hash, .size = 7, .mode = 0o100644, .mtime = 2 },
    };
    defer {
        alloc.free(first[0].path);
        alloc.free(first[1].path);
    }

    try std.testing.expectError(error.DuplicateTreeEntry, writeFromIndex(alloc, &store, &first));
}

test "writeFromIndex rejects invalid index paths" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var objects_dir = try tmp_dir.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    var entries: [1]index_mod.Entry = .{
        .{ .path = try alloc.dupe(u8, "src/../main.zig"), .blob_hash = try store.put(.blob, "x"), .size = 1, .mode = 0o100644, .mtime = 1 },
    };
    defer alloc.free(entries[0].path);

    try std.testing.expectError(error.InvalidPath, writeFromIndex(alloc, &store, &entries));
}

test "readToFlatEntries rejects non-tree objects" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var objects_dir = try tmp_dir.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const blob_hash = try store.put(.blob, "hello world");
    try std.testing.expectError(error.NotATree, readToFlatEntries(alloc, &store, blob_hash));
}

test "writeFromIndex updates duplicate index entries to latest metadata" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var objects_dir = try tmp_dir.dir.makeOpenPath("objects", .{});
    defer objects_dir.close();
    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const first_hash = try store.put(.blob, "first");
    const second_hash = try store.put(.blob, "second");

    var entries: [2]index_mod.Entry = .{
        .{ .path = try alloc.dupe(u8, "a.txt"), .blob_hash = first_hash, .size = 5, .mode = 0o100644, .mtime = 1 },
        .{ .path = try alloc.dupe(u8, "a.txt"), .blob_hash = second_hash, .size = 6, .mode = 0o100755, .mtime = 2 },
    };
    defer {
        alloc.free(entries[0].path);
        alloc.free(entries[1].path);
    }

    const root_hash = try writeFromIndex(alloc, &store, &entries);
    const flat = try readToFlatEntries(alloc, &store, root_hash);
    defer freeFlatEntries(alloc, flat);

    try std.testing.expectEqual(@as(usize, 1), flat.len);
    try std.testing.expectEqualStrings("a.txt", flat[0].path);
    try std.testing.expectEqualSlices(u8, &second_hash, &flat[0].hash);
    try std.testing.expectEqual(@as(u64, 6), flat[0].size);
    try std.testing.expectEqual(@as(u64, 0o100755), flat[0].mode);
}
