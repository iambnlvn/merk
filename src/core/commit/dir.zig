const std = @import("std");
const Allocator = std.mem.Allocator;

/// The single place that knows how to build a path for a repo
/// component's on-disk state relative to its `Vfs` root.
///
/// Every component (`Store`, `Staging`, `ReferenceStore`, ...) used to
/// reimplement the same "join repo_dir with a sub-path, or just use
/// the sub-path when repo_dir is empty" logic on its own (`subPath` in
/// `staging.zig`, mirrored again in `object_store.zig`). That
/// duplication is exactly what lets the convention drift — nothing
/// stops one copy from handling the empty-repo_dir case differently
/// from another. `ComponentDir` gives every component one shared
/// implementation instead, so "where does merk's state live under
/// `.merk`" has exactly one answer.
pub const ComponentDir = struct {
    /// Directory this component's state lives under, relative to its
    /// `Vfs` root. May be "" if the `Vfs` is already rooted there.
    repo_dir: []const u8,

    pub fn init(repo_dir: []const u8) ComponentDir {
        return .{ .repo_dir = repo_dir };
    }

    /// Join with `sub`, e.g. "staging/pages" -> "<repo_dir>/staging/pages".
    /// Caller owns and must free the result.
    pub fn join(self: ComponentDir, alloc: Allocator, sub: []const u8) ![]u8 {
        if (self.repo_dir.len == 0) return alloc.dupe(u8, sub);
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.repo_dir, sub });
    }

    /// Two-level hex sharding for hash-keyed on-disk stores: joins with
    /// "xx/yy/<hex>" so no single directory ever holds more than a
    /// couple hundred entries. Shared by loose objects (`Store`) and
    /// the structural-hash side index (`StructuralIndex`) — both used
    /// to carry their own copy of this exact split-the-hex logic.
    pub fn shardedPath(self: ComponentDir, alloc: Allocator, hex: []const u8) ![]u8 {
        const shard = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ hex[0..2], hex[2..4], hex });
        defer alloc.free(shard);
        return self.join(alloc, shard);
    }
};
