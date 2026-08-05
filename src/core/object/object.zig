const std = @import("std");
const fs_mod = @import("merk").io;
const format = @import("./object_format.zig");
const hash_mod = @import("merk").crypto.hash;
const compression = @import("merk").compression;

pub const Hash = format.Hash;
pub const ObjectType = format.ObjectType;
pub const Object = format.Object;

const object_name_len = 2 + 1 + 2 + 1 + 64; // "xx/yy/<64 hex chars>"

pub const Store = struct {
    fs: fs_mod.vfs.Vfs,
    alloc: std.mem.Allocator,
    /// Directory objects live under, relative to `fs`'s root. May be ""
    /// if `fs` is already rooted at the objects directory itself
    objects_dir: []const u8,

    pub fn init(alloc: std.mem.Allocator, fs: fs_mod.vfs.Vfs, objects_dir: []const u8) Store {
        return .{ .fs = fs, .alloc = alloc, .objects_dir = objects_dir };
    }

    pub fn put(self: *const Store, obj_type: ObjectType, payload: []const u8) !Hash {
        return self.putWithStructuralHash(obj_type, payload, null);
    }

    pub fn putWithStructuralHash(
        self: *const Store,
        obj_type: ObjectType,
        payload: []const u8,
        structural_hash: ?Hash,
    ) !Hash {
        const codec = compression.choose(payload.len);
        const encoded = try format.encodeAlloc(self.alloc, obj_type, payload, codec, structural_hash);
        defer self.alloc.free(encoded.bytes);

        const path = try self.objectPath(encoded.hash);
        defer self.alloc.free(path);

        if (!try self.fs.fileExists(path)) {
            try self.fs.writeFile(self.alloc, path, encoded.bytes);
        }

        if (structural_hash) |sh| {
            try self.addToStructuralIndex(sh, encoded.hash);
        }

        return encoded.hash;
    }

    pub fn putReader(self: *const Store, obj_type: ObjectType, size_hint: u64, reader: anytype) !Hash {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        try buf.ensureTotalCapacity(self.alloc, std.math.cast(usize, size_hint) orelse 0);

        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try reader.read(&chunk);
            if (n == 0) break;
            try buf.appendSlice(self.alloc, chunk[0..n]);
        }

        return self.put(obj_type, buf.items);
    }

    pub fn get(self: *const Store, obj_hash: Hash) !Object {
        const path = try self.objectPath(obj_hash);
        defer self.alloc.free(path);

        const bytes = (try self.fs.readFile(self.alloc, path)) orelse return error.NotFound;
        defer self.alloc.free(bytes);

        return format.decodeFromBuffer(self.alloc, bytes);
    }

    /// Read just the structural hash of an object, without decompressing
    /// or materializing its payload. Returns null if the object has none.
    pub fn getStructuralHash(self: *const Store, obj_hash: Hash) !?Hash {
        const path = try self.objectPath(obj_hash);
        defer self.alloc.free(path);

        const header_buf = (try self.fs.readRange(self.alloc, path, 0, format.header_len)) orelse return error.NotFound;
        defer self.alloc.free(header_buf);
        const header = try format.decodeHeaderFromBuffer(header_buf);

        if (!header.has_structural_hash) return null;

        const offset = format.structuralHashOffset(header);
        const buf = (try self.fs.readRange(self.alloc, path, offset, format.structural_hash_len)) orelse return error.NotFound;
        defer self.alloc.free(buf);

        var h: Hash = undefined;
        @memcpy(&h, buf[0..format.structural_hash_len]);
        return h;
    }

    /// every object hash ever registered under this structural hash, backed
    /// by a small flat index file rather than a directory scan
    pub fn findByStructuralHash(self: *const Store, target: Hash) ![]Hash {
        const path = try self.structuralIndexPath(target);
        defer self.alloc.free(path);

        const bytes = (try self.fs.readFile(self.alloc, path)) orelse
            return try self.alloc.alloc(Hash, 0);
        defer self.alloc.free(bytes);

        const hlen = @sizeOf(Hash);
        const n = bytes.len / hlen;
        const result = try self.alloc.alloc(Hash, n);
        errdefer self.alloc.free(result);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            @memcpy(&result[i], bytes[i * hlen ..][0..hlen]);
        }
        return result;
    }

    /// Read and parse only the fixed-size header, without pulling the
    /// potentially large object body into memory
    pub fn getHeader(self: *const Store, obj_hash: Hash) !format.ObjectHeader {
        const path = try self.objectPath(obj_hash);
        defer self.alloc.free(path);

        const buf = (try self.fs.readRange(self.alloc, path, 0, format.header_len)) orelse return error.NotFound;
        defer self.alloc.free(buf);

        return format.decodeHeaderFromBuffer(buf);
    }

    pub fn exists(self: *const Store, obj_hash: Hash) bool {
        const path = self.objectPath(obj_hash) catch return false;
        defer self.alloc.free(path);
        return self.fs.fileExists(path) catch false;
    }

    /// Remove an object from disk
    ///  !NOTE: tho objects are meant to be immutable but this might be
    /// useful for gc-style tools
    pub fn delete(self: *const Store, obj_hash: Hash) !void {
        if (self.getStructuralHash(obj_hash) catch null) |sh| {
            self.removeFromStructuralIndex(sh, obj_hash) catch {};
        }

        const path = try self.objectPath(obj_hash);
        defer self.alloc.free(path);
        try self.fs.deleteFile(path);
    }

    /// Number of loose objects currently on disk
    pub fn count(self: *const Store) !usize {
        const names = try self.listObjectEntries();
        defer freeNames(self.alloc, names);
        return names.len;
    }

    /// Total on-disk size, in bytes, of all loose objects
    pub fn totalSize(self: *const Store) !u64 {
        const names = try self.listObjectEntries();
        defer freeNames(self.alloc, names);

        var total: u64 = 0;
        for (names) |name| {
            const full_path = try joinPath(self.alloc, self.objects_dir, name);
            defer self.alloc.free(full_path);

            if (try self.fs.statFile(full_path)) |stat| total += stat.size;
        }
        return total;
    }

    pub const CompressionStats = struct {
        objects: usize = 0,
        payload_bytes: u64 = 0,
        stored_bytes: u64 = 0,
    };

    /// Aggregate payload-vs-stored byte counts across every loose object,
    /// read straight from each object's header (`getHeader`, not a full
    /// decode) — the cheapest way to answer "is compression pulling its
    /// weight here" once `compression.choose` starts actually selecting
    /// something other than `.none`. Right now `stored_bytes` will
    /// equal `payload_bytes`, since encode-time compression is disabled
    /// (see `compression.Codec.zlib`'s doc comment) — this is measuring
    /// infrastructure that's ready for when that changes, not evidence
    /// compression is doing anything today.
    pub fn compressionStats(self: *const Store) !CompressionStats {
        const names = try self.listObjectEntries();
        defer freeNames(self.alloc, names);

        var stats = CompressionStats{};
        for (names) |name| {
            const hex = name[name.len - 64 ..];
            const obj_hash = hash_mod.fromHex(hex) catch continue;

            const header = self.getHeader(obj_hash) catch continue;
            stats.objects += 1;
            stats.payload_bytes += header.payload_len;
            stats.stored_bytes += header.stored_len;
        }
        return stats;
    }

    /// Sharded loose-object filenames directly under `objects_dir` —
    /// filtered to the "xx/yy/<64 hex>" shape `isObjectFileName` checks
    /// for, so `structural_index/...` entries and anything else living
    /// alongside the shards don't leak in. `count`, `totalSize`,
    /// `verifyAll`, and `compressionStats` all want exactly this list;
    /// one place to change the filter instead of four.
    fn listObjectEntries(self: *const Store) ![][]u8 {
        const names = try self.fs.listFiles(self.alloc, self.objects_dir);

        var kept: std.ArrayListUnmanaged([]u8) = .{};
        errdefer {
            for (kept.items) |n| self.alloc.free(n);
            kept.deinit(self.alloc);
        }

        var i: usize = 0;
        errdefer {
            // Anything not yet claimed by `kept` (or already freed as
            // non-object-shaped) still needs freeing on the error path —
            // `kept.append` below is the only thing here that can fail.
            for (names[i..]) |n| self.alloc.free(n);
            self.alloc.free(names);
        }

        while (i < names.len) : (i += 1) {
            const name = names[i];
            if (isObjectFileName(name)) {
                try kept.append(self.alloc, name);
            } else {
                self.alloc.free(name);
            }
        }
        self.alloc.free(names);

        return kept.toOwnedSlice(self.alloc);
    }

    /// Builds a "<base>/xx/yy/<hex>" path (or "xx/yy/<hex>" if `base` is
    /// empty) — the sharding scheme both loose objects (`objectPath`) and
    /// the structural-hash side index (`structuralIndexPath`) use, so a
    /// change to the shard width only has one place to happen.
    fn shardedPath(alloc: std.mem.Allocator, base: []const u8, hex: []const u8) ![]u8 {
        if (base.len == 0) {
            return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ hex[0..2], hex[2..4], hex });
        }
        return std.fmt.allocPrint(alloc, "{s}/{s}/{s}/{s}", .{ base, hex[0..2], hex[2..4], hex });
    }

    fn structuralIndexPath(self: *const Store, sh: Hash) ![]u8 {
        var hex_buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{sh}) catch unreachable;

        const base = try joinPath(self.alloc, self.objects_dir, "structural_index");
        defer self.alloc.free(base);

        return shardedPath(self.alloc, base, hex);
    }

    fn addToStructuralIndex(self: *const Store, sh: Hash, obj_hash: Hash) !void {
        const path = try self.structuralIndexPath(sh);
        defer self.alloc.free(path);

        const existing = try self.fs.readFile(self.alloc, path);
        defer if (existing) |e| self.alloc.free(e);

        if (existing) |bytes| {
            const hashes = std.mem.bytesAsSlice(Hash, bytes);
            for (hashes) |existing_hash| {
                if (std.mem.eql(u8, &existing_hash, &obj_hash)) return; // already registered
            }

            const new_bytes = try self.alloc.alloc(u8, bytes.len + @sizeOf(Hash));
            defer self.alloc.free(new_bytes);

            @memcpy(new_bytes[0..bytes.len], bytes);
            @memcpy(new_bytes[bytes.len..], &obj_hash);

            try self.fs.writeFile(self.alloc, path, new_bytes);
        } else {
            try self.fs.writeFile(self.alloc, path, &obj_hash);
        }
    }

    fn removeFromStructuralIndex(self: *const Store, sh: Hash, obj_hash: Hash) !void {
        const path = try self.structuralIndexPath(sh);
        defer self.alloc.free(path);

        const existing = (try self.fs.readFile(self.alloc, path)) orelse return;
        defer self.alloc.free(existing);

        const new_bytes = try self.alloc.alloc(u8, existing.len);
        defer self.alloc.free(new_bytes);

        const existing_hashes = std.mem.bytesAsSlice(Hash, existing);
        var out_hashes = std.mem.bytesAsSlice(Hash, new_bytes);
        var out_count: usize = 0;

        for (existing_hashes) |existing_hash| {
            if (!std.mem.eql(u8, &existing_hash, &obj_hash)) {
                out_hashes[out_count] = existing_hash;
                out_count += 1;
            }
        }

        if (out_count == 0) {
            try self.fs.deleteFile(path);
        } else {
            const out_bytes = std.mem.sliceAsBytes(out_hashes[0..out_count]);
            try self.fs.writeFile(self.alloc, path, out_bytes);
        }
    }

    pub const VerifyReport = struct {
        checked: usize = 0,
        corrupt: std.ArrayListUnmanaged(Hash) = .{},

        pub fn deinit(self: *VerifyReport, alloc: std.mem.Allocator) void {
            self.corrupt.deinit(alloc);
        }
    };

    /// Walk every loose object, fully decode it (decompress + verify its
    /// hash), and report which ones fail. no used as of now, but it will be a
    /// backing for an `fsck`-style integrity-check command
    pub fn verifyAll(self: *const Store) !VerifyReport {
        var report = VerifyReport{};
        errdefer report.deinit(self.alloc);

        const names = try self.listObjectEntries();
        defer freeNames(self.alloc, names);

        for (names) |name| {
            report.checked += 1;

            const hex = name[name.len - 64 ..];
            const obj_hash = hash_mod.fromHex(hex) catch {
                try report.corrupt.append(self.alloc, std.mem.zeroes(Hash));
                continue;
            };

            if (self.get(obj_hash)) |obj| {
                self.alloc.free(obj.payload);
            } else |err| {
                switch (err) {
                    error.CorruptObject, error.HashMismatch => try report.corrupt.append(self.alloc, obj_hash),
                    else => return err,
                }
            }
        }

        return report;
    }
    /// Resolve a hex prefix to the single object hash it identifies
    pub fn resolveHashPrefix(self: *const Store, prefix: []const u8) !Hash {
        try hash_mod.parseHexPrefix(prefix);

        const shard_dir = try joinPath(self.alloc, self.objects_dir, prefix[0..2]);
        defer self.alloc.free(shard_dir);

        const names = try self.fs.listFiles(self.alloc, shard_dir);
        defer freeNames(self.alloc, names);

        var found: ?Hash = null;
        for (names) |rel| {
            // NOTE: rel looks like "yy/<64 hex chars>" relative to shard_dir
            if (rel.len != 2 + 1 + 64 or rel[2] != '/') continue;

            const hex = rel[3..];
            if (!std.mem.startsWith(u8, hex, prefix)) continue;

            const h = hash_mod.fromHex(hex) catch continue;
            if (found != null) return error.Ambiguous;
            found = h;
        }

        return found orelse error.NotFound;
    }

    fn objectPath(self: *const Store, obj_hash: Hash) ![]u8 {
        var hex_buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{obj_hash}) catch unreachable;
        return shardedPath(self.alloc, self.objects_dir, hex);
    }
};

