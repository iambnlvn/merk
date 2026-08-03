const std = @import("std");

pub const Context = struct {
    alloc: std.mem.Allocator,
    repo_root: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
};
