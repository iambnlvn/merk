const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing_io = @import("testing.zig");

/// Write `bytes` prefixed by its length as a little-endian `LenT`.
pub fn writeBytes(comptime LenT: type, writer: *Io.Writer, bytes: []const u8) !void {
    try writer.writeInt(LenT, @intCast(bytes.len), .little);
    try writer.writeAll(bytes);
}

/// Read a `LenT`-length-prefixed byte string into a freshly allocated,
/// owned buffer. Caller frees with `alloc.free`.
pub fn readBytesAlloc(comptime LenT: type, alloc: Allocator, reader: *Io.Reader) ![]u8 {
    const len = try reader.takeInt(LenT, .little);

    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);

    try reader.readSliceAll(buf);
    return buf;
}

pub fn writeCount(comptime CountT: type, writer: *Io.Writer, count: usize) !void {
    try writer.writeInt(CountT, @intCast(count), .little);
}

pub fn readCount(comptime CountT: type, reader: *Io.Reader) !CountT {
    return reader.takeInt(CountT, .little);
}

/// Auto-fill convention shared by identity and commit-metadata timestamps:
/// 0 means "use the current wall-clock time at serialisation/init time".
/// Centralised here so every caller applies the same rule instead of
/// re-deriving the same ternary.
pub fn resolveTimestampMs(timestamp_ms: i64) i64 {
    return if (timestamp_ms != 0) timestamp_ms else std.time.milliTimestamp();
}

/// Write a `CountT`-counted array of `LenT`-length-prefixed byte strings.
pub fn writeStringArray(
    comptime CountT: type,
    comptime LenT: type,
    writer: *Io.Writer,
    items: []const []const u8,
) !void {
    try writeCount(CountT, writer, items.len);
    for (items) |item| try writeBytes(LenT, writer, item);
}

