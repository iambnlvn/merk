const std = @import("std");
const merkle_mod = @import("merkle");
const Entry = merkle_mod.Entry;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// A sorted, path-indexed collection of `Entry` values — the pure
/// in-memory half of what `Staging` used to do on its own. Knows
/// nothing about disk, `Vfs`, or Merkle pages; it only keeps `entries`
/// sorted by path and `path_index` in sync with it.
///
/// Lives alongside `staging.zig` under `staging/` rather than at the
/// package root because it's an implementation detail of `Staging` —
/// callers outside this package go through the top-level `staging.zig`
/// facade, which re-exports this type for the cases where composing
/// it directly (independent of persistence) is useful.
pub const EntryIndex = struct {
    alloc: Allocator,
    entries: ArrayList(Entry) = .empty,
    path_index: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn init(alloc: Allocator) EntryIndex {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *EntryIndex) void {
        self.clear();
        self.entries.deinit(self.alloc);
        self.path_index.deinit(self.alloc);
    }

    /// Frees every entry and empties the index. Does not touch any
    /// backing store — callers that persist elsewhere handle that
    /// separately.
    pub fn clear(self: *EntryIndex) void {
        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.clearRetainingCapacity();
        self.path_index.clearRetainingCapacity();
    }

    pub fn count(self: *const EntryIndex) usize {
        return self.entries.items.len;
    }

    /// Read-only view of every entry, in current sort order.
    pub fn allEntries(self: *const EntryIndex) []const Entry {
        return self.entries.items;
    }

    pub fn lookup(self: *const EntryIndex, path: []const u8) ?Entry {
        const i = self.path_index.get(path) orelse return null;
        return self.entries.items[i];
    }

    /// Insert `entry` or replace whatever's currently at the same
    /// path. Takes ownership of `entry` (and its `path`) on success;
    /// frees it on failure.
    pub fn upsert(self: *EntryIndex, entry: Entry) !void {
        errdefer {
            var owned = entry;
            owned.deinit(self.alloc);
        }
        if (self.path_index.get(entry.path)) |i| {
            try self.replaceAt(i, entry);
        } else {
            try self.appendOne(entry);
        }
    }

    /// Remove the entry at `path`. Returns `error.NotFound` if absent.
    pub fn remove(self: *EntryIndex, path: []const u8) !void {
        const i = self.path_index.get(path) orelse return error.NotFound;
        var removed = self.entries.orderedRemove(i);
        removed.deinit(self.alloc);
        try self.reindex();
    }

    /// Re-sort `entries` by path and rebuild `path_index` to match.
    /// Call after any bulk mutation that bypassed `upsert`/`remove`
    /// (e.g. after `merkle_mod.collect` populates `entries` directly
    /// from a page store).
    pub fn sortAndReindex(self: *EntryIndex) !void {
        std.mem.sort(Entry, self.entries.items, {}, merkle_mod.pathLessThan);
        try self.reindex();
    }

    fn reindex(self: *EntryIndex) !void {
        self.path_index.clearRetainingCapacity();
        try self.path_index.ensureTotalCapacity(self.alloc, @intCast(self.entries.items.len));
        for (self.entries.items, 0..) |entry, i| {
            self.path_index.putAssumeCapacity(entry.path, i);
        }
    }

    fn replaceAt(self: *EntryIndex, i: usize, new_entry: Entry) !void {
        try self.path_index.ensureUnusedCapacity(self.alloc, 1);
        const existing = &self.entries.items[i];
        _ = self.path_index.remove(existing.path);
        existing.deinit(self.alloc);
        existing.* = new_entry;
        self.path_index.putAssumeCapacity(existing.path, i);
    }

    fn appendOne(self: *EntryIndex, new_entry: Entry) !void {
        try self.path_index.ensureUnusedCapacity(self.alloc, 1);
        try self.entries.append(self.alloc, new_entry);
        const i = self.entries.items.len - 1;
        self.path_index.putAssumeCapacity(self.entries.items[i].path, i);
    }
};
