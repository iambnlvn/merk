//  Layout on disk:
//    <repo>/.nodus/objects/<xx>/<yy>/<full-hex-hash>
//
//  Where <xx> = first 2 hex chars, <yy> = next 2 hex chars
//  This sharding keeps directory sizes manageable
//
//  Every write is atomic: data is written to a temp file first,
//  then renamed into place.  Existing objects are never
//  overwritten
//
//  Object wire format (binary, little-endian):
//    [4]  magic   = 0x4E_4F_44_55  ("NODU")
//    [1]  version = 1
//    [1]  type    = ObjectType (u8)
//    [4]  payload length (u32)
//    [n]  payload bytes
//    [32] BLAKE3 hash of (type ++ payload)   (integrity check)

const std = @import("std");
const hash_mod = @import("hash.zig");
const Hash = hash_mod.Hash;

pub const ObjectType = enum(u8) {
    blob = 1,
    tree = 2,
    commit = 3,
    ast = 4,
};

pub const MAGIC: u32 = 0x4E_4F_44_55; // "NODU"
pub const VERSION: u8 = 1;
const object_rel_path_len = 2 + 1 + 2 + 1 + 64; // xx/yy/full-hex-hash
const object_dir_path_len = 2 + 1 + 2; // xx/yy
const object_header_len = 10;

pub const ObjectHeader = struct {
    obj_type: ObjectType,
    payload_len: u32,
};

pub const Object = struct {
    obj_type: ObjectType,
    payload: []u8, // caller owns; free with store.alloc
};

pub fn encodeObject(
    writer: anytype,
    obj_type: ObjectType,
    payload: []const u8,
) !Hash {
    const type_byte = [1]u8{@intFromEnum(obj_type)};
    const parts: []const []const u8 = &.{ &type_byte, payload };
    const obj_hash = hash_mod.blake3Many(parts);

    try writer.writeInt(u32, MAGIC, .little);
    try writer.writeByte(VERSION);
    try writer.writeByte(@intFromEnum(obj_type));
    try writer.writeInt(u32, @intCast(payload.len), .little);
    try writer.writeAll(payload);
    try writer.writeAll(&obj_hash);

    return obj_hash;
}

pub fn encodeObjectFromReader(
    writer: anytype,
    obj_type: ObjectType,
    payload_len: usize,
    reader: *std.Io.Reader,
) !Hash {
    const type_byte = [1]u8{@intFromEnum(obj_type)};
    var hasher = hash_mod.Hasher.init();
    hasher.update(&type_byte);

    try writer.writeInt(u32, MAGIC, .little);
    try writer.writeByte(VERSION);
    try writer.writeByte(@intFromEnum(obj_type));
    try writer.writeInt(u32, @intCast(payload_len), .little);

    var copy_buf: [4096]u8 = undefined;
    var remaining = payload_len;
    while (remaining > 0) {
        const chunk = copy_buf[0..@min(copy_buf.len, remaining)];
        const n = try reader.readSliceShort(chunk);
        if (n == 0) return error.EndOfStream;

        hasher.update(chunk[0..n]);
        try writer.writeAll(chunk[0..n]);
        remaining -= n;
    }

    const obj_hash = hasher.final();
    try writer.writeAll(&obj_hash);
    return obj_hash;
}

pub fn decodeObjectHeader(reader: anytype) !ObjectHeader {
    const magic = try reader.takeInt(u32, .little);
    if (magic != MAGIC) return error.CorruptObject;

    const ver = try reader.takeByte();
    if (ver != VERSION) return error.UnsupportedVersion;

    const type_byte = try reader.takeByte();
    const obj_type: ObjectType = @enumFromInt(type_byte);

    return .{
        .obj_type = obj_type,
        .payload_len = try reader.takeInt(u32, .little),
    };
}

fn decodeObjectHeaderBytes(bytes: *const [object_header_len]u8) !ObjectHeader {
    if (std.mem.readInt(u32, bytes[0..4], .little) != MAGIC) {
        return error.CorruptObject;
    }
    if (bytes[4] != VERSION) {
        return error.UnsupportedVersion;
    }

    return .{
        .obj_type = @enumFromInt(bytes[5]),
        .payload_len = std.mem.readInt(u32, bytes[6..10], .little),
    };
}

pub fn decodeObject(alloc: std.mem.Allocator, reader: anytype) !Object {
    const header = try decodeObjectHeader(reader);

    const payload = try alloc.alloc(u8, header.payload_len);
    errdefer alloc.free(payload);
    @memcpy(payload, try reader.take(header.payload_len));

    var stored_hash: Hash = undefined;
    @memcpy(&stored_hash, try reader.take(stored_hash.len));

    const type_byte = [1]u8{@intFromEnum(header.obj_type)};
    const parts: []const []const u8 = &.{ &type_byte, payload };
    const computed = hash_mod.blake3Many(parts);
    if (!std.mem.eql(u8, &computed, &stored_hash)) return error.HashMismatch;

    return .{
        .obj_type = header.obj_type,
        .payload = payload,
    };
}

