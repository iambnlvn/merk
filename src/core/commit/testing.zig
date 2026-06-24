const std = @import("std");

pub const MockReader = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn takeInt(self: *@This(), comptime T: type, endian: std.builtin.Endian) !T {
        const size = @sizeOf(T);
        if (self.pos + size > self.buffer.len) return error.EndOfStream;
        const bytes = self.buffer[self.pos .. self.pos + size][0..size];
        self.pos += size;
        return std.mem.readInt(T, bytes, endian);
    }

    pub fn take(self: *@This(), len: usize) ![]const u8 {
        if (self.pos + len > self.buffer.len) return error.EndOfStream;
        const slice = self.buffer[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }
};