pub const ObjectReader = struct {
    alloc: std.mem.Allocator,
    obj_type: ObjectType,
    payload: []u8,
    pos: usize,

    pub fn init(store: *const Store, obj_hash: Hash) !ObjectReader {
        const obj = try store.get(obj_hash);
        return .{ .alloc = store.alloc, .obj_type = obj.obj_type, .payload = obj.payload, .pos = 0 };
    }

    pub fn deinit(self: *ObjectReader) void {
        self.alloc.free(self.payload);
    }

    pub fn read(self: *ObjectReader, buffer: []u8) usize {
        const rem = self.payload[self.pos..];
        const n = @min(buffer.len, rem.len);
        @memcpy(buffer[0..n], rem[0..n]);
        self.pos += n;
        return n;
    }

    pub fn remaining(self: *const ObjectReader) usize {
        return self.payload.len - self.pos;
    }

    /// Rewind back to the start of the payload for a second pass
    pub fn reset(self: *ObjectReader) void {
        self.pos = 0;
    }
};

fn joinPath(alloc: std.mem.Allocator, dir: []const u8, sub: []const u8) ![]u8 {
    if (dir.len == 0) return alloc.dupe(u8, sub);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, sub });
}

fn freeNames(alloc: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

fn isObjectFileName(name: []const u8) bool {
    if (name.len != object_name_len) return false;
    if (name[2] != '/' or name[5] != '/') return false;
    for (name[6..]) |c| {
        if (!isHexChar(c)) return false;
    }
    return true;
}

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

test "store put and get round-trip" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");

    const payload = "hello, object store!";
    const h = try store.put(.blob, payload);
    try std.testing.expect(store.exists(h));

    const obj = try store.get(h);
    defer alloc.free(obj.payload);

    try std.testing.expectEqual(ObjectType.blob, obj.obj_type);
    try std.testing.expectEqualStrings(payload, obj.payload);
}

