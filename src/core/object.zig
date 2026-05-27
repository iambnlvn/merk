//  Layout on disk:
//    <repo>/.nodus/objects/<xx>/<yy>/<full-hex-hash>
//
//  Where <xx> = first 2 hex chars, <yy> = next 2 hex chars
//  This sharding keeps directory sizes manageable
//
//  Every write is atomic: data is written to a temp file first,
//  then renamed into place. Existing objects are never overwritten
//
//  Object wire format v2 (little-endian):
//    [4]  magic   = 0x4E_4F_44_55  ("NODU")
//    [1]  version = 2
//    [1]  type    = ObjectType (u8)
//    [1]  codec   = compression.Codec (u8)
//    [1]  reserved
//    [4]  payload length (u32, uncompressed)
//    [4]  stored length  (u32, bytes on disk)
//    [n]  stored bytes   (raw or compressed depending on codec)
//    [32] BLAKE3 hash of (type ++ original payload)

const std = @import("std");
const compression = @import("./compression.zig");
const hash_mod = @import("./hash.zig");
const Hash = hash_mod.Hash;

pub const ObjectType = enum(u8) {
    blob = 1,
    tree = 2,
    commit = 3,
    ast = 4,
};

pub const MAGIC: u32 = 0x4E_4F_44_55; // "NODU"
pub const VERSION: u8 = 2;
const object_rel_path_len = 2 + 1 + 2 + 1 + 64;
const object_dir_path_len = 2 + 1 + 2;
const object_header_len = 16;

pub const ObjectHeader = struct {
    version: u8,
    obj_type: ObjectType,
    codec: compression.Codec,
    payload_len: u32,
    stored_len: u32,
};

pub const Object = struct {
    obj_type: ObjectType,
    payload: []u8,
};

pub fn encodeObject(
    writer: anytype,
    obj_type: ObjectType,
    payload: []const u8,
) !Hash {
    const type_byte = [1]u8{@intFromEnum(obj_type)};
    const parts: []const []const u8 = &.{ &type_byte, payload };
    const obj_hash = hash_mod.blake3Many(parts);

    try writeHeader(writer, .{
        .version = VERSION,
        .obj_type = obj_type,
        .codec = .none,
        .payload_len = @intCast(payload.len),
        .stored_len = @intCast(payload.len),
    });

    try writer.writeAll(payload);
    try writer.writeAll(&obj_hash);
    return obj_hash;
}

