const std = @import("std");
const hash_mod = @import("hash.zig");
const index_mod = @import("index.zig");
const object = @import("object.zig");

const Hash = hash_mod.Hash;
const Store = object.Store;

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
