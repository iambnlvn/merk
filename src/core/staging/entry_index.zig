const std = @import("std");
const merkle_mod = @import("merkle");
const crypto = @import("crypto");
const Entry = merkle_mod.Entry;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing = std.testing;

/// Ceiling on how many entries a single `EntryIndex` can hold. Chosen
/// to match `path_index`'s value type (see below), not an inherent
/// limit of anything else here.
pub const max_entries: usize = std.math.maxInt(u32);

/// A sorted, path-indexed collection of `Entry` values — the pure
/// in-memory half of what `Staging` used to do on its own. Knows
/// nothing about disk, `Vfs`, or Merkle pages; it only keeps `entries`
/// sorted by path and `path_index` in sync with it.
pub const EntryIndex = struct {
    alloc: Allocator,
    entries: ArrayList(Entry) = .empty,
    /// Path -> position in `entries`. Values are `u32` rather than
    /// `usize`: halves this map's per-entry footprint on 64-bit
    /// targets, and `max_entries` keeps that narrowing always valid.
    path_index: std.StringHashMapUnmanaged(u32) = .empty,

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

    /// Whether `path` is currently staged. Trivial wrapper over
    /// `lookup`, but every current caller that wants a yes/no answer
    /// does `lookup(...) != null` itself -- worth having once.
    pub fn contains(self: *const EntryIndex, path: []const u8) bool {
        return self.path_index.contains(path);
    }

    /// The contiguous run of entries whose path begins with `prefix`,
    /// found in O(log n + k) via a binary search for the run's start
    /// followed by a linear scan to its end, instead of an O(n) filter
    /// over the whole list.
    ///
    /// REQUIRES `entries` to already be path-sorted -- true immediately
    /// after `load()`, `save()`, `replaceAll()`, or `sortAndReindex()`,
    /// but NOT guaranteed at every point in time (see the same caveat
    /// on `Staging.allEntries()`). Calling this against an unsorted
    /// list silently returns a wrong (too-small, too-large, or
    /// discontiguous-in-truth) slice rather than an error -- callers
    /// that can't guarantee a prior sort should call `sortAndReindex()`
    /// themselves first.
    pub fn entriesUnder(self: *const EntryIndex, prefix: []const u8) []const Entry {
        const entries = self.entries.items;
        if (prefix.len == 0) return entries;

        const start = lowerBoundByPrefix(entries, prefix);
        var end = start;
        while (end < entries.len and std.mem.startsWith(u8, entries[end].path, prefix)) : (end += 1) {}
        return entries[start..end];
    }

    /// Reserve capacity for at least `additional` more entries in both
    /// the entry list and the path index, so a caller adding many
    /// entries in a row (bulk add, loading from disk) pays for one
    /// growth instead of several geometric reallocations.
    pub fn reserve(self: *EntryIndex, additional: usize) !void {
        try self.entries.ensureUnusedCapacity(self.alloc, additional);
        try self.path_index.ensureUnusedCapacity(self.alloc, @intCast(additional));
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

    /// Append `entry`, failing if its path is already present rather
    /// than silently replacing it (as `upsert` would). For callers
    /// that have already established this path must be new — e.g.
    /// deserializing untrusted bytes, where a repeat path means the
    /// data is corrupt, not that it should overwrite.
    pub fn appendUnique(self: *EntryIndex, entry: Entry) !void {
        errdefer {
            var owned = entry;
            owned.deinit(self.alloc);
        }
        if (self.path_index.contains(entry.path)) return error.DuplicatePath;
        try self.appendOne(entry);
    }

    /// Remove the entry at `path`. Returns `error.NotFound` if absent.
    ///
    /// `orderedRemove` shifts every entry after `i` down by one to keep
    /// `entries` sorted — unavoidably O(n) for a mid-list removal. But
    /// unlike a full `reindex()`, this only updates the shifted
    /// entries' *positions* in `path_index`, never re-hashing their
    /// path strings — rehashing is the expensive part for long paths;
    /// updating a position is a plain integer write.
    pub fn remove(self: *EntryIndex, path: []const u8) !void {
        const i = self.path_index.get(path) orelse return error.NotFound;
        var removed = self.entries.orderedRemove(i);
        _ = self.path_index.remove(path);
        removed.deinit(self.alloc);

        for (self.entries.items[i..], i..) |entry, new_pos| {
            self.path_index.getPtr(entry.path).?.* = @intCast(new_pos);
        }
    }

    /// Discard all current entries and replace with `entries`, which
    /// this index takes ownership of (each `Entry.path` will be freed
    /// by a later `clear`/`deinit`/`remove`/`upsert` that replaces it).
    /// Callers must not free `entries[i].path` themselves afterward,
    /// and must not reuse the backing slice.
    ///
    /// Does not check for duplicate paths among `entries` — callers
    /// that can't already guarantee uniqueness (e.g. deserializing
    /// untrusted bytes) should validate before calling this; use
    /// `appendUnique` per-entry in that case instead.
    pub fn replaceAll(self: *EntryIndex, entries: []const Entry) !void {
        if (entries.len > max_entries) return error.TooManyEntries;
        self.clear();
        try self.entries.ensureTotalCapacityPrecise(self.alloc, entries.len);
        self.entries.appendSliceAssumeCapacity(entries);
        try self.sortAndReindex();
    }

    /// Re-sort `entries` by path and rebuild `path_index` to match.
    /// Call after any bulk mutation that bypassed `upsert`/`remove`.
    pub fn sortAndReindex(self: *EntryIndex) !void {
        std.mem.sort(Entry, self.entries.items, {}, merkle_mod.pathLessThan);
        try self.reindex();
    }

    fn reindex(self: *EntryIndex) !void {
        self.path_index.clearRetainingCapacity();
        try self.path_index.ensureTotalCapacity(self.alloc, @intCast(self.entries.items.len));
        for (self.entries.items, 0..) |entry, i| {
            self.path_index.putAssumeCapacity(entry.path, @intCast(i));
        }
    }

    fn replaceAt(self: *EntryIndex, i: usize, new_entry: Entry) !void {
        try self.path_index.ensureUnusedCapacity(self.alloc, 1);
        const existing = &self.entries.items[i];
        _ = self.path_index.remove(existing.path);
        existing.deinit(self.alloc);
        existing.* = new_entry;
        self.path_index.putAssumeCapacity(existing.path, @intCast(i));
    }

    fn appendOne(self: *EntryIndex, new_entry: Entry) !void {
        if (self.entries.items.len >= max_entries) return error.TooManyEntries;
        try self.path_index.ensureUnusedCapacity(self.alloc, 1);
        try self.entries.append(self.alloc, new_entry);
        const i = self.entries.items.len - 1;
        self.path_index.putAssumeCapacity(self.entries.items[i].path, @intCast(i));
    }
};

/// First index in a path-sorted `entries` slice whose path is `>=
/// prefix` in the same byte-lexicographic order `pathLessThan` sorts
/// by. A plain hand-rolled binary search rather than `std.sort` helpers
/// since the comparison here is asymmetric (`Entry` vs. a raw prefix
/// slice, not `Entry` vs. `Entry`).
fn lowerBoundByPrefix(entries: []const Entry, prefix: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pathBeforePrefix(entries[mid].path, prefix)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// True if `path` sorts strictly before `prefix` itself (treating
/// `prefix` as a path of its own for comparison purposes).
fn pathBeforePrefix(path: []const u8, prefix: []const u8) bool {
    const min_len = @min(path.len, prefix.len);
    return switch (std.mem.order(u8, path[0..min_len], prefix[0..min_len])) {
        .lt => true,
        .gt => false,
        .eq => path.len < prefix.len,
    };
}

fn testEntry(alloc: Allocator, path: []const u8, seed: u8) !Entry {
    return .{
        .path = try alloc.dupe(u8, path),
        .blob_hash = crypto.blake3(&.{seed}),
        .size = seed,
        .mode = 0o100644,
        .mtime = seed,
    };
}

test "empty index: count, allEntries, lookup all report empty" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 0), idx.count());
    try testing.expectEqual(@as(usize, 0), idx.allEntries().len);
    try testing.expect(idx.lookup("anything") == null);
}

