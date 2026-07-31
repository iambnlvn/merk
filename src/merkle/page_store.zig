const std = @import("std");
const hash_mod = @import("../crypto/crypto.zig").hash;
const node = @import("node.zig");
const io = @import("../storage/io.zig");

const Hash = hash_mod.Hash;
const Page = node.Page;

/// Manages persistent storage of fixed-size index pages.
/// Pages are stored in a sharded directory tree based on their hash, under
/// `pages_dir` (relative to `fs`'s root) — of the form
/// `<pages_dir>/xx/yy/<64-char-hex>`. Mirrors `object.Store`'s
/// `fs`/`objects_dir` shape so both storage layers are driven identically
/// in tests (`io.TestFs`) and in production (`io.RealFs`).
pub const PageStore = struct {
    alloc: std.mem.Allocator,
    fs: io.FileSystem,
    /// Directory pages live under, relative to `fs`'s root. May be ""
    /// if `fs` is already rooted at the pages directory itself
    pages_dir: []const u8,

    pub fn init(alloc: std.mem.Allocator, fs: io.FileSystem, pages_dir: []const u8) PageStore {
        return .{ .alloc = alloc, .fs = fs, .pages_dir = pages_dir };
    }

    pub fn put(self: *const PageStore, page_bytes: *const [node.PAGE_SIZE]u8) !Hash {
        const page_hash = hash_mod.blake3(page_bytes);
        const path = try self.pagePath(page_hash);
        defer self.alloc.free(path);

        // Fast path: page already exists (pages are content-addressed and
        // immutable, so no need to compare bytes, just presence)
        if (!try self.fs.fileExists(path)) {
            try self.fs.writeFile(self.alloc, path, page_bytes);
        }

        return page_hash;
    }

    /// Read a page from the store and verify its hash
    pub fn getBytes(self: *const PageStore, page_hash: Hash) ![node.PAGE_SIZE]u8 {
        const path = try self.pagePath(page_hash);
        defer self.alloc.free(path);

        const raw = (try self.fs.readFile(self.alloc, path)) orelse return error.NotFound;
        defer self.alloc.free(raw);

        if (raw.len != node.PAGE_SIZE) return error.CorruptIndexPage;

        var bytes: [node.PAGE_SIZE]u8 = undefined;
        @memcpy(&bytes, raw[0..node.PAGE_SIZE]);

        const computed = hash_mod.blake3(&bytes);
        if (!node.hashEq(computed, page_hash)) return error.HashMismatch;
        return bytes;
    }

    /// Parse a page from disk into an in-memory representation
    pub fn get(self: *const PageStore, page_hash: Hash) !Page {
        const bytes = try self.getBytes(page_hash);
        return node.parsePage(self.alloc, &bytes);
    }

    fn pagePath(self: *const PageStore, page_hash: Hash) ![]u8 {
        var hex_buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{page_hash}) catch unreachable;

        if (self.pages_dir.len == 0) {
            return std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}", .{ hex[0..2], hex[2..4], hex });
        }
        return std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}/{s}", .{ self.pages_dir, hex[0..2], hex[2..4], hex });
    }
};

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
        .blob_hash = hash_mod.zero_hash,
        .size = 0,
        .mode = 0o644,
        .mtime = 0,
    }) catch unreachable;
    return page;
}

test "put+get round-trips page bytes" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = PageStore.init(alloc, tfs.fs(), "index/pages");

    const page = testPage(0xAB);
    const h = try store.put(&page);
    const back = try store.getBytes(h);
    try std.testing.expectEqualSlices(u8, &page, &back);
}

test "put is idempotent — writing identical content twice yields the same hash and one file" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = PageStore.init(alloc, tfs.fs(), "index/pages");

    const page = testPage(0x11);
    const h1 = try store.put(&page);
    const h2 = try store.put(&page);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
    try std.testing.expectEqual(@as(usize, 1), tfs.fileCount());
}

test "get on an unknown hash returns NotFound" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = PageStore.init(alloc, tfs.fs(), "index/pages");

    try std.testing.expectError(error.NotFound, store.getBytes(hash_mod.zero_hash));
}

test "getBytes detects on-disk corruption via content hash mismatch" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = PageStore.init(alloc, tfs.fs(), "index/pages");

    const page = testPage(0x22);
    const h = try store.put(&page);

    // Tamper with the stored bytes directly, bypassing PageStore, to
    // simulate corruption/bit rot after the page was written.
    var hex_buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{h}) catch unreachable;
    const path = try std.fmt.allocPrint(alloc, "index/pages/{s}/{s}/{s}", .{ hex[0..2], hex[2..4], hex });
    defer alloc.free(path);

    const original = (try tfs.fs().readFile(alloc, path)).?;
    defer alloc.free(original);
    const tampered = try alloc.dupe(u8, original);
    defer alloc.free(tampered);
    tampered[0] ^= 0xFF;
    try tfs.fs().writeFile(alloc, path, tampered);

    try std.testing.expectError(error.HashMismatch, store.getBytes(h));
}

test "getBytes rejects a page file of the wrong size as corrupt" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = PageStore.init(alloc, tfs.fs(), "index/pages");

    // Fabricate an undersized "page" directly, bypassing PageStore.put,
    // to simulate a truncated write
    var hex_buf: [64]u8 = undefined;
    const bogus_hash = hash_mod.blake3("short content");
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{bogus_hash}) catch unreachable;
    const path = try std.fmt.allocPrint(alloc, "index/pages/{s}/{s}/{s}", .{ hex[0..2], hex[2..4], hex });
    defer alloc.free(path);
    try tfs.fs().writeFile(alloc, path, "not a full page");

    try std.testing.expectError(error.CorruptIndexPage, store.getBytes(bogus_hash));
}

test "get parses page bytes into a structured Page" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = PageStore.init(alloc, tfs.fs(), "index/pages");

    const page = testParseableLeafPage();
    const h = try store.put(&page);
    var parsed = try store.get(h);
    defer parsed.deinit(alloc);

    try std.testing.expect(parsed == .leaf);
    try std.testing.expectEqual(@as(usize, 1), parsed.leaf.items.len);
    try std.testing.expectEqualStrings("only.txt", parsed.leaf.items[0].path);
}

test "PageStore works with an empty pages_dir (fs already rooted there)" {
    const alloc = std.testing.allocator;
    var tfs = io.TestFs.init(alloc);
    defer tfs.deinit();
    const store = PageStore.init(alloc, tfs.fs(), "");

    const page = testPage(0x33);
    const h = try store.put(&page);
    const back = try store.getBytes(h);
    try std.testing.expectEqualSlices(u8, &page, &back);
}

test "RealFs: put+get round-trips page bytes on real disk" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_fs = io.RealFs.init(tmp.dir);
    const store = PageStore.init(alloc, real_fs.fs(), "index/pages");

    const page = testPage(0xCD);
    const h = try store.put(&page);
    const back = try store.getBytes(h);
    try std.testing.expectEqualSlices(u8, &page, &back);
}