test "store works with an empty objects_dir (fs already rooted there)" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "");
    const h = try store.put(.tree, "rooted at fs root");

    const obj = try store.get(h);
    defer alloc.free(obj.payload);
    try std.testing.expectEqualStrings("rooted at fs root", obj.payload);
}

test "store deduplication avoids a second write" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");

    const h1 = try store.put(.blob, "dedup test");
    try std.testing.expectEqual(@as(usize, 1), try store.count());

    const h2 = try store.put(.blob, "dedup test");
    try std.testing.expectEqualSlices(u8, &h1, &h2);
    try std.testing.expectEqual(@as(usize, 1), try store.count());
}

test "store getHeader matches the full decode without materializing the payload" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const payload = "intent-aware version control " ** 32;

    const h = try store.put(.commit, payload);
    const header = try store.getHeader(h);

    try std.testing.expectEqual(format.VERSION, header.version);
    try std.testing.expectEqual(ObjectType.commit, header.obj_type);
    try std.testing.expectEqual(@as(u32, payload.len), header.payload_len);

    const obj = try store.get(h);
    defer alloc.free(obj.payload);
    try std.testing.expectEqual(header.payload_len, @as(u32, @intCast(obj.payload.len)));
}

test "store getHeader on a missing object returns NotFound" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    var ghost: Hash = std.mem.zeroes(Hash);
    ghost[0] = 0xAB;

    try std.testing.expectError(error.NotFound, store.getHeader(ghost));
}

