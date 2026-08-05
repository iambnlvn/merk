const std = @import("std");
const testing = std.testing;
const native_fs = std.fs;
pub const Dir = native_fs.Dir;

const Allocator = std.mem.Allocator;

/// Composite error set representing all possible failure modes across
/// diverse backend implementations, ensuring future-proof error handling.
pub const VfsError = error{
    FileNotFound,
    FileTooBig,
    PathAlreadyExists,
    AccessDenied,
    Unexpected,
} || native_fs.File.OpenError || native_fs.File.ReadError || native_fs.File.WriteError || native_fs.File.SeekError || native_fs.Dir.StatFileError || native_fs.Dir.DeleteFileError || native_fs.Dir.RenameError || Allocator.Error || native_fs.Dir.MakeError || native_fs.Dir.Iterator.Error;

pub const Vfs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Default safety cap for full-file reads (1 GiB) to prevent
    /// runaway memory allocations on unexpectedly massive files.
    pub const default_max_read_size: usize = 1 << 30;

    /// Virtual method table defining the required backend driver functions.
    pub const VTable = struct {
        readFile: *const fn (ptr: *anyopaque, alloc: Allocator, path: []const u8, max_size: usize) VfsError!?[]u8,
        readRange: *const fn (ptr: *anyopaque, alloc: Allocator, path: []const u8, offset: u64, len: usize) VfsError!?[]u8,
        writeFile: *const fn (ptr: *anyopaque, alloc: Allocator, path: []const u8, contents: []const u8) VfsError!void,
        openStream: *const fn (ptr: *anyopaque, alloc: Allocator, path: []const u8) VfsError!?FileStream,
        deleteFile: *const fn (ptr: *anyopaque, path: []const u8) VfsError!void,
        fileExists: *const fn (ptr: *anyopaque, path: []const u8) VfsError!bool,
        statFile: *const fn (ptr: *anyopaque, path: []const u8) VfsError!?FileStat,
        renameFile: *const fn (ptr: *anyopaque, old_path: []const u8, new_path: []const u8) VfsError!void,
        copyFile: *const fn (ptr: *anyopaque, old_path: []const u8, new_path: []const u8) VfsError!void,
        deleteDir: *const fn (ptr: *anyopaque, dir_path: []const u8) VfsError!void,
        listFiles: *const fn (ptr: *anyopaque, alloc: Allocator, dir_path: []const u8) VfsError![][]u8,
    };

    /// Reads an entire file into memory using the default size limit.
    /// Returns `null` if the file does not exist.
    pub fn readFile(self: Vfs, alloc: Allocator, path: []const u8) !?[]u8 {
        return self.vtable.readFile(self.ptr, alloc, path, default_max_read_size);
    }

    /// Reads an entire file into memory enforced by a custom maximum byte limit.
    pub fn readFileLimit(self: Vfs, alloc: Allocator, path: []const u8, max_size: usize) !?[]u8 {
        return self.vtable.readFile(self.ptr, alloc, path, max_size);
    }

    /// Reads a precise byte range from a file starting at the given offset.
    pub fn readRange(self: Vfs, alloc: Allocator, path: []const u8, offset: u64, len: usize) !?[]u8 {
        return self.vtable.readRange(self.ptr, alloc, path, offset, len);
    }

    /// Writes contents to a file at the specified path, creating missing parent directories.
    pub fn writeFile(self: Vfs, alloc: Allocator, path: []const u8, contents: []const u8) !void {
        return self.vtable.writeFile(self.ptr, alloc, path, contents);
    }

    /// Opens a sequential stream handle for reading large files incrementally.
    pub fn openStream(self: Vfs, alloc: Allocator, path: []const u8) !?FileStream {
        return self.vtable.openStream(self.ptr, alloc, path);
    }

    /// Deletes a file at the designated path.
    pub fn deleteFile(self: Vfs, path: []const u8) !void {
        return self.vtable.deleteFile(self.ptr, path);
    }

    /// Checks whether a file exists at the given path.
    pub fn fileExists(self: Vfs, path: []const u8) !bool {
        return self.vtable.fileExists(self.ptr, path);
    }

    /// Retrieves file metadata (size and modification timestamp) without loading contents.
    pub fn statFile(self: Vfs, path: []const u8) !?FileStat {
        return self.vtable.statFile(self.ptr, path);
    }

    /// Renames or moves a file from an old path to a new path.
    pub fn renameFile(self: Vfs, old_path: []const u8, new_path: []const u8) !void {
        return self.vtable.renameFile(self.ptr, old_path, new_path);
    }

    /// Copies a file from an existing path to a destination path.
    pub fn copyFile(self: Vfs, old_path: []const u8, new_path: []const u8) !void {
        return self.vtable.copyFile(self.ptr, old_path, new_path);
    }

    /// Recursively deletes an entire directory tree.
    pub fn deleteDir(self: Vfs, dir_path: []const u8) !void {
        return self.vtable.deleteDir(self.ptr, dir_path);
    }

    /// Recursively lists all file paths contained within a directory.
    pub fn listFiles(self: Vfs, alloc: Allocator, dir_path: []const u8) ![][]u8 {
        return self.vtable.listFiles(self.ptr, alloc, dir_path);
    }
};

