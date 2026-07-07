const std = @import("std");
const testing = std.testing;
const MockReader = @import("testing.zig").MockReader;

pub fn writeBytes(comptime LenT: type, writer: anytype, bytes: []const u8) !void {
    try writer.writeInt(LenT, @intCast(bytes.len), .little);
    try writer.writeAll(bytes);
}

pub fn readBytesAlloc(comptime LenT: type, alloc: std.mem.Allocator, reader: anytype) ![]u8 {
    const len = try reader.takeInt(LenT, .little);

    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);

    const bytes = try reader.take(len);
    @memcpy(buf, bytes);

    return buf;
}

pub fn writeCount(comptime CountT: type, writer: anytype, count: usize) !void {
    try writer.writeInt(CountT, @intCast(count), .little);
}

pub fn readCount(comptime CountT: type, reader: anytype) !CountT {
    return reader.takeInt(CountT, .little);
}

test "wire: writeBytes and readBytesAlloc standard roundtrip" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    const sample_text = "Commit message title metadata";

    // Test with a u16 length prefix
    try writeBytes(u16, buf.writer(alloc), sample_text);

    // Layout validation: [2 Bytes Length] + [29 Bytes Content] = 31 Bytes
    try testing.expectEqual(@as(usize, 2 + sample_text.len), buf.items.len);
    try testing.expectEqual(@as(u8, @intCast(sample_text.len)), buf.items[0]); // Little endian low byte

    var mock_reader = MockReader{ .buffer = buf.items };
    const decoded = try readBytesAlloc(u16, alloc, &mock_reader);
    defer alloc.free(decoded);

    try testing.expectEqualSlices(u8, sample_text, decoded);
}

test "wire: readBytesAlloc unexpected EOF handling" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // Intentionally forge a length prefix of 100, but write nothing else
    try buf.writer(alloc).writeInt(u8, 100, .little);

    var mock_reader = MockReader{ .buffer = buf.items };

    // Should fail cleanly with EndOfStream without leaking memory
    try testing.expectError(error.EndOfStream, readBytesAlloc(u8, alloc, &mock_reader));
}

test "wire: writeCount and readCount validation" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // Check count boundary scenarios
    try writeCount(u8, buf.writer(alloc), 42);
    try writeCount(u32, buf.writer(alloc), 99999);

    var mock_reader = MockReader{ .buffer = buf.items };

    const small_count = try readCount(u8, &mock_reader);
    const large_count = try readCount(u32, &mock_reader);

    try testing.expectEqual(@as(u8, 42), small_count);
    try testing.expectEqual(@as(u32, 99999), large_count);
}