pub const Store = struct {
    dir: std.fs.Dir,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, repo_root: []const u8) !Store {
        var cwd = std.fs.cwd();
        const objects_path = try std.fs.path.join(alloc, &.{ repo_root, ".nodus", "objects" });
        defer alloc.free(objects_path);

        try cwd.makePath(objects_path);
        const dir = try cwd.openDir(objects_path, .{});

        return .{ .dir = dir, .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        self.dir.close();
    }

    /// Store raw payload bytes under the given type
    /// Returns the content hash (BLAKE3 of type-byte ++ payload)
    pub fn put(self: *const Store, obj_type: ObjectType, payload: []const u8) !Hash {
        var reader = std.io.Reader.fixed(payload);
        return self.putReader(obj_type, payload.len, &reader);
    }

    /// Store payload bytes from a reader under the given type.
    /// Caller must provide the exact payload length in bytes.
    pub fn putReader(
        self: *const Store,
        obj_type: ObjectType,
        payload_len: usize,
        reader: *std.Io.Reader,
    ) !Hash {
        try self.dir.makePath(".tmp");

        var rand_buf: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        const tmp_path = try std.fmt.allocPrint(self.alloc, ".tmp/{x}.tmp", .{rand_buf});
        defer self.alloc.free(tmp_path);

        const f = try self.dir.createFile(tmp_path, .{});
        var file_closed = false;
        defer if (!file_closed) f.close();
        errdefer {
            if (!file_closed) {
                f.close();
                file_closed = true;
            }
            self.dir.deleteFile(tmp_path) catch {};
        }

        var write_buf: [4096]u8 = undefined;
        var file_writer = f.writer(&write_buf);
        const w = &file_writer.interface;

        const obj_hash = try encodeObjectFromReader(w, obj_type, payload_len, reader);

        try w.flush();
        f.close();
        file_closed = true;

        var path_buf: [object_rel_path_len]u8 = undefined;
        const path = self.objectPath(&path_buf, obj_hash);

        var dir_path_buf: [object_dir_path_len]u8 = undefined;
        const dir_path = self.objectDirPath(&dir_path_buf, obj_hash);
        self.dir.rename(tmp_path, path) catch |err| switch (err) {
            error.FileNotFound => {
                try self.dir.makePath(dir_path);
                try self.dir.rename(tmp_path, path);
            },
            error.PathAlreadyExists => {
                self.dir.deleteFile(tmp_path) catch {};
                return obj_hash;
            },
            else => return err,
        };
        return obj_hash;
    }

    /// Load an object by hash.  Returns error.NotFound if missing.
    pub fn get(self: *const Store, obj_hash: Hash) !Object {
        var path_buf: [object_rel_path_len]u8 = undefined;
        const path = self.objectPath(&path_buf, obj_hash);

        const f = self.dir.openFile(path, .{}) catch |e| {
            if (e == error.FileNotFound) return error.NotFound;
            return e;
        };
        defer f.close();

        var read_buf: [4096]u8 = undefined;
        var file_reader = f.reader(&read_buf);
        const r = &file_reader.interface;
        return decodeObject(self.alloc, r);
    }

    /// Load only the object header. Returns error.NotFound if missing
    pub fn getHeader(self: *const Store, obj_hash: Hash) !ObjectHeader {
        var path_buf: [object_rel_path_len]u8 = undefined;
        const path = self.objectPath(&path_buf, obj_hash);

        const f = self.dir.openFile(path, .{}) catch |e| {
            if (e == error.FileNotFound) return error.NotFound;
            return e;
        };
        defer f.close();

        var read_buf: [64]u8 = undefined;
        var file_reader = f.reader(&read_buf);
        const r = &file_reader.interface;
        return decodeObjectHeader(r);
    }

    /// Check existence without loading
    pub fn exists(self: *const Store, obj_hash: Hash) bool {
        var path_buf: [object_rel_path_len]u8 = undefined;
        const path = self.objectPath(&path_buf, obj_hash);
        self.dir.access(path, .{}) catch return false;
        return true;
    }

    fn objectPath(_: *const Store, buf: *[object_rel_path_len]u8, obj_hash: Hash) []const u8 {
        var hex_buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{obj_hash}) catch unreachable;
        return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{
            hex[0..2],
            hex[2..4],
            hex,
        }) catch unreachable;
    }

    fn objectDirPath(_: *const Store, buf: *[object_dir_path_len]u8, obj_hash: Hash) []const u8 {
        var hex_buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{obj_hash}) catch unreachable;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{
            hex[0..2],
            hex[2..4],
        }) catch unreachable;
    }
};

