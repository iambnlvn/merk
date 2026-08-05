const std = @import("std");

pub const crypto = @import("crypto/crypto.zig");
pub const compression = @import("compression/compression.zig");
pub const merkle = @import("merkle/merkle.zig");

pub const io = struct {
    pub const vfs = @import("storage/vfs.zig");
    pub const os_fs = @import("storage/os_fs.zig").OsFs;
    pub const mem_fs = @import("storage/mem_fs.zig").MemoryFs;
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