test "store delete removes the object" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const h = try store.put(.blob, "temporary");
    try std.testing.expect(store.exists(h));

    try store.delete(h);
    try std.testing.expect(!store.exists(h));
    try std.testing.expectError(error.NotFound, store.get(h));
}

test "store delete on a missing object surfaces the underlying error" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    var ghost: Hash = std.mem.zeroes(Hash);
    ghost[0] = 0xCD;

    try std.testing.expectError(error.FileNotFound, store.delete(ghost));
}

test "store count only counts well-formed object entries" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    _ = try store.put(.blob, "one");
    _ = try store.put(.tree, "two");
    _ = try store.put(.commit, "three");

    // Something that lives alongside the shard dirs but isn't itself a
    // valid "xx/yy/hash" entry should be ignored by count()
    try mem_fs.fs().writeFile(alloc, "objects/README", "not an object");

    try std.testing.expectEqual(@as(usize, 3), try store.count());
}

test "store totalSize sums the on-disk bytes of loose objects" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    _ = try store.put(.blob, "a");
    _ = try store.put(.blob, "bb");

    const total = try store.totalSize();
    try std.testing.expect(total > 0);
}

test "store compressionStats aggregates payload/stored bytes across objects, ignoring the structural index" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    _ = try store.put(.blob, "twelve bytes");
    const sh: Hash = [_]u8{0x11} ** 32;
    _ = try store.putWithStructuralHash(.ast, "fn f() void {}", sh);

    const stats = try store.compressionStats();
    try std.testing.expectEqual(@as(usize, 2), stats.objects);
    try std.testing.expectEqual(@as(u64, "twelve bytes".len + "fn f() void {}".len), stats.payload_bytes);
    //TODO!:
    // Compression is currently disabled (codec always .none), so stored
    // should exactly match payload — this test also doubles as a
    // tripwire: it'll start failing the moment `choose()` picks
    // something other than `.none`, which is the reminder to update it.
    try std.testing.expectEqual(stats.payload_bytes, stats.stored_bytes);
}

