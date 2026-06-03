const std = @import("std");
const nodus = @import("nodus");

pub const Context = struct {
    alloc: std.mem.Allocator,
    repo_root: []const u8,
};