/// A sequential streaming handle abstraction for reading files chunk-by-chunk.
pub const FileStream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, buffer: []u8) VfsError!usize,
        close: *const fn (ptr: *anyopaque) void,
    };

    /// Reads data from the active stream into the provided buffer.
    pub fn read(self: FileStream, buffer: []u8) VfsError!usize {
        return self.vtable.read(self.ptr, buffer);
    }

    /// Closes the stream and releases any allocated handle resources.
    pub fn close(self: FileStream) void {
        self.vtable.close(self.ptr);
    }

    /// Standard library compatibility reader type.
    pub const Reader = std.Io.Reader(FileStream, VfsError, readImpl);

    /// Wraps the stream into a standard library `std.Io.Reader` for high-level parsing utilities.
    pub fn reader(self: FileStream) Reader {
        return .{ .context = self };
    }

    fn readImpl(self: FileStream, buffer: []u8) VfsError!usize {
        return self.read(buffer);
    }
};

/// Represents core metadata fields for a file.
pub const FileStat = struct {
    size: u64,
    mtime_ns: i128,
};

/// Shared test suite used to validate structural conformance across different
/// VFS backend implementations
pub fn runVfsTests(fs: Vfs, alloc: Allocator) !void {
    // Write and Read
    const test_path = "subdir/test_file.txt";
    const content = "Hello, Merk VFS!";

    try fs.writeFile(alloc, test_path, content);

    const read_back = try fs.readFile(alloc, test_path);
    try testing.expect(read_back != null);
    defer alloc.free(read_back.?);
    try testing.expectEqualStrings(content, read_back.?);

    // File Existence
    try testing.expect(try fs.fileExists(test_path));
    try testing.expect(!try fs.fileExists("nonexistent.txt"));

    // Stat Metadata
    const stat = try fs.statFile(test_path);
    try testing.expect(stat != null);
    try testing.expectEqual(@as(u64, content.len), stat.?.size);

    // Range Reads
    const range = try fs.readRange(alloc, test_path, 7, 5); // Should read "Merk "
    try testing.expect(range != null);
    defer alloc.free(range.?);
    try testing.expectEqualStrings("Merk ", range.?);

    // Copy and Rename
    try fs.copyFile(test_path, "subdir/copy.txt");
    try testing.expect(try fs.fileExists("subdir/copy.txt"));

    try fs.renameFile("subdir/copy.txt", "subdir/renamed.txt");
    try testing.expect(!try fs.fileExists("subdir/copy.txt"));
    try testing.expect(try fs.fileExists("subdir/renamed.txt"));

    // Listing Files
    const files = try fs.listFiles(alloc, "subdir");
    defer {
        for (files) |f| alloc.free(f);
        alloc.free(files);
    }
    try testing.expectEqual(@as(usize, 2), files.len);

    // Deletion
    try fs.deleteFile(test_path);
    try testing.expect(!try fs.fileExists(test_path));
}