pub const ObjectReader = struct {
    file: std.fs.File,
    header: ObjectHeader,
    hasher: hash_mod.Hasher,
    remaining_bytes: usize,
    trailer_verified: bool,

    pub fn init(store: *const Store, obj_hash: Hash) !ObjectReader {
        var path_buf: [object_rel_path_len]u8 = undefined;
        const path = store.objectPath(&path_buf, obj_hash);

        const file = store.dir.openFile(path, .{}) catch |e| {
            if (e == error.FileNotFound) return error.NotFound;
            return e;
        };
        errdefer file.close();

        var header_buf: [object_header_len]u8 = undefined;
        const n = try file.readAll(&header_buf);
        if (n != header_buf.len) return error.EndOfStream;

        const header = try decodeObjectHeaderBytes(&header_buf);
        var hasher = hash_mod.Hasher.init();
        hasher.update(&[1]u8{@intFromEnum(header.obj_type)});

        return .{
            .file = file,
            .header = header,
            .hasher = hasher,
            .remaining_bytes = header.payload_len,
            .trailer_verified = false,
        };
    }

    pub fn deinit(self: *ObjectReader) void {
        self.file.close();
    }

    pub fn read(self: *ObjectReader, buffer: []u8) !usize {
        if (buffer.len == 0) {
            if (self.remaining_bytes == 0 and !self.trailer_verified) {
                try self.verifyTrailer();
            }
            return 0;
        }

        if (self.remaining_bytes == 0) {
            if (!self.trailer_verified) {
                try self.verifyTrailer();
            }
            return 0;
        }

        const to_read = @min(buffer.len, self.remaining_bytes);
        const n = try self.file.readAll(buffer[0..to_read]);
        if (n != to_read) return error.EndOfStream;

        self.hasher.update(buffer[0..n]);
        self.remaining_bytes -= n;
        if (self.remaining_bytes == 0) {
            try self.verifyTrailer();
        }
        return n;
    }

    fn verifyTrailer(self: *ObjectReader) !void {
        if (self.trailer_verified) return;

        var stored_hash: Hash = undefined;
        const n = try self.file.readAll(&stored_hash);
        if (n != stored_hash.len) return error.EndOfStream;

        const computed = self.hasher.final();
        if (!std.mem.eql(u8, &computed, &stored_hash)) return error.HashMismatch;
        self.trailer_verified = true;
    }
};

test "store put and get round-trip" {
    const alloc = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const payload = "hello, object store!";
    const h = try store.put(.blob, payload);

    try std.testing.expect(store.exists(h));

    const obj = try store.get(h);
    defer alloc.free(obj.payload);

    try std.testing.expectEqual(ObjectType.blob, obj.obj_type);
    try std.testing.expectEqualStrings(payload, obj.payload);
}

test "store deduplication" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const h1 = try store.put(.blob, "dedup test");
    const h2 = try store.put(.blob, "dedup test");
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "store putReader tolerates destination appearing before rename" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const payload = "race-safe payload";
    const h = try store.put(.blob, payload);

    var reader = std.io.Reader.fixed(payload);
    const h2 = try store.putReader(.blob, payload.len, &reader);

    try std.testing.expectEqualSlices(u8, &h, &h2);

    const obj = try store.get(h2);
    defer alloc.free(obj.payload);
    try std.testing.expectEqualStrings(payload, obj.payload);
}

test "store putReader streams payload into object" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };

    var reader = std.io.Reader.fixed("streamed payload");
    const h = try store.putReader(.blob, "streamed payload".len, &reader);

    const obj = try store.get(h);
    defer alloc.free(obj.payload);

    try std.testing.expectEqual(ObjectType.blob, obj.obj_type);
    try std.testing.expectEqualStrings("streamed payload", obj.payload);
}

test "store missing hash returns NotFound" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };
    const missing = hash_mod.blake3("definitely not stored");
    try std.testing.expectError(error.NotFound, store.get(missing));
}

test "store getHeader reads metadata without payload allocation" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const payload = "header only";
    const h = try store.put(.commit, payload);
    const header = try store.getHeader(h);

    try std.testing.expectEqual(ObjectType.commit, header.obj_type);
    try std.testing.expectEqual(@as(u32, payload.len), header.payload_len);
}

test "store getHeader missing hash returns NotFound" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };
    const missing = hash_mod.blake3("still not stored");
    try std.testing.expectError(error.NotFound, store.getHeader(missing));
}