pub fn decodeObject(alloc: std.mem.Allocator, reader: anytype) !Object {
    const header = try decodeObjectHeader(reader);

    const payload = switch (header.codec) {
        .none => blk: {
            const bytes = try alloc.alloc(u8, header.payload_len);
            errdefer alloc.free(bytes);
            @memcpy(bytes, try reader.take(header.payload_len));
            break :blk bytes;
        },
    };
    errdefer alloc.free(payload);

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

pub fn decodeObjectHeader(reader: anytype) !ObjectHeader {
    const magic = try reader.takeInt(u32, .little);
    if (magic != MAGIC) return error.CorruptObject;

    const version = try reader.takeByte();
    const type_byte = try reader.takeByte();
    const obj_type: ObjectType = @enumFromInt(type_byte);

    if (version != VERSION) return error.UnsupportedVersion;

    return .{
        .version = version,
        .obj_type = obj_type,
        .codec = @enumFromInt(try reader.takeByte()),
        .payload_len = blk: {
            _ = try reader.takeByte();
            break :blk try reader.takeInt(u32, .little);
        },
        .stored_len = try reader.takeInt(u32, .little),
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

    pub fn put(self: *const Store, obj_type: ObjectType, payload: []const u8) !Hash {
        var reader = std.io.Reader.fixed(payload);
        return self.putReader(obj_type, payload.len, &reader);
    }

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

        const f = try self.dir.createFile(tmp_path, .{ .read = true });
        var file_closed = false;
        defer if (!file_closed) f.close();
        errdefer {
            if (!file_closed) {
                f.close();
                file_closed = true;
            }
            self.dir.deleteFile(tmp_path) catch {};
        }

        const codec = compression.choose(payload_len);
        const header_placeholder = ObjectHeader{
            .version = VERSION,
            .obj_type = obj_type,
            .codec = codec,
            .payload_len = @intCast(payload_len),
            .stored_len = 0,
        };
        try writeHeaderToFile(f, header_placeholder);
        const body_start = try f.getPos();

        var write_buf: [4096]u8 = undefined;
        var file_writer = f.writerStreaming(&write_buf);
        const w = &file_writer.interface;

        var content_hasher = hash_mod.Hasher.init();
        const type_byte = [1]u8{@intFromEnum(obj_type)};
        content_hasher.update(&type_byte);

        const HashSink = struct {
            var hasher: *hash_mod.Hasher = undefined;

            fn onChunk(bytes: []const u8) void {
                hasher.update(bytes);
            }
        };
        HashSink.hasher = &content_hasher;

        try compression.encodeBody(w, reader, payload_len, codec, HashSink.onChunk);
        try w.flush();

        const body_end = try f.getPos();
        const stored_len: u32 = @intCast(body_end - body_start);
        const obj_hash = content_hasher.final();

        try f.writeAll(&obj_hash);
        try f.seekTo(0);
        try writeHeaderToFile(f, .{
            .version = VERSION,
            .obj_type = obj_type,
            .codec = codec,
            .payload_len = @intCast(payload_len),
            .stored_len = stored_len,
        });

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

    pub fn get(self: *const Store, obj_hash: Hash) !Object {
        var path_buf: [object_rel_path_len]u8 = undefined;
        const path = self.objectPath(&path_buf, obj_hash);

        const f = self.dir.openFile(path, .{}) catch |e| {
            if (e == error.FileNotFound) return error.NotFound;
            return e;
        };
        defer f.close();

        var read_buf: [4096]u8 = undefined;
        var file_reader = f.readerStreaming(&read_buf);
        return decodeObject(self.alloc, &file_reader.interface);
    }

    pub fn getHeader(self: *const Store, obj_hash: Hash) !ObjectHeader {
        var path_buf: [object_rel_path_len]u8 = undefined;
        const path = self.objectPath(&path_buf, obj_hash);

        const f = self.dir.openFile(path, .{}) catch |e| {
            if (e == error.FileNotFound) return error.NotFound;
            return e;
        };
        defer f.close();

        var read_buf: [64]u8 = undefined;
        var file_reader = f.readerStreaming(&read_buf);
        return decodeObjectHeader(&file_reader.interface);
    }

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
    file_reader: std.fs.File.Reader,
    header: ObjectHeader,
    hasher: hash_mod.Hasher,
    remaining_bytes: usize,
    trailer_verified: bool,
    file_reader_buf: [4096]u8,

    pub fn init(store: *const Store, obj_hash: Hash) !ObjectReader {
        var path_buf: [object_rel_path_len]u8 = undefined;
        const path = store.objectPath(&path_buf, obj_hash);

        const file = store.dir.openFile(path, .{}) catch |e| {
            if (e == error.FileNotFound) return error.NotFound;
            return e;
        };
        errdefer file.close();

        var header_reader_buf: [object_header_len]u8 = undefined;
        var header_reader = file.readerStreaming(&header_reader_buf);
        const header = try decodeObjectHeader(&header_reader.interface);

        var result = ObjectReader{
            .file = file,
            .file_reader_buf = undefined,
            .file_reader = undefined,
            .header = header,
            .hasher = hash_mod.Hasher.init(),
            .remaining_bytes = header.payload_len,
            .trailer_verified = false,
        };
        result.hasher.update(&[1]u8{@intFromEnum(header.obj_type)});
        result.file_reader = result.file.readerStreaming(&result.file_reader_buf);

        return result;
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
            if (!self.trailer_verified) try self.verifyTrailer();
            return 0;
        }

        const to_read = @min(buffer.len, self.remaining_bytes);
        const n = try compression.decodeStream(
            self.header.codec,
            &self.file_reader.interface,
            buffer[0..to_read],
        );
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
        @memcpy(&stored_hash, try self.file_reader.interface.take(stored_hash.len));

        const computed = self.hasher.final();
        if (!std.mem.eql(u8, &computed, &stored_hash)) return error.HashMismatch;
        self.trailer_verified = true;
    }
};

fn writeHeader(writer: anytype, header: ObjectHeader) !void {
    if (header.version != VERSION) return error.UnsupportedVersion;

    try writer.writeInt(u32, MAGIC, .little);
    try writer.writeByte(VERSION);
    try writer.writeByte(@intFromEnum(header.obj_type));
    try writer.writeByte(@intFromEnum(header.codec));
    try writer.writeByte(0);
    try writer.writeInt(u32, header.payload_len, .little);
    try writer.writeInt(u32, header.stored_len, .little);
}

fn writeHeaderToFile(file: std.fs.File, header: ObjectHeader) !void {
    var buf: [object_header_len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeHeader(&writer, header);
    try file.writeAll(buf[0..writer.end]);
}

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

test "store writes v2 raw payload header" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };
    const payload = "intent-aware version control " ** 32;

    const h = try store.put(.blob, payload);
    const header = try store.getHeader(h);

    try std.testing.expectEqual(VERSION, header.version);
    try std.testing.expectEqual(compression.Codec.none, header.codec);
    try std.testing.expectEqual(@as(u32, payload.len), header.stored_len);
    try std.testing.expectEqual(@as(u32, payload.len), header.payload_len);

    const obj = try store.get(h);
    defer alloc.free(obj.payload);
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

test "legacy v1 headers are rejected" {
    var bytes: [10]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], MAGIC, .little);
    bytes[4] = 1;
    bytes[5] = @intFromEnum(ObjectType.blob);
    std.mem.writeInt(u32, bytes[6..10], 0, .little);

    var reader = std.io.Reader.fixed(&bytes);
    try std.testing.expectError(error.UnsupportedVersion, decodeObjectHeader(&reader));
}

test "object reader streams payload" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var objects_dir = try tmp_dir.dir.openDir(".", .{});
    defer objects_dir.close();

    var store = Store{ .dir = objects_dir, .alloc = alloc };
    const payload = "node graph semantic history " ** 48;

    const h = try store.put(.blob, payload);
    var reader = try ObjectReader.init(&store, h);
    defer reader.deinit();

    var out = try alloc.alloc(u8, payload.len);
    defer alloc.free(out);

    var offset: usize = 0;
    while (offset < out.len) {
        const n = try reader.read(out[offset..@min(offset + 37, out.len)]);
        if (n == 0) break;
        offset += n;
    }

    try std.testing.expectEqual(payload.len, offset);
    try std.testing.expectEqualStrings(payload, out);
}
