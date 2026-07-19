const std = @import("std");
const hash_mod = @import("merk").hash;
const node = @import("node.zig");

const Hash = hash_mod.Hash;
const Page = node.Page;

/// Layout constants for page paths (hex-encoded BLAKE3 hashes), of the form
/// `index/pages/xx/yy/<64-char-hex>`
const PAGE_REL_PATH_LEN: usize = 11 + 1 + 2 + 1 + 2 + 1 + 64;
const PAGE_DIR_PATH_LEN: usize = 11 + 1 + 2 + 1 + 2;

/// Manages persistent storage of fixed-size index pages
/// Pages are stored in a sharded directory tree based on their hash
pub const PageStore = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,

    /// Ensure the pages directory exists.
    pub fn ensure(self: *const PageStore) !void {
        try self.dir.makePath("index/pages");
        try self.dir.makePath(".tmp");
    }

    pub fn put(self: *const PageStore, page_bytes: *const [node.PAGE_SIZE]u8) !Hash {
        try self.ensure();

        const page_hash = hash_mod.blake3(page_bytes);
        var path_buf: [PAGE_REL_PATH_LEN]u8 = undefined;
        const path = pageRelPath(&path_buf, page_hash);

        // Fast path: page already exists.
        if (self.dir.access(path, .{})) |_| {
            return page_hash;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        // Write to a temporary file and rename for atomicity
        var rand_buf: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        const tmp_path = try std.fmt.allocPrint(self.alloc, ".tmp/{x}.idx", .{rand_buf});
        defer self.alloc.free(tmp_path);

        var file = try self.dir.createFile(tmp_path, .{});
        var file_closed = false;
        defer if (!file_closed) file.close();
        errdefer {
            if (!file_closed) {
                file.close();
                file_closed = true;
            }
            self.dir.deleteFile(tmp_path) catch {};
        }

        try file.writeAll(page_bytes);
        try file.sync();
        file.close();
        file_closed = true;

        // Rename into place, creating parent directories if necessary
        var dir_buf: [PAGE_DIR_PATH_LEN]u8 = undefined;
        const dir_path = pageDirPath(&dir_buf, page_hash);
        self.dir.rename(tmp_path, path) catch |err| switch (err) {
            error.FileNotFound => {
                try self.dir.makePath(dir_path);
                try self.dir.rename(tmp_path, path);
            },
            error.PathAlreadyExists => {
                self.dir.deleteFile(tmp_path) catch {};
            },
            else => return err,
        };

        return page_hash;
    }

    /// Read a page from the store and verify its hash
    pub fn getBytes(self: *const PageStore, page_hash: Hash) ![node.PAGE_SIZE]u8 {
        var path_buf: [PAGE_REL_PATH_LEN]u8 = undefined;
        const path = pageRelPath(&path_buf, page_hash);

        const file = self.dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return err,
        };
        defer file.close();

        var bytes: [node.PAGE_SIZE]u8 = undefined;
        var reader_buf: [node.PAGE_SIZE]u8 = undefined;
        var file_reader = file.readerStreaming(&reader_buf);
        @memcpy(&bytes, try file_reader.interface.take(node.PAGE_SIZE));

        const computed = hash_mod.blake3(&bytes);
        if (!node.hashEq(computed, page_hash)) return error.HashMismatch;
        return bytes;
    }

    /// Parse a page from disk into an in-memory representation
    pub fn get(self: *const PageStore, page_hash: Hash) !Page {
        const bytes = try self.getBytes(page_hash);
        return node.parsePage(self.alloc, &bytes);
    }
};

fn pageRelPath(buf: *[PAGE_REL_PATH_LEN]u8, page_hash: Hash) []const u8 {
    var hex_buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{page_hash}) catch unreachable;
    return std.fmt.bufPrint(buf, "index/pages/{s}/{s}/{s}", .{
        hex[0..2],
        hex[2..4],
        hex,
    }) catch unreachable;
}

fn pageDirPath(buf: *[PAGE_DIR_PATH_LEN]u8, page_hash: Hash) []const u8 {
    var hex_buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{page_hash}) catch unreachable;
    return std.fmt.bufPrint(buf, "index/pages/{s}/{s}", .{
        hex[0..2],
        hex[2..4],
    }) catch unreachable;
}

/// A page with valid header bytes but arbitrary (non-parseable) trailing
/// content — fine for the byte-level tests below, which never ask
/// PageStore to parse it, only to store/retrieve/verify the raw bytes.
fn testPage(fill: u8) [node.PAGE_SIZE]u8 {
    var page: [node.PAGE_SIZE]u8 = [_]u8{fill} ** node.PAGE_SIZE;
    node.writePageHeader(&page, node.LEAF_PAGE, 0);
    return page;
}

/// A minimal but genuinely valid, parseable single-entry leaf page.
fn testParseableLeafPage() [node.PAGE_SIZE]u8 {
    var page: [node.PAGE_SIZE]u8 = [_]u8{0} ** node.PAGE_SIZE;
    node.writePageHeader(&page, node.LEAF_PAGE, 1);
    var writer = std.Io.Writer.fixed(page[node.LEAF_HEADER_LEN..]);
    node.writeLeafEntry(&writer, .{
        .key = 1,
        .path = @constCast("only.txt"),
        .blob_hash = hash_mod.ZERO_HASH,
        .size = 0,
        .mode = 0o644,
        .mtime = 0,
    }) catch unreachable;
    return page;
}

test "put+get round-trips page bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = PageStore{ .alloc = std.testing.allocator, .dir = tmp.dir };

    const page = testPage(0xAB);
    const h = try store.put(&page);
    const back = try store.getBytes(h);
    try std.testing.expectEqualSlices(u8, &page, &back);
}

test "put is idempotent — writing identical content twice yields the same hash and one file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = PageStore{ .alloc = std.testing.allocator, .dir = tmp.dir };

    const page = testPage(0x11);
    const h1 = try store.put(&page);
    const h2 = try store.put(&page);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "get on an unknown hash returns NotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = PageStore{ .alloc = std.testing.allocator, .dir = tmp.dir };

    try std.testing.expectError(error.NotFound, store.getBytes(hash_mod.ZERO_HASH));
}

test "getBytes detects on-disk corruption via content hash mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = PageStore{ .alloc = std.testing.allocator, .dir = tmp.dir };

    const page = testPage(0x22);
    const h = try store.put(&page);

    // Flip a byte directly on disk, bypassing PageStore, to simulate
    // corruption/bit rot after the page was written.
    var path_buf: [PAGE_REL_PATH_LEN]u8 = undefined;
    const path = pageRelPath(&path_buf, h);
    var file = try tmp.dir.openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.seekTo(0);
    try file.writeAll(&.{0xFF});

    try std.testing.expectError(error.HashMismatch, store.getBytes(h));
}

test "get parses page bytes into a structured Page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = PageStore{ .alloc = std.testing.allocator, .dir = tmp.dir };

    const page = testParseableLeafPage();
    const h = try store.put(&page);
    var parsed = try store.get(h);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed == .leaf);
    try std.testing.expectEqual(@as(usize, 1), parsed.leaf.items.len);
    try std.testing.expectEqualStrings("only.txt", parsed.leaf.items[0].path);
}
