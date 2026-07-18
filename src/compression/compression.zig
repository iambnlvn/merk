const std = @import("std");

pub const Codec = enum(u8) {
    none = 0,
    /// Decode-only for now. std.compress.flate.Compress hangs on `.end()` /
    /// drain in Zig 0.15.2 for at least some inputs (unfinished upstream,
    /// fixed on master / targeted for 0.16 — see
    /// https://ziggit.dev/t/std-compress-flate-compress-nontermination/13692)
    /// Decompress is unaffected, so objects that already carry codec=zlib
    /// (e.g. migrated/imported data) decode correctly. `choose()` will never
    /// select this until CodecError.ZlibEncodeUnavailable is retired below
    zlib = 1,
};

pub const CodecError = error{
    /// encodeBody was asked for .zlib. See the Codec.zlib doc comment
    ZlibEncodeUnavailable,
    /// Decoded byte count didn't match the payload_len recorded in the
    /// object header — truncated/corrupt stream or a header/body mismatch
    CorruptObject,
};

pub const default_min_compress_len: usize = 96;

/// Window buffer size required by std.compress.flate.Decompress. Must be
/// non-zero and large enough for the format's history window, or you hit
/// the decompressor's buggy zero-length "direct" mode (separate upstream
/// issue: infinite loop on streamExact with an empty window buffer)
pub const zlib_window_len: usize = std.compress.flate.max_window_len;

/// Would compressing a payload of this size plausibly pay for itself?
pub fn wouldBenefitFromCompression(payload_len: usize) bool {
    return payload_len >= default_min_compress_len;
}

pub fn choose(payload_len: usize) Codec {
    _ = wouldBenefitFromCompression(payload_len);
    // Always .none today — zlib encode is disabled, see Codec.zlib
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
        .zlib => return CodecError.ZlibEncodeUnavailable,
    }
}

/// One-shot decode into a freshly allocated `payload_len`-byte buffer
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
            if (stored.len != payload_len) return CodecError.CorruptObject;
            @memcpy(payload, stored);
        },
        .zlib => {
            var window_buf: [zlib_window_len]u8 = undefined;
            var stored_reader: std.Io.Reader = .fixed(stored);
            var out_writer: std.Io.Writer = .fixed(payload);
            var decompress: std.compress.flate.Decompress =
                .init(&stored_reader, .zlib, &window_buf);

            // streamRemaining is a std.Io.Reader method, reached through the
            // .reader field — Decompress does not expose it directly.
            const n = decompress.reader.streamRemaining(&out_writer) catch |err| switch (err) {
                // out_writer is exactly payload_len bytes — a decompressed
                // stream that doesn't fit means the header lied about size.
                error.WriteFailed => return CodecError.CorruptObject,
                else => |e| return e,
            };
            if (n != payload_len) return CodecError.CorruptObject;
        },
    }

    return payload;
}

/// Fill `buffer` from the raw (uncompressed-on-the-wire) stream in a single
/// call — only meaningful for .none, since .zlib needs decompressor state
/// to persist *across* calls. Kept for callers that only ever see raw
/// bodies; anything that might be compressed should use `Decoder` instead.
pub fn decodeStream(
    codec: Codec,
    raw_reader: *std.Io.Reader,
    buffer: []u8,
) !usize {
    return switch (codec) {
        .none => raw_reader.readSliceShort(buffer),
        .zlib => error.NeedsStatefulDecoder,
    };
}

/// Stateful, multi-call decoder for a single object body. Construct once
/// per object with a window buffer that outlives it, then call `read`
/// repeatedly (same contract as `std.Io.Reader.readSliceShort`: returns the
/// number of bytes read, 0 at end of stream). Unlike `decodeStream`, this
/// correctly handles .zlib because the flate.Decompress state is preserved
/// between calls instead of being reconstructed from scratch each time.
pub const Decoder = union(Codec) {
    none: void,
    zlib: std.compress.flate.Decompress,

    pub fn init(codec: Codec, raw_reader: *std.Io.Reader, window_buf: []u8) Decoder {
        return switch (codec) {
            .none => .{ .none = {} },
            .zlib => .{ .zlib = .init(raw_reader, .zlib, window_buf) },
        };
    }

    pub fn read(self: *Decoder, raw_reader: *std.Io.Reader, buffer: []u8) !usize {
        return switch (self.*) {
            .none => raw_reader.readSliceShort(buffer),
            .zlib => |*d| d.reader.readSliceShort(buffer),
        };
    }
};

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

test "larger payloads also stay raw (zlib encode disabled pending upstream fix)" {
    try std.testing.expectEqual(Codec.none, choose(256));
}

test "wouldBenefitFromCompression threshold" {
    try std.testing.expect(!wouldBenefitFromCompression(default_min_compress_len - 1));
    try std.testing.expect(wouldBenefitFromCompression(default_min_compress_len));
}

