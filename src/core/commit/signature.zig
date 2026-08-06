//! NOTE: merk doesn't verify signatures itself; it stores and returns
//! them opaquely so external tooling (a keyring-aware CLI, `merk
//! verify`, CI policy checks, ...) can do that against whatever
//! keyring it trusts.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wire = @import("wire.zig");
const testing_io = @import("testing.zig");

pub const SignatureError = error{
    EmptyKeyId,
    KeyIdTooLong,
    EmptySignatureBytes,
    SignatureBytesTooLong,
};

/// Which cryptographic scheme produced the signature bytes.
pub const SignatureAlgorithm = enum(u8) {
    ssh_ed25519 = 0,
    ssh_rsa = 1,
    pgp_rsa = 2,
    pgp_ed25519 = 3,
};

pub const SignatureInfo = struct {
    algorithm: SignatureAlgorithm,

    /// Raw signature bytes, in whatever encoding `algorithm` produces
    /// (e.g. an SSH SIGNATURE blob, a detached OpenPGP signature).
    bytes: []const u8,

    /// Fingerprint / key ID / certificate footprint identifying the
    /// signing key. Opaque to merk, just enough for a verifier to know
    /// which key to check against.
    key_id: []const u8,

    pub fn validate(self: SignatureInfo) SignatureError!void {
        if (self.key_id.len == 0) return error.EmptyKeyId;
        if (self.key_id.len > std.math.maxInt(u8)) return error.KeyIdTooLong;
        if (self.bytes.len == 0) return error.EmptySignatureBytes;
        if (self.bytes.len > std.math.maxInt(u32)) return error.SignatureBytesTooLong;
    }

    pub fn serialize(self: SignatureInfo, writer: *Io.Writer) !void {
        try self.validate();
        try writer.writeByte(@intFromEnum(self.algorithm));
        try wire.writeBytes(u8, writer, self.key_id);
        try wire.writeBytes(u32, writer, self.bytes);
    }
};

/// An owned, deep-copied signature as read back from storage. Free with
/// `.deinit`.
pub const Signature = struct {
    algorithm: SignatureAlgorithm,
    bytes: []u8,
    key_id: []u8,

    pub fn deserialize(alloc: Allocator, reader: *Io.Reader) !Signature {
        const raw_algorithm = try reader.takeByte();
        const algorithm = std.meta.intToEnum(SignatureAlgorithm, raw_algorithm) catch
            return error.CorruptSignature;

        const key_id = try wire.readBytesAlloc(u8, alloc, reader);
        errdefer alloc.free(key_id);

        const bytes = try wire.readBytesAlloc(u32, alloc, reader);
        errdefer alloc.free(bytes);

        const info = SignatureInfo{ .algorithm = algorithm, .bytes = bytes, .key_id = key_id };
        try info.validate();

        return .{ .algorithm = algorithm, .bytes = bytes, .key_id = key_id };
    }

    pub fn deinit(self: *Signature, alloc: Allocator) void {
        alloc.free(self.bytes);
        alloc.free(self.key_id);
        self.* = undefined;
    }
};

test "SignatureInfo validation rejects empty key id and empty bytes" {
    const missing_key = SignatureInfo{ .algorithm = .ssh_ed25519, .bytes = "sig", .key_id = "" };
    try testing.expectError(error.EmptyKeyId, missing_key.validate());

    const missing_bytes = SignatureInfo{ .algorithm = .ssh_ed25519, .bytes = "", .key_id = "SHA256:abc" };
    try testing.expectError(error.EmptySignatureBytes, missing_bytes.validate());
}

test "SignatureInfo serialize/deserialize round-trip" {
    const alloc = testing.allocator;
    const info = SignatureInfo{
        .algorithm = .pgp_ed25519,
        .bytes = "not-a-real-signature-blob",
        .key_id = "0xDEADBEEF",
    };

    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();
    try info.serialize(sink.writer());

    var reader = testing_io.fixedReader(sink.bytes());
    var sig = try Signature.deserialize(alloc, &reader);
    defer sig.deinit(alloc);

    try testing.expectEqual(SignatureAlgorithm.pgp_ed25519, sig.algorithm);
    try testing.expectEqualStrings("not-a-real-signature-blob", sig.bytes);
    try testing.expectEqualStrings("0xDEADBEEF", sig.key_id);
}

test "Signature deserialize rejects an out-of-range algorithm byte" {
    const alloc = testing.allocator;
    var sink = testing_io.ByteSink.init(alloc);
    defer sink.deinit();

    try sink.writer().writeByte(200); // not a valid SignatureAlgorithm
    try wire.writeBytes(u8, sink.writer(), "key");
    try wire.writeBytes(u32, sink.writer(), "sig");

    var reader = testing_io.fixedReader(sink.bytes());
    try testing.expectError(error.CorruptSignature, Signature.deserialize(alloc, &reader));
}
