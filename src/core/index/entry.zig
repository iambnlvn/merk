const std = @import("std");
const hash_mod = @import("../hash.zig");
const format = @import("format.zig");

pub const Hash = hash_mod.Hash;
pub const PathKey = format.PathKey;

/// Represents a tracked file in the repository
/// NOTE:The `path` slice is owned by this struct and must be freed with `deinit`
pub const Entry = struct {
    path: []u8,
    blob_hash: Hash,
    size: u64,
    mode: u64,
    mtime: i128,

    pub fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};

/// Worktree status of an indexed entry relative to the filesystem
pub const WorktreeState = enum {
    clean,
    modified,
    deleted,
};

pub const ChangeKind = enum {
    added,
    removed,
    modified,
};

/// Describes a single change between two index states
/// The `path` slice is owned and must be freed with `EntryChange.deinit`
pub const EntryChange = struct {
    kind: ChangeKind,
    path: []u8,
    old_blob_hash: ?Hash = null,
    new_blob_hash: ?Hash = null,
    old_size: ?u64 = null,
    new_size: ?u64 = null,
    old_mode: ?u64 = null,
    new_mode: ?u64 = null,

    pub fn deinit(self: *EntryChange, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};

/// Release all memory associated with a slice of changes
pub fn freeChanges(alloc: std.mem.Allocator, changes: []EntryChange) void {
    for (changes) |*c| c.deinit(alloc);
    alloc.free(changes);
}

/// Compute the B-tree key for a given path
pub fn pathKey(path: []const u8) PathKey {
    return format.foldHashPrefix(hash_mod.blake3(path));
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPath;
    if (path.len > std.math.maxInt(u16)) return error.InvalidPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidPath;
    if (std.mem.eql(u8, path, ".nodus")) return error.InvalidPath;
    if (std.mem.startsWith(u8, path, ".nodus/")) return error.InvalidPath;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
}

/// Sort by repository-relative path (lexicographic)
pub fn pathLessThan(_: void, lhs: Entry, rhs: Entry) bool {
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

/// Sort by B-tree key (hash-derived), falling back to path for stability
pub fn btreeLessThan(_: void, lhs: Entry, rhs: Entry) bool {
    const lhs_key = pathKey(lhs.path);
    const rhs_key = pathKey(rhs.path);
    if (lhs_key == rhs_key) return std.mem.lessThan(u8, lhs.path, rhs.path);
    return lhs_key < rhs_key;
}

test "pathKey is deterministic big-endian prefix" {
    const h = hash_mod.blake3("src/main.zig");
    var expected: PathKey = 0;
    for (h[0..8]) |byte| expected = (expected << 8) | byte;
    try std.testing.expectEqual(expected, pathKey("src/main.zig"));
}