test "upsert appends new entries and keeps them findable" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "b.txt", 2));
    try idx.upsert(try testEntry(alloc, "a.txt", 1));

    try testing.expectEqual(@as(usize, 2), idx.count());
    try testing.expect(idx.lookup("a.txt") != null);
    try testing.expect(idx.lookup("b.txt") != null);
    try testing.expect(idx.lookup("c.txt") == null);
}

test "upsert on an existing path replaces it without growing count" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "a.txt", 1));
    try idx.upsert(try testEntry(alloc, "a.txt", 99));

    try testing.expectEqual(@as(usize, 1), idx.count());
    const e = idx.lookup("a.txt").?;
    try testing.expectEqual(@as(u64, 99), e.size);
}

test "appendUnique rejects a path that's already present" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.appendUnique(try testEntry(alloc, "a.txt", 1));
    // appendUnique frees the entry (including its duped path) on
    // failure -- if it didn't, testing.allocator would flag a leak.
    try testing.expectError(error.DuplicatePath, idx.appendUnique(try testEntry(alloc, "a.txt", 2)));
    try testing.expectEqual(@as(usize, 1), idx.count());
}

test "remove drops the entry and reports NotFound on a second attempt" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "a.txt", 1));
    try idx.remove("a.txt");

    try testing.expectEqual(@as(usize, 0), idx.count());
    try testing.expectError(error.NotFound, idx.remove("a.txt"));
}

