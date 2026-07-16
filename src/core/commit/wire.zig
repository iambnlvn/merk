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

/// Auto-fill convention shared by identity and commit-metadata timestamps:
/// 0 means "use the current wall-clock time at serialisation/init time".
/// Centralised here so every caller applies the same rule instead of
/// re-deriving the same ternary
pub fn resolveTimestampMs(timestamp_ms: i64) i64 {
    return if (timestamp_ms != 0) timestamp_ms else std.time.milliTimestamp();
}

/// Write a `CountT`-counted array of `LenT`-length-prefixed byte strings
pub fn writeStringArray(
    comptime CountT: type,
    comptime LenT: type,
    writer: anytype,
    items: []const []const u8,
) !void {
    try writeCount(CountT, writer, items.len);
    for (items) |item| try writeBytes(LenT, writer, item);
}

/// Read a `CountT`-counted array of `LenT`-length-prefixed byte strings
/// into freshly allocated, owned copies. On error, everything already
/// allocated — including the outer slice — is freed before returning
pub fn readStringArrayAlloc(
    comptime CountT: type,
    comptime LenT: type,
    alloc: std.mem.Allocator,
    reader: anytype,
) ![][]u8 {
    const count = try readCount(CountT, reader);
    const items = try alloc.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| alloc.free(item);
        alloc.free(items);
    }

    while (initialized < count) : (initialized += 1) {
        items[initialized] = try readBytesAlloc(LenT, alloc, reader);
    }

    return items;
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

test "wire: resolveTimestampMs passes through nonzero, fills zero with now" {
    try testing.expectEqual(@as(i64, 1_700_000_000_000), resolveTimestampMs(1_700_000_000_000));

    const before = std.time.milliTimestamp();
    const now = resolveTimestampMs(0);
    const after = std.time.milliTimestamp();
    try testing.expect(now >= before and now <= after);
}

test "wire: writeStringArray and readStringArrayAlloc roundtrip" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    const labels = [_][]const u8{ "feat", "v2", "" };
    try writeStringArray(u16, u16, buf.writer(alloc), &labels);

    var mock_reader = MockReader{ .buffer = buf.items };
    const decoded = try readStringArrayAlloc(u16, u16, alloc, &mock_reader);
    defer {
        for (decoded) |item| alloc.free(item);
        alloc.free(decoded);
    }

    try testing.expectEqual(@as(usize, 3), decoded.len);
    try testing.expectEqualStrings("feat", decoded[0]);
    try testing.expectEqualStrings("v2", decoded[1]);
    try testing.expectEqualStrings("", decoded[2]);
}

test "wire: readStringArrayAlloc frees partial allocations on truncation" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try writeCount(u16, buf.writer(alloc), 2);
    try writeBytes(u16, buf.writer(alloc), "only-one");

    var mock_reader = MockReader{ .buffer = buf.items };
    try testing.expectError(error.EndOfStream, readStringArrayAlloc(u16, u16, alloc, &mock_reader));
}