/// Read a `CountT`-counted array of `LenT`-length-prefixed byte strings
/// into freshly allocated, owned copies. On error, everything already
/// allocated — including the outer slice — is freed before returning.
pub fn readStringArrayAlloc(
    comptime CountT: type,
    comptime LenT: type,
    alloc: Allocator,
    reader: *Io.Reader,
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

/// Write a `CountT`-counted array of self-serializing items — each `T`
/// exposes `fn serialize(self: T, writer: *Io.Writer) !void`. Writing
/// never allocates, so this works the same whether `T` is a fixed-size
/// record like `ParentInfo`/`DependencyInfo` or a borrowing view like
/// `TrailerInfo` — the allocation-free/owning distinction below only
/// matters for the read side (`readListAlloc` vs `readOwningListAlloc`),
/// where materializing an owned copy is unavoidable.
pub fn writeList(comptime T: type, comptime CountT: type, writer: *Io.Writer, items: []const T) !void {
    try writeCount(CountT, writer, items.len);
    for (items) |item| try item.serialize(writer);
}

/// Read a `CountT`-counted array of allocation-free items, each read via
/// its own `fn deserialize(reader: *Io.Reader) !T`. `T` must not own any
/// memory itself (a fixed-size record like `ParentInfo` or
/// `DependencyInfo`) — there's nothing to unwind per-element on a
/// partial failure, only the outer slice, which `errdefer` covers.
/// For element types that *do* own memory, see `readOwningListAlloc`.
pub fn readListAlloc(comptime T: type, comptime CountT: type, alloc: Allocator, reader: *Io.Reader) ![]T {
    const len = try readCount(CountT, reader);
    const items = try alloc.alloc(T, len);
    errdefer alloc.free(items);

    for (items) |*item| item.* = try T.deserialize(reader);

    return items;
}

/// Read a `CountT`-counted array of owning items, each read via its own
/// `fn deserialize(alloc: Allocator, reader: *Io.Reader) !T` and unwound
/// via `fn deinit(self: *T, alloc: Allocator) void` if a later element
/// (or a caller's own follow-up validation) fails. The allocator-aware
/// counterpart to `readListAlloc`, for element types that hold their own
/// allocations — e.g. `Trailer`, whose `key`/`value` are owned slices.
/// Generalizes the same "allocate N, fill, unwind what's filled so far
/// on error" shape `readStringArrayAlloc` already uses for raw byte
/// strings, to any self-deserializing owning type.
pub fn readOwningListAlloc(comptime T: type, comptime CountT: type, alloc: Allocator, reader: *Io.Reader) ![]T {
    const len = try readCount(CountT, reader);
    const items = try alloc.alloc(T, len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(alloc);
        alloc.free(items);
    }

    while (initialized < len) : (initialized += 1) {
        items[initialized] = try T.deserialize(alloc, reader);
    }

    return items;
}

test "wire: writeBytes and readBytesAlloc standard roundtrip" {
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    const sample_text = "Commit message title metadata";

    // Test with a u16 length prefix
    try writeBytes(u16, sink.writer(), sample_text);

    // Layout validation: [2 Bytes Length] + [29 Bytes Content] = 31 Bytes
    try testing.expectEqual(@as(usize, 2 + sample_text.len), sink.bytes().len);
    try testing.expectEqual(@as(u8, @intCast(sample_text.len)), sink.bytes()[0]); // Little endian low byte

    var reader = testing_io.fixedReader(sink.bytes());
    const decoded = try readBytesAlloc(u16, alloc, &reader);
    defer alloc.free(decoded);

    try testing.expectEqualSlices(u8, sample_text, decoded);
}

test "wire: readBytesAlloc unexpected EOF handling" {
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    // Intentionally forge a length prefix of 100, but write nothing else
    try sink.writer().writeInt(u8, 100, .little);

    var reader = testing_io.fixedReader(sink.bytes());

    // Should fail cleanly with EndOfStream without leaking memory
    try testing.expectError(error.EndOfStream, readBytesAlloc(u8, alloc, &reader));
}

test "wire: writeCount and readCount validation" {
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    // Check count boundary scenarios
    try writeCount(u8, sink.writer(), 42);
    try writeCount(u32, sink.writer(), 99999);

    var reader = testing_io.fixedReader(sink.bytes());

    const small_count = try readCount(u8, &reader);
    const large_count = try readCount(u32, &reader);

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
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    const labels = [_][]const u8{ "feat", "v2", "" };
    try writeStringArray(u16, u16, sink.writer(), &labels);

    var reader = testing_io.fixedReader(sink.bytes());
    const decoded = try readStringArrayAlloc(u16, u16, alloc, &reader);
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
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    try writeCount(u16, sink.writer(), 2);
    try writeBytes(u16, sink.writer(), "only-one");

    var reader = testing_io.fixedReader(sink.bytes());
    try testing.expectError(error.EndOfStream, readStringArrayAlloc(u16, u16, alloc, &reader));
}

const ListItem = struct {
    value: u8,

    fn init(value: u8) ListItem {
        return .{ .value = value };
    }

    fn serialize(self: ListItem, writer: *Io.Writer) !void {
        try writer.writeByte(self.value);
    }

    fn deserialize(reader: *Io.Reader) !ListItem {
        return .{ .value = try reader.takeByte() };
    }
};

test "wire: writeList and readListAlloc roundtrip allocation-free items" {
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    const items = [_]ListItem{ .init(1), .init(2), .init(3) };
    try writeList(ListItem, u8, sink.writer(), &items);

    // count(1) + 3 * value(1)
    try testing.expectEqual(@as(usize, 4), sink.bytes().len);

    var reader = testing_io.fixedReader(sink.bytes());
    const decoded = try readListAlloc(ListItem, u8, alloc, &reader);
    defer alloc.free(decoded);

    try testing.expectEqual(@as(usize, 3), decoded.len);
    for (items, decoded) |expected, actual| {
        try testing.expectEqual(expected.value, actual.value);
    }
}

const OwningListItem = struct {
    value: []u8,

    fn deserialize(alloc: Allocator, reader: *Io.Reader) !OwningListItem {
        return .{ .value = try readBytesAlloc(u8, alloc, reader) };
    }

    fn deinit(self: *OwningListItem, alloc: Allocator) void {
        alloc.free(self.value);
        self.* = undefined;
    }
};

test "wire: readOwningListAlloc frees every already-read element on a later failure" {
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    // Claims 2 elements, but only supplies one well-formed one — the
    // second read fails partway through, and the first element (already
    // allocated) must not leak.
    try writeCount(u8, sink.writer(), 2);
    try writeBytes(u8, sink.writer(), "first");

    var reader = testing_io.fixedReader(sink.bytes());
    try testing.expectError(error.EndOfStream, readOwningListAlloc(OwningListItem, u8, alloc, &reader));
}

test "wire: readOwningListAlloc roundtrips owning items" {
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    try writeCount(u8, sink.writer(), 2);
    try writeBytes(u8, sink.writer(), "alpha");
    try writeBytes(u8, sink.writer(), "beta");

    var reader = testing_io.fixedReader(sink.bytes());
    const decoded = try readOwningListAlloc(OwningListItem, u8, alloc, &reader);
    defer {
        for (decoded) |*item| item.deinit(alloc);
        alloc.free(decoded);
    }

    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expectEqualStrings("alpha", decoded[0].value);
    try testing.expectEqualStrings("beta", decoded[1].value);
}