test "remove from the middle keeps every other entry findable (position bookkeeping is correct)" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    // Insert already in sorted order so remove's shift-and-reindex is
    // exercised against a realistic layout.
    try idx.upsert(try testEntry(alloc, "a.txt", 1));
    try idx.upsert(try testEntry(alloc, "b.txt", 2));
    try idx.upsert(try testEntry(alloc, "c.txt", 3));
    try idx.upsert(try testEntry(alloc, "d.txt", 4));
    try idx.sortAndReindex();

    try idx.remove("b.txt"); // middle removal shifts c.txt and d.txt down

    try testing.expectEqual(@as(usize, 3), idx.count());
    try testing.expect(idx.lookup("b.txt") == null);

    // Every remaining entry must resolve to the right content, not
    // just "be present" -- this is what would break if positions
    // weren't updated after the shift.
    try testing.expectEqual(@as(u64, 1), idx.lookup("a.txt").?.size);
    try testing.expectEqual(@as(u64, 3), idx.lookup("c.txt").?.size);
    try testing.expectEqual(@as(u64, 4), idx.lookup("d.txt").?.size);
}

test "remove the last element needs no shifting and still stays consistent" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "a.txt", 1));
    try idx.upsert(try testEntry(alloc, "b.txt", 2));
    try idx.sortAndReindex();

    try idx.remove("b.txt");
    try testing.expectEqual(@as(usize, 1), idx.count());
    try testing.expect(idx.lookup("a.txt") != null);
}

test "sortAndReindex orders entries by path regardless of insertion order" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "z.txt", 1));
    try idx.upsert(try testEntry(alloc, "a.txt", 2));
    try idx.upsert(try testEntry(alloc, "m.txt", 3));
    try idx.sortAndReindex();

    const entries = idx.allEntries();
    try testing.expectEqualStrings("a.txt", entries[0].path);
    try testing.expectEqualStrings("m.txt", entries[1].path);
    try testing.expectEqualStrings("z.txt", entries[2].path);
}

test "reserve avoids growth without changing observable behavior" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.reserve(50);
    try testing.expect(idx.entries.capacity >= 50);

    var i: u8 = 0;
    while (i < 50) : (i += 1) {
        var buf: [16]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "f{d}.txt", .{i});
        try idx.upsert(try testEntry(alloc, path, i));
    }
    try testing.expectEqual(@as(usize, 50), idx.count());
}