test "store verifyAll reports corruption without failing the whole scan" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const good1 = try store.put(.blob, "healthy object one");
    const good2 = try store.put(.blob, "healthy object two");
    const bad = try store.put(.blob, "about to be corrupted");

    // Tamper with `bad`'s bytes directly on disk, bypassing Store.put
    var hex_buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{bad}) catch unreachable;
    const path = try std.fmt.allocPrint(alloc, "objects/{s}/{s}/{s}", .{ hex[0..2], hex[2..4], hex });
    defer alloc.free(path);

    const original = (try mem_fs.fs().readFile(alloc, path)).?;
    defer alloc.free(original);
    const tampered = try alloc.dupe(u8, original);
    defer alloc.free(tampered);
    tampered[tampered.len - 1] ^= 0xFF;
    try mem_fs.fs().writeFile(alloc, path, tampered);

    var report = try store.verifyAll();
    defer report.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), report.checked);
    try std.testing.expectEqual(@as(usize, 1), report.corrupt.items.len);
    try std.testing.expectEqualSlices(u8, &bad, &report.corrupt.items[0]);

    // Sanity: the untouched objects are still fine
    const obj1 = try store.get(good1);
    defer alloc.free(obj1.payload);
    const obj2 = try store.get(good2);
    defer alloc.free(obj2.payload);
}

test "resolveHashPrefix finds a unique match by full hash" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const h = try store.put(.blob, "unique object");

    var hex_buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{h}) catch unreachable;

    const resolved = try store.resolveHashPrefix(hex);
    try std.testing.expectEqualSlices(u8, &h, &resolved);

    const short_prefix = try store.resolveHashPrefix(hex[0..32]);
    try std.testing.expectEqualSlices(u8, &h, &short_prefix);
}

test "resolveHashPrefix delegates minimum-length validation to hash_mod" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    _ = try store.put(.blob, "irrelevant");

    try std.testing.expectError(error.InvalidHexLength, store.resolveHashPrefix("a"));
}

test "resolveHashPrefix returns NotFound for a prefix nothing matches" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    _ = try store.put(.blob, "something");

    try std.testing.expectError(error.NotFound, store.resolveHashPrefix("f" ** 16));
}

