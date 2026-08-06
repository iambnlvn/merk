pub const vfs = @import("vfs.zig");
const os_fs_mod = @import("os_fs.zig");
const mem_fs_mod = @import("mem_fs.zig");

pub const Vfs = vfs.Vfs;
pub const OsFs = os_fs_mod.OsFs;
pub const MemoryFs = mem_fs_mod.MemoryFs;
