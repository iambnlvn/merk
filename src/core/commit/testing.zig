//! There are exactly two recurring needs in those tests: a growable
//! in-memory sink to serialize into, and a fixed-buffer source to
//! deserialize back out of. Both already exist on `std.Io` — this file
//! adds no protocol of its own, it just gives call sites short, named
//! wrappers instead of re-deriving the `Io.Writer.Allocating` /
//! `Io.Reader.fixed` boilerplate at every test.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A growable in-memory `Io.Writer` for a test to serialize into.
///
///     var sink = ByteSink.init(alloc);
///     defer sink.deinit();
///     try value.serialize(sink.writer());
///     try testing.expectEqualSlices(u8, expected, sink.bytes());
pub const ByteSink = struct {
    allocating: Io.Writer.Allocating,

    pub fn init(alloc: Allocator) ByteSink {
        return .{ .allocating = Io.Writer.Allocating.init(alloc) };
    }

    pub fn deinit(self: *ByteSink) void {
        self.allocating.deinit();
    }

    /// The writer to pass into a `serialize` call. Borrows from `self`;
    /// valid only until the next call to `.deinit()`.
    pub fn writer(self: *ByteSink) *Io.Writer {
        return &self.allocating.writer;
    }

    /// Borrows from `self`.
    pub fn bytes(self: *ByteSink) []const u8 {
        return self.allocating.written();
    }
};

/// A fixed-buffer `Io.Reader` over `bytes`, for a test to deserialize
/// from. `bytes` must outlive the returned reader.
pub fn fixedReader(bytes: []const u8) Io.Reader {
    return Io.Reader.fixed(bytes);
}