test "resolveHashPrefix returns Ambiguous for a shared prefix" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");

    // Bypass Store.put entirely and fabricate two "objects" that share
    // a long common prefix but differ afterward — resolveHashPrefix only
    // inspects filenames, not object content, so dummy bytes are fine
    // here. The shared prefix is still rooted at shard "aa/bb" so both
    // land in the same directory resolveHashPrefix scans
    const shared_prefix = "aabbccddeeff0011";
    const hash_a = shared_prefix ++ "1" ** (64 - shared_prefix.len);
    const hash_b = shared_prefix ++ "2" ** (64 - shared_prefix.len);

    try mem_fs.fs().writeFile(alloc, "objects/aa/bb/" ++ hash_a, "dummy");
    try mem_fs.fs().writeFile(alloc, "objects/aa/bb/" ++ hash_b, "dummy");

    try std.testing.expectError(error.Ambiguous, store.resolveHashPrefix(shared_prefix));
}

test "ObjectReader streams a payload across many small reads" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const payload = "node graph semantic history " ** 48;
    const h = try store.put(.blob, payload);

    var reader = try ObjectReader.init(&store, h);
    defer reader.deinit();

    var out = try alloc.alloc(u8, payload.len);
    defer alloc.free(out);

    var offset: usize = 0;
    while (offset < out.len) {
        const n = reader.read(out[offset..@min(offset + 37, out.len)]);
        if (n == 0) break;
        offset += n;
    }

    try std.testing.expectEqual(payload.len, offset);
    try std.testing.expectEqualStrings(payload, out);
    try std.testing.expectEqual(@as(usize, 0), reader.remaining());
}

test "ObjectReader reset() allows a second full pass" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const h = try store.put(.blob, "read me twice");

    var reader = try ObjectReader.init(&store, h);
    defer reader.deinit();

    var first: [32]u8 = undefined;
    const n1 = reader.read(&first);
    try std.testing.expectEqual(@as(usize, 0), reader.remaining());

    reader.reset();
    var second: [32]u8 = undefined;
    const n2 = reader.read(&second);

    try std.testing.expectEqual(n1, n2);
    try std.testing.expectEqualSlices(u8, first[0..n1], second[0..n2]);
}

test "ObjectReader.init on a missing hash returns NotFound" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    var ghost: Hash = std.mem.zeroes(Hash);
    ghost[0] = 0xEF;

    try std.testing.expectError(error.NotFound, ObjectReader.init(&store, ghost));
}

test "findByStructuralHash finds every ast object sharing a structural hash" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");

    const shared_sh: Hash = [_]u8{0xAB} ** 32;
    const other_sh: Hash = [_]u8{0xCD} ** 32;

    // Two distinct `ast` payloads that normalize to the same structural
    // hash (e.g. same logic, different formatting/comments)
    const h1 = try store.putWithStructuralHash(.ast, "fn foo() void { return; }", shared_sh);
    const h2 = try store.putWithStructuralHash(.ast, "fn foo() void {\n    return;\n}", shared_sh);

    // An unrelated ast object with a different structural hash
    const h3 = try store.putWithStructuralHash(.ast, "fn bar() void {}", other_sh);

    // A plain blob with no structural hash at all — must never surface
    const h4 = try store.put(.blob, "not an ast object");

    const matches = try store.findByStructuralHash(shared_sh);
    defer alloc.free(matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);

    var found_h1 = false;
    var found_h2 = false;
    for (matches) |m| {
        if (std.mem.eql(u8, &m, &h1)) found_h1 = true;
        if (std.mem.eql(u8, &m, &h2)) found_h2 = true;
        // Sanity: neither the differently-hashed nor the plain blob leaked in
        try std.testing.expect(!std.mem.eql(u8, &m, &h3));
        try std.testing.expect(!std.mem.eql(u8, &m, &h4));
    }
    try std.testing.expect(found_h1);
    try std.testing.expect(found_h2);

    const no_matches = try store.findByStructuralHash(std.mem.zeroes(Hash));
    defer alloc.free(no_matches);
    try std.testing.expectEqual(@as(usize, 0), no_matches.len);
}

test "getStructuralHash returns null for objects encoded without one" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const h = try store.put(.blob, "no structural hash here");

    const sh = try store.getStructuralHash(h);
    try std.testing.expect(sh == null);
}

test "getStructuralHash round-trips without touching the payload" {
    const alloc = std.testing.allocator;
    var mem_fs = fs_mod.mem_fs.init(alloc);
    defer mem_fs.deinit();

    const store = Store.init(alloc, mem_fs.fs(), "objects");
    const sh: Hash = [_]u8{0x42} ** 32;
    const h = try store.putWithStructuralHash(.ast, "struct Foo { x: i32 }", sh);

    const got = try store.getStructuralHash(h);
    try std.testing.expect(got != null);
    try std.testing.expectEqualSlices(u8, &sh, &got.?);
}