test "encodeBody rejects zlib with a named error" {
    var reader: std.Io.Reader = .fixed("doesn't matter");
    var out_buf: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);
    const noop = struct {
        fn f(_: []const u8) void {}
    }.f;
    try std.testing.expectError(
        CodecError.ZlibEncodeUnavailable,
        encodeBody(&writer, &reader, 4, .zlib, &noop),
    );
}

test "none codec round-trips through encodeBody/decodeAlloc" {
    const plain = "the raw payload bytes";
    var reader: std.Io.Reader = .fixed(plain);
    var out_buf: [plain.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);

    var hashed_bytes: usize = 0;
    const counter = struct {
        var total: *usize = undefined;
        fn f(chunk: []const u8) void {
            total.* += chunk.len;
        }
    };
    counter.total = &hashed_bytes;

    try encodeBody(&writer, &reader, plain.len, .none, &counter.f);
    try std.testing.expectEqual(plain.len, hashed_bytes);

    const alloc = std.testing.allocator;
    const decoded = try decodeAlloc(alloc, .none, &out_buf, plain.len);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u8, plain, decoded);
}

test "decodeAlloc none rejects length mismatch" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        CodecError.CorruptObject,
        decodeAlloc(alloc, .none, "short", 999),
    );
}

test "decodeStream none reads raw bytes" {
    var reader: std.Io.Reader = .fixed("hello");
    var buf: [5]u8 = undefined;
    const n = try decodeStream(.none, &reader, &buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..n]);
}

test "decodeStream zlib refuses stateless use" {
    var reader: std.Io.Reader = .fixed("");
    var buf: [5]u8 = undefined;
    try std.testing.expectError(error.NeedsStatefulDecoder, decodeStream(.zlib, &reader, &buf));
}

// Reference vector: zlib.compress(b"the quick brown fox jumps over the lazy
// dog " * 4, 6) via Python's zlib module — an independent implementation,
// so a correct decode here is a real correctness check, not just a
// round-trip against our own (nonexistent) encoder.
const zlib_vector_plain =
    "the quick brown fox jumps over the lazy dog " ** 4;
const zlib_vector_compressed = [_]u8{
    0x78, 0x9c, 0x2b, 0xc9, 0x48, 0x55, 0x28, 0x2c, 0xcd, 0x4c, 0xce, 0x56,
    0x48, 0x2a, 0xca, 0x2f, 0xcf, 0x53, 0x48, 0xcb, 0xaf, 0x50, 0xc8, 0x2a,
    0xcd, 0x2d, 0x28, 0x56, 0xc8, 0x2f, 0x4b, 0x2d, 0x52, 0x28, 0x01, 0x4a,
    0xe7, 0x24, 0x56, 0x55, 0x2a, 0xa4, 0xe4, 0xa7, 0x83, 0x39, 0x03, 0xad,
    0x16, 0x00, 0x60, 0x2e, 0x40, 0x65,
};

test "decodeAlloc zlib matches an independently-produced reference vector" {
    const alloc = std.testing.allocator;
    const decoded = try decodeAlloc(
        alloc,
        .zlib,
        &zlib_vector_compressed,
        zlib_vector_plain.len,
    );
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u8, zlib_vector_plain, decoded);
}

test "decodeAlloc zlib rejects a payload_len that's too small" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        CodecError.CorruptObject,
        decodeAlloc(alloc, .zlib, &zlib_vector_compressed, zlib_vector_plain.len - 1),
    );
}

test "Decoder zlib streams the same reference vector across many small reads" {
    var window_buf: [zlib_window_len]u8 = undefined;
    var stored_reader: std.Io.Reader = .fixed(&zlib_vector_compressed);
    var decoder = Decoder.init(.zlib, &stored_reader, &window_buf);

    var out: [zlib_vector_plain.len]u8 = undefined;
    var got: usize = 0;
    while (got < out.len) {
        var chunk_buf: [7]u8 = undefined; // deliberately not aligned to input size
        const n = try decoder.read(&stored_reader, &chunk_buf);
        if (n == 0) break;
        @memcpy(out[got .. got + n], chunk_buf[0..n]);
        got += n;
    }
    try std.testing.expectEqual(zlib_vector_plain.len, got);
    try std.testing.expectEqualSlices(u8, zlib_vector_plain, out[0..got]);
}

test "Decoder none streams raw bytes across many small reads" {
    var stored_reader: std.Io.Reader = .fixed("streamed raw content, chunk by chunk");
    var decoder = Decoder.init(.none, &stored_reader, &.{});

    var out: [64]u8 = undefined;
    var got: usize = 0;
    while (true) {
        var chunk_buf: [3]u8 = undefined;
        const n = try decoder.read(&stored_reader, &chunk_buf);
        if (n == 0) break;
        @memcpy(out[got .. got + n], chunk_buf[0..n]);
        got += n;
    }
    try std.testing.expectEqualSlices(u8, "streamed raw content, chunk by chunk", out[0..got]);
}