test "replaceAll discards prior entries and takes ownership of new ones" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "old.txt", 1));

    var replacement: ArrayList(Entry) = .empty;
    try replacement.append(alloc, try testEntry(alloc, "new.txt", 2));
    try idx.replaceAll(replacement.items);
    replacement.deinit(alloc); // ownership of .path moved into idx

    try testing.expectEqual(@as(usize, 1), idx.count());
    try testing.expect(idx.lookup("old.txt") == null);
    try testing.expect(idx.lookup("new.txt") != null);
}

test "replaceAll with an empty slice clears the index" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "a.txt", 1));
    try idx.replaceAll(&.{});
    try testing.expectEqual(@as(usize, 0), idx.count());
}

test "clear frees every entry and leaves the index reusable" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "a.txt", 1));
    try idx.upsert(try testEntry(alloc, "b.txt", 2));
    idx.clear();

    try testing.expectEqual(@as(usize, 0), idx.count());
    try testing.expect(idx.lookup("a.txt") == null);

    // Index must still work normally after clear(), not just be empty.
    try idx.upsert(try testEntry(alloc, "c.txt", 3));
    try testing.expectEqual(@as(usize, 1), idx.count());
}

test "contains reports presence without needing the caller to unwrap lookup" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "a.txt", 1));

    try testing.expect(idx.contains("a.txt"));
    try testing.expect(!idx.contains("b.txt"));

    try idx.remove("a.txt");
    try testing.expect(!idx.contains("a.txt"));
}

test "entriesUnder returns only the contiguous run matching a directory prefix" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();

    try idx.upsert(try testEntry(alloc, "README.md", 1));
    try idx.upsert(try testEntry(alloc, "src/a.zig", 2));
    try idx.upsert(try testEntry(alloc, "src/b.zig", 3));
    try idx.upsert(try testEntry(alloc, "src/sub/c.zig", 4));
    try idx.upsert(try testEntry(alloc, "srcx/d.zig", 5));
    try idx.upsert(try testEntry(alloc, "zzz.txt", 6));
    try idx.sortAndReindex();

    const under_src = idx.entriesUnder("src/");
    try testing.expectEqual(@as(usize, 3), under_src.len);
    for (under_src) |e| try testing.expect(std.mem.startsWith(u8, e.path, "src/"));

    // "srcx/d.zig" shares the "src" prefix but not the "src/" one --
    // must not leak into a directory-prefix query.
    try testing.expect(idx.lookup("srcx/d.zig") != null);
    for (under_src) |e| try testing.expect(!std.mem.eql(u8, e.path, "srcx/d.zig"));

    try testing.expectEqual(@as(usize, 0), idx.entriesUnder("missing/").len);
    try testing.expectEqual(idx.count(), idx.entriesUnder("").len);
}

test "many upserts and interleaved removals stay internally consistent" {
    const alloc = testing.allocator;
    var idx = EntryIndex.init(alloc);
    defer idx.deinit();
    try idx.reserve(200);

    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        var buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "src/file-{d:0>4}.zig", .{i});
        try idx.upsert(try testEntry(alloc, path, @intCast(i % 256)));
    }

    // Remove every third one, from the front, to stress repeated
    // shift-and-reindex behavior against a shrinking list.
    i = 0;
    while (i < 200) : (i += 3) {
        var buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "src/file-{d:0>4}.zig", .{i});
        try idx.remove(path);
    }

    try idx.sortAndReindex();

    // Spot-check survivors and casualties are exactly as expected.
    try testing.expect(idx.lookup("src/file-0000.zig") == null);
    try testing.expect(idx.lookup("src/file-0001.zig") != null);
    try testing.expect(idx.lookup("src/file-0199.zig") != null);

    const entries = idx.allEntries();
    var prev: []u8 = "";
    for (entries) |e| {
        try testing.expect(merkle_mod.pathLessThan({}, .{ .path = prev, .blob_hash = undefined, .size = 0, .mode = 0, .mtime = 0 }, e) or prev.len == 0);
        prev = e.path;
    }
}