test "store round-trips empty payload" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };

    const h = try store.put(.blob, "");
    const obj = try store.get(h);
    defer alloc.free(obj.payload);

    try std.testing.expectEqual(ObjectType.blob, obj.obj_type);
    try std.testing.expectEqual(@as(usize, 0), obj.payload.len);
}

test "decodeObject rejects corrupt magic" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    try bytes.appendSlice(std.testing.allocator, &[_]u8{
        0x00,    0x00,                          0x00, 0x00, // bad magic
        VERSION, @intFromEnum(ObjectType.blob),
        0x00, 0x00, 0x00, 0x00, // zero payload len
    });
    try bytes.appendNTimes(std.testing.allocator, 0, @sizeOf(Hash));

    var reader = std.io.Reader.fixed(bytes.items);
    try std.testing.expectError(error.CorruptObject, decodeObject(std.testing.allocator, &reader));
}

test "decodeObject rejects unsupported version" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    try bytes.appendSlice(std.testing.allocator, &[_]u8{
        0x55, 0x44, 0x4F, 0x4E, // MAGIC little-endian
        0xFF, // bad version
        @intFromEnum(ObjectType.blob),
        0x00, 0x00, 0x00, 0x00, // zero payload len
    });
    try bytes.appendNTimes(std.testing.allocator, 0, @sizeOf(Hash));

    var reader = std.io.Reader.fixed(bytes.items);
    try std.testing.expectError(error.UnsupportedVersion, decodeObject(std.testing.allocator, &reader));
}

test "decodeObject rejects truncated payload" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    try bytes.appendSlice(std.testing.allocator, &[_]u8{
        0x55,    0x44,                          0x4F, 0x4E, // MAGIC little-endian
        VERSION, @intFromEnum(ObjectType.blob),
        0x05, 0x00, 0x00, 0x00, // payload len = 5
    });
    try bytes.appendSlice(std.testing.allocator, "abc");

    var reader = std.io.Reader.fixed(bytes.items);
    try std.testing.expectError(error.EndOfStream, decodeObject(std.testing.allocator, &reader));
}

test "decodeObject rejects truncated stored hash" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    try bytes.appendSlice(std.testing.allocator, &[_]u8{
        0x55,    0x44,                          0x4F, 0x4E, // MAGIC little-endian
        VERSION, @intFromEnum(ObjectType.blob),
        0x03, 0x00, 0x00, 0x00, // payload len = 3
    });
    try bytes.appendSlice(std.testing.allocator, "abc");
    try bytes.appendNTimes(std.testing.allocator, 0, 8);

    var reader = std.io.Reader.fixed(bytes.items);
    try std.testing.expectError(error.EndOfStream, decodeObject(std.testing.allocator, &reader));
}

test "decodeObject rejects hash mismatch" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    var payload = "abc".*;
    var encoded = std.io.Writer.Allocating.init(std.testing.allocator);
    defer encoded.deinit();
    _ = try encodeObject(&encoded.writer, .blob, &payload);

    try bytes.appendSlice(std.testing.allocator, encoded.written());
    bytes.items[10] = 'z';

    var reader = std.io.Reader.fixed(bytes.items);
    try std.testing.expectError(error.HashMismatch, decodeObject(std.testing.allocator, &reader));
}

test "ObjectReader streams payload and verifies trailer" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };
    const payload = "stream me in chunks";
    const h = try store.put(.blob, payload);

    var object_reader = try ObjectReader.init(&store, h);
    defer object_reader.deinit();

    try std.testing.expectEqual(ObjectType.blob, object_reader.header.obj_type);
    try std.testing.expectEqual(@as(u32, payload.len), object_reader.header.payload_len);

    var out: [8]u8 = undefined;
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(alloc);

    while (true) {
        const n = try object_reader.read(&out);
        if (n == 0) break;
        try collected.appendSlice(alloc, out[0..n]);
    }

    try std.testing.expectEqualStrings(payload, collected.items);
}

test "ObjectReader detects hash mismatch at end of stream" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };
    const payload = "verify me";
    const h = try store.put(.blob, payload);

    var path_buf: [object_rel_path_len]u8 = undefined;
    const path = store.objectPath(&path_buf, h);

    var file = try store.dir.openFile(path, .{ .mode = .read_write });
    defer file.close();

    const hash_offset = object_header_len + payload.len;
    try file.pwriteAll(&[_]u8{0xFF}, hash_offset);

    var object_reader = try ObjectReader.init(&store, h);
    defer object_reader.deinit();

    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try object_reader.read(&out));
    try std.testing.expectEqualStrings(payload[0..4], out[0..4]);
    try std.testing.expectEqual(@as(usize, 4), try object_reader.read(&out));
    try std.testing.expectEqualStrings(payload[4..8], out[0..4]);
    try std.testing.expectError(error.HashMismatch, object_reader.read(&out));
}
