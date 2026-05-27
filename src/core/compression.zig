const std = @import("std");

pub const Codec = enum(u8) {
    none = 0,
};

pub const default_min_compress_len: usize = 96;

pub fn choose(payload_len: usize) Codec {
    _ = payload_len;
    return .none;
}

pub fn encodeBody(
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    payload_len: usize,
    codec: Codec,
    on_chunk: *const fn ([]const u8) void,
) !void {
    switch (codec) {
        .none => try encodeRaw(writer, reader, payload_len, on_chunk),
    }
}

pub fn decodeAlloc(
    alloc: std.mem.Allocator,
    codec: Codec,
    stored: []const u8,
    payload_len: usize,
) ![]u8 {
    const payload = try alloc.alloc(u8, payload_len);
    errdefer alloc.free(payload);

    switch (codec) {
        .none => {
            if (stored.len != payload_len) return error.CorruptObject;
            @memcpy(payload, stored);
        },
    }

    return payload;
}

pub fn decodeStream(
    codec: Codec,
    raw_reader: *std.Io.Reader,
    buffer: []u8,
) !usize {
    return switch (codec) {
        .none => raw_reader.readSliceShort(buffer),
    };
}

fn encodeRaw(
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    payload_len: usize,
    on_chunk: *const fn ([]const u8) void,
) !void {
    var buf: [4096]u8 = undefined;
    var remaining = payload_len;
    while (remaining > 0) {
        const chunk = buf[0..@min(buf.len, remaining)];
        const n = try reader.readSliceShort(chunk);
        if (n == 0) return error.EndOfStream;

        const written = chunk[0..n];
        on_chunk(written);
        try writer.writeAll(written);
        remaining -= n;
    }
}

test "small payloads stay raw" {
    try std.testing.expectEqual(Codec.none, choose(32));
}

test "larger payloads stay raw until compression backend is stable" {
    try std.testing.expectEqual(Codec.none, choose(256));
}
