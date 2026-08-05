pub const vfs = @import("vfs.zig");
const os_fs_mod = @import("os_fs.zig");
const mem_fs_mod = @import("mem_fs.zig");

pub const Vfs = vfs.Vfs;
pub const FileSystem = Vfs;
pub const OsFs = os_fs_mod.OsFs;
pub const MemoryFs = mem_fs_mod.MemoryFs;
pub const RealFs = OsFs;
pub const TestFs = MemoryFs;

pub const os_fs = OsFs;
pub const mem_fs = MemoryFs;
