const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const crypto = @import("crypto");
const storage = @import("storage");
const merkle_mod = @import("merkle");

const Store = @import("object.zig").Store;
const ComponentDir = @import("./staging/repo_paths.zig").ComponentDir;

const Vfs = storage.Vfs;
const MemoryFs = storage.MemoryFs;
const OsFs = storage.OsFs;
const Hash = crypto.Hash;
const Entry = merkle_mod.Entry;
const WorktreeState = merkle_mod.WorktreeState;

pub const EntryIndex = @import("./staging/entry_index.zig").EntryIndex;

/// The staging area: tracks files staged for the next commit.
// NOTE:
/// Deliberately holds no Merkle tree and no page store of its own.
/// Earlier versions built and persisted a tree on every `save()`, into a
/// private "staging/pages" directory separate from the repository's
/// permanent "index/pages" store. That meant a staged tree's hash was
/// only ever resolvable in the store it was built into — committing had
/// to remember to re-materialize it into the permanent store, and any
/// path that forgot (or that read a staged hash before that step ran)
/// hit `error.NotFound` looking up pages that only existed in the other
/// store.
///
/// A flat, in-memory (persisted as a plain list, not a tree) entry list
/// removes the hazard entirely: there is nothing here that can be valid
/// in one store and missing from another, because nothing here is
/// store-addressed at all. The one Merkle tree Merk ever needs from
/// staged content is built on demand — directly into the repository's
/// shared, permanent `PageStore` — at the two moments that actually need
/// a hash: committing, and diffing staged vs. HEAD (see
/// `Repository.stagingTreeRoot`, `Repository.commit`, `Repository.status`
/// in repo.zig). Because pages are content-addressed, rebuilding the same
/// entries repeatedly is cheap — `PageStore.put` skips any page that's
/// already on disk — so there's no real cost to never caching the root
/// here.
///
/// On-disk layout, rooted at `staging_dir`:
/// ```md
/// staging/
/// └── entries   <- flat, length-prefixed serialization of the entry list
/// ```
///
/// PERSISTENCE SAFETY: `save()` writes to a sibling temp file and renames
/// it over `entries`, so a crash or write failure mid-save can never leave
/// a truncated/corrupt `entries` file behind — see `save()` below. This
/// assumes `Vfs` exposes `rename` and `deleteFile`; if the concrete `Vfs`
/// backing a given `Staging` doesn't implement them yet, add them there
/// rather than reverting to a direct, non-atomic `writeFile`.
///
/// CONCURRENCY NOTE: `save()` takes an advisory lock (a sibling
/// `entries.lock`, written and deleted around the write — see
/// `saveInternal`) around the write itself, so two processes racing a
/// `save()` usually get a clear `error.StagingLocked` instead of one
/// silently clobbering the other's write. It's check-then-write, not a
/// true atomic exclusive-create (`Vfs` doesn't expose one), so a narrow
/// race remains where both processes can pass the check before either
/// writes the lock — this narrows the existing hazard, it doesn't close
/// it outright. `load()` still takes no lock at all, and nothing here
/// serializes a full load-mutate-save cycle across processes (a
/// `load()` in one process can still interleave with a `save()` in
/// another). Full read/write serialization across the cycle is a
/// bigger design question, left open.
///
/// In-memory bookkeeping — the sorted entry list and the path -> index
pub const Staging = struct {
    alloc: Allocator,
    fs: Vfs,
    /// Where the staging area's on-disk state (the `entries` file)
    /// lives, relative to `fs`'s root. Typically ".merk/staging" when
    /// `fs` is rooted at the repo root.
    dir: ComponentDir,
    index: EntryIndex,
    /// Cached result of `dir.join(alloc, "entries")`. `dir` never
    /// changes after `init`, so there's no reason to rejoin+reallocate
    /// this path on every single `load()`/`save()` call — computed
    /// lazily on first use (via `entriesPath`) and freed in `deinit`.
    entries_path: ?[]u8 = null,
    /// Set on every mutation (`addFile`/`put`/`remove`/`replaceAll`),
    /// cleared by `load()` and by a successful `save()`. Lets `save()`
    /// skip the write (and the rename/lock syscalls that go with it)
    /// when nothing has changed since the last load or save -- useful
    /// since `Repository.commit`/`status` can end up calling into
    /// staging repeatedly within one CLI invocation.
    dirty: bool = false,

    pub fn init(alloc: Allocator, fs: Vfs, staging_dir: []const u8) Staging {
        return .{
            .alloc = alloc,
            .fs = fs,
            .dir = ComponentDir.init(staging_dir),
            .index = EntryIndex.init(alloc),
        };
    }

    pub fn deinit(self: *Staging) void {
        self.index.deinit();
        if (self.entries_path) |p| self.alloc.free(p);
    }

    /// Returns the (cached) path to the `entries` file, computing and
    /// caching it on first call.
    fn entriesPath(self: *Staging) ![]const u8 {
        if (self.entries_path) |p| return p;
        const p = try self.dir.join(self.alloc, "entries");
        self.entries_path = p;
        return p;
    }

    /// Load the staging area from disk. If none exists yet, starts empty.
    ///
    /// All-or-nothing: parsing happens into a scratch `EntryIndex` first.
    /// `self.index` is only replaced once the entire file has parsed
    /// cleanly (well-formed bytes, every path validated, no duplicate
    /// paths) — a load that fails partway through leaves `self.index`
    /// exactly as it was before the call, never half-populated with
    /// entries that are in `allEntries()` but unreachable via `lookup()`.
    pub fn load(self: *Staging) !void {
        const entries_path = try self.entriesPath();

        const bytes = (try self.fs.readFile(self.alloc, entries_path)) orelse {
            // Nothing on disk yet — ensure in-memory state is consistent.
            self.index.clear();
            try self.index.sortAndReindex();
            self.dirty = false;
            return;
        };
        defer self.alloc.free(bytes);

        var scratch = EntryIndex.init(self.alloc);
        errdefer scratch.deinit();

        try deserializeEntries(self.alloc, bytes, &scratch);
        try scratch.sortAndReindex();

        // Only swap the parsed result in once it's fully valid — nothing
        // above this line has touched `self.index`.
        self.index.deinit();
        self.index = scratch;
        // Freshly loaded from disk: in-memory state matches what's
        // persisted, so there's nothing for a subsequent save() to do
        // until the next mutation.
        self.dirty = false;
    }

    /// Persist the current entries to disk as a flat list. No Merkle
    /// tree is built or written here — see the type doc comment above.
    ///
    /// Writes to a temp file and renames over `entries` so a crash or
    /// write failure can't leave a truncated/corrupt `entries` file on
    /// disk — the old file (or the new one) always survives intact,
    /// never a half-written mix of the two. Mirrors the
    /// write-temp-then-rename pattern `writeBlobToWorktree` uses for
    /// worktree content in `repo.zig`.
    pub fn save(self: *Staging) !void {
        try self.saveInternal(false);
    }

    /// Write even if `dirty` is false. Exists for callers that need a
    /// guaranteed on-disk write regardless of in-memory bookkeeping
    /// (currently just `replaceAll`, which always persists its result
    /// even when replacing empty-with-empty) — ordinary callers should
    /// use `save()`.
    fn forceSave(self: *Staging) !void {
        try self.saveInternal(true);
    }

    fn saveInternal(self: *Staging, force: bool) !void {
        if (!force and !self.dirty) return;

        // Ensure path-sorted order for deterministic output and path_index consistency.
        try self.index.sortAndReindex();

        const bytes = try serializeEntries(self.alloc, self.index.allEntries());
        defer self.alloc.free(bytes);

        const entries_path = try self.entriesPath();

        // Advisory lock: a sibling `entries.lock`, mirroring git's
        // `index.lock`. Best-effort with the `Vfs` primitives this file
        // already relies on (`readFile`/`writeFile`/`deleteFile`) —
        // check-then-write, not a true atomic exclusive-create, so
        // there's a narrow window where two processes can both pass the
        // check before either writes the lock. Still turns the ordinary
        // case (an obviously still-running, or crashed-and-abandoned,
        // `merk` process) into a loud `error.StagingLocked` instead of
        // silent clobbering, with no new `Vfs` surface required. If
        // `Vfs` ever grows a real exclusive-create primitive, swap this
        // for that instead of the check-then-write race.
        //
        // No staleness policy — a lock left behind by a crashed process
        // must be removed by hand (or by the CLI on the user's
        // confirmation), same as git's own guidance for a stale
        // `index.lock`.
        const lock_path = try std.fmt.allocPrint(self.alloc, "{s}.lock", .{entries_path});
        defer self.alloc.free(lock_path);

        if (try self.fs.readFile(self.alloc, lock_path)) |existing| {
            self.alloc.free(existing);
            return error.StagingLocked;
        }
        try self.fs.writeFile(self.alloc, lock_path, "");
        defer self.fs.deleteFile(lock_path) catch {};

        const tmp_path = try std.fmt.allocPrint(
            self.alloc,
            "{s}.merk-tmp-{d}",
            .{ entries_path, std.time.nanoTimestamp() },
        );
        defer self.alloc.free(tmp_path);

        try self.fs.writeFile(self.alloc, tmp_path, bytes);
        errdefer self.fs.deleteFile(tmp_path) catch {};

        try self.fs.renameFile(tmp_path, entries_path);

        self.dirty = false;
    }

    /// Look up a staged entry by its repository-relative path.
    pub fn lookup(self: *const Staging, path: []const u8) ?Entry {
        return self.index.lookup(path);
    }

    /// Remove a staged path. Does not touch the worktree file — callers
    /// that want that too (e.g. `Repository.revert` undoing an addition)
    /// delete it themselves. Returns `error.NotFound` if the path isn't
    /// currently staged.
    pub fn remove(self: *Staging, path: []const u8) !void {
        try self.index.remove(path);
        self.dirty = true;
    }

    /// Add or update a file in the staging area, reading from `repo_root/path`.
    /// The blob content is stored via `store`.
    pub fn addFile(
        self: *Staging,
        store: *const Store,
        repo_root: []const u8,
        path: []const u8,
    ) !Hash {
        return self.addOneFromRoot(store, std.fs.cwd(), repo_root, path);
    }

    /// Shared join-then-read logic behind `addFile`/`addFiles`,
    /// parameterized by directory handle for the same reason
    /// `addFileFromDir` exists at all: so tests (and any future caller
    /// that isn't reading from the real process `cwd`) can point it
    /// somewhere other than `std.fs.cwd()`.
    fn addOneFromRoot(
        self: *Staging,
        store: *const Store,
        dir: std.fs.Dir,
        repo_root: []const u8,
        path: []const u8,
    ) !Hash {
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, path });
        defer self.alloc.free(full_path);
        return self.addFileFromDir(store, dir, full_path, path);
    }

    /// Add or update a file, reading from an explicit directory handle.
    ///
    /// NOTE: this reads worktree files (arbitrary user content anywhere
    /// on disk), which is a different concern from the staging area's
    /// own storage above — it deliberately stays on `std.fs.Dir` rather
    /// than `Vfs`.
    pub fn addFileFromDir(
        self: *Staging,
        store: *const Store,
        dir: std.fs.Dir,
        fs_path: []const u8,
        staged_path: []const u8,
    ) !Hash {
        try merkle_mod.validatePath(staged_path);

        const file = try dir.openFile(fs_path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.kind != .file) return error.NotAFile;

        const blob_hash = try store.putReader(.blob, stat.size, file);

        try self.index.upsert(.{
            .path = try self.alloc.dupe(u8, staged_path),
            .blob_hash = blob_hash,
            .size = stat.size,
            .mode = stat.mode,
            .mtime = stat.mtime,
        });
        self.dirty = true;

        return blob_hash;
    }

    /// Add multiple files as a single all-or-nothing operation: either
    /// every path in `paths` ends up staged, or the staging area's
    /// in-memory state is left exactly as it was before the call.
    ///
    /// Closes a gap `addFile` (and a caller looping over it) has on its
    /// own: a failure partway through a loop of `addFile` calls leaves
    /// the earlier paths staged with no way to undo just that batch.
    /// This snapshots the current entries before the loop and restores
    /// them if any `addFile` fails, instead of pushing that snapshot/
    /// restore responsibility onto every caller.
    ///
    /// Blob content already written to `store` for paths that succeeded
    /// before the failure is NOT rolled back — objects are content-
    /// addressed and immutable, so an orphaned blob is harmless, just
    /// unreferenced until something else stages the same content again
    /// (or a future GC sweeps it).
    ///
    /// On success, returns the per-path blob hashes in `paths` order.
    /// Does not call `save()` — the caller still does that once, same
    /// as after any other mutator.
    pub fn addFiles(
        self: *Staging,
        store: *const Store,
        repo_root: []const u8,
        paths: []const []const u8,
    ) ![]Hash {
        return self.addFilesFromDir(store, std.fs.cwd(), repo_root, paths);
    }

    /// `addFiles`, parameterized by directory handle — see
    /// `addOneFromRoot` for why this split exists.
    fn addFilesFromDir(
        self: *Staging,
        store: *const Store,
        dir: std.fs.Dir,
        repo_root: []const u8,
        paths: []const []const u8,
    ) ![]Hash {
        var snapshot: ArrayList(Entry) = .empty;
        var snapshot_owned = true;
        defer if (snapshot_owned) {
            for (snapshot.items) |*e| e.deinit(self.alloc);
            snapshot.deinit(self.alloc);
        };

        try snapshot.ensureTotalCapacityPrecise(self.alloc, self.index.count());
        for (self.index.allEntries()) |e| {
            snapshot.appendAssumeCapacity(.{
                .path = try self.alloc.dupe(u8, e.path),
                .blob_hash = e.blob_hash,
                .size = e.size,
                .mode = e.mode,
                .mtime = e.mtime,
            });
        }

        var hashes: ArrayList(Hash) = .empty;
        errdefer hashes.deinit(self.alloc);
        try hashes.ensureTotalCapacityPrecise(self.alloc, paths.len);

        for (paths) |path| {
            const hash = self.addOneFromRoot(store, dir, repo_root, path) catch |err| {
                // Roll `self.index` back to the pre-call snapshot.
                self.index.clear();
                try self.index.entries.ensureTotalCapacityPrecise(self.alloc, snapshot.items.len);
                self.index.entries.appendSliceAssumeCapacity(snapshot.items);
                try self.index.sortAndReindex();

                // Ownership of every snapshot entry just moved into
                // `self.index` above — disarm the cleanup `defer` so it
                // doesn't free them out from under the index it just
                // restored; only the (now-empty-of-owned-data) list
                // itself still needs freeing.
                snapshot_owned = false;
                snapshot.deinit(self.alloc);
                return err;
            };
            hashes.appendAssumeCapacity(hash);
        }

        self.dirty = true;
        return try hashes.toOwnedSlice(self.alloc);
    }

    /// Determine whether a staged entry matches the current worktree file.
    pub fn stateOf(self: *const Staging, repo_root: []const u8, entry: Entry) !WorktreeState {
        const cwd = std.fs.cwd();
        const full_path = try std.fs.path.join(self.alloc, &.{ repo_root, entry.path });
        defer self.alloc.free(full_path);
        return self.stateOfInDir(cwd, full_path, entry);
    }

    /// Determine worktree state using an explicit directory handle.
    ///
    /// NOTE: Uses exact mtime comparison; some filesystems may not
    /// preserve nanosecond precision reliably, which can in principle
    /// produce a false `.modified` on an unmodified file whose mtime got
    /// truncated on write-then-stat. Not currently worked around.
    ///
    /// NOTE — known, undecided race: if a file is staged and then
    /// modified again within the same filesystem timestamp tick, the
    /// second write can land on an identical `mtime` to what's recorded
    /// here, which would read back as `.clean` even though content
    /// changed (the "racy git" problem — git's real index handles this
    /// by falling back to a content check for entries whose mtime is
    /// `>=` the index file's own mtime). No such fallback exists here
    /// yet; this is a deliberately-flagged gap, not a fix applied.
    ///
    /// NOTE — `entry.mode` is compared as the full raw mode word from
    /// `stat()`, not just the bits Merk actually cares about (e.g. the
    /// executable bit). A `chmod` that changes unrelated permission bits
    /// without touching content will currently register as `.modified`.
    /// If git-like "only content + executable-ness matters" semantics
    /// are wanted, mask both the stored and compared mode down to the
    /// relevant bits — not done here, since it changes observable
    /// `status()` output and needs its own decision.
    pub fn stateOfInDir(_: *const Staging, dir: std.fs.Dir, fs_path: []const u8, entry: Entry) !WorktreeState {
        const stat = dir.statFile(fs_path) catch |err| switch (err) {
            error.FileNotFound => return .deleted,
            else => return err,
        };

        if (stat.kind != .file) return .modified;
        if (stat.size != entry.size) return .modified;
        if (stat.mode != entry.mode) return .modified;
        if (stat.mtime != entry.mtime) return .modified;
        return .clean;
    }

    /// Read-only view of every staged entry, sorted by path. Callers
    /// that just need to iterate (`status`, writing the worktree, ...)
    /// should use this instead of reaching into the staging area's
    /// internal storage directly — keeps `Staging` free to change how
    /// it stores entries without every caller breaking.
    ///
    /// NOTE: only guaranteed sorted immediately after `load()`, `save()`,
    /// or `replaceAll()` have run (all three call `sortAndReindex()`).
    /// A plain `addFile`/`put` for a brand-new path appends to the end
    /// of the underlying list without re-sorting — `lookup()` is
    /// unaffected (it never relies on order), but code that assumes
    /// `allEntries()` is sorted at every point in time, not just after a
    /// save, will be wrong.
    pub fn allEntries(self: *const Staging) []const Entry {
        return self.index.allEntries();
    }

    /// Number of staged entries.
    pub fn count(self: *const Staging) usize {
        return self.index.count();
    }

    /// Insert or replace an entry directly — the entry-metadata-in-hand
    /// counterpart to `addFile`/`addFileFromDir`, for callers that
    /// already have an `Entry` rather than a worktree file to read
    /// (tests, or restoring entries from a snapshot). Does not persist;
    /// call `save()` when done.
    pub fn put(self: *Staging, entry: Entry) !void {
        try self.index.upsert(entry);
        self.dirty = true;
    }

    /// Discard current entries and replace with `entries`, then persist.
    /// Takes ownership of `entries` (each `Entry.path` is freed by this
    /// `Staging`'s later `deinit`/`remove`/replace, same as any other
    /// staged entry) — callers should not free `entries[i].path`
    /// themselves after this call, and must not reuse the backing slice.
    ///
    /// Always writes, even when `entries` happens to match what's
    /// already on disk (e.g. replacing empty with empty) — callers of
    /// `replaceAll` want the persisted state to unconditionally match
    /// `entries`, not a `save()` that quietly no-ops because nothing
    /// looked "dirty."
    pub fn replaceAll(self: *Staging, entries: []Entry) !void {
        self.index.clear();
        for (entries) |e| try self.index.entries.append(self.alloc, e);
        try self.index.sortAndReindex();
        try self.forceSave();
    }

    /// Whether `path` is currently staged. Trivial wrapper over
    /// `lookup`, but every current caller that wants a yes/no answer
    /// does `lookup(...) != null` itself — worth having once, since
    /// `Repository`'s validate-first pattern checks "is this path
    /// tracked?" repeatedly across `unstagePaths`/`removePaths`/
    /// `restorePaths`.
    pub fn contains(self: *const Staging, path: []const u8) bool {
        return self.index.contains(path);
    }

    /// Sum of `entry.size` across every staged entry. Cheap, and useful
    /// for a something like a progress bar or a "you're about to commit 4GB across
    /// 12,000 files, continue?" guard before an expensive
    /// `stagingTreeRoot()` build.
    pub fn totalStagedSize(self: *const Staging) u64 {
        var total: u64 = 0;
        for (self.index.allEntries()) |e| total += e.size;
        return total;
    }

    /// The contiguous run of staged entries under a directory `prefix`
    /// — the primitive a future `merk status <path>` or `merk diff
    /// <path>` would want instead of filtering the full entry list
    /// every time. See `EntryIndex.entriesUnder` for the sortedness
    /// requirement this inherits.
    pub fn entriesUnder(self: *const Staging, prefix: []const u8) []const Entry {
        return self.index.entriesUnder(prefix);
    }

    /// Confirms every staged entry's blob actually resolves in `store`.
    /// Nothing currently checks this in normal operation — every hash
    /// in `index` came from `store.putReader` moments before it was
    /// staged — but the guarantee can break silently after anything
    /// that prunes or corrupts the store independently of staging (a
    /// future GC, a manual `rm -rf .merk/objects`, a hand-edited
    /// `entries` file that parses but references a hash nobody wrote).
    /// Without this, that surfaces as a bare `error.NotFound` deep
    /// inside `stagingTreeRoot()`'s tree construction; `verify()` gives
    /// a clean, staging-specific answer instead ("N of M staged blobs
    /// are missing from the store, here they are") before that happens.
    ///
    /// Caller owns the returned `VerifyResult` and must call its
    /// `deinit(alloc)`. Each `MissingEntry.path` borrows from this
    /// `Staging`'s own entries — valid only as long as `self.index`
    /// isn't mutated or freed before the caller is done with it.
    pub fn verify(self: *const Staging, store: *const Store) !VerifyResult {
        var missing: ArrayList(MissingEntry) = .empty;
        errdefer missing.deinit(self.alloc);

        for (self.index.allEntries()) |e| {
            if (!store.exists(e.blob_hash)) {
                try missing.append(self.alloc, .{ .path = e.path, .blob_hash = e.blob_hash });
            }
        }

        return .{ .missing = try missing.toOwnedSlice(self.alloc) };
    }
};

/// One staged entry whose blob is missing from the object store —
/// see `Staging.verify`.
pub const MissingEntry = struct {
    path: []const u8,
    blob_hash: Hash,
};

/// Result of `Staging.verify`: every staged entry whose blob failed to
/// resolve in the store. Empty `missing` means everything checks out.
pub const VerifyResult = struct {
    missing: []MissingEntry,

    pub fn deinit(self: *VerifyResult, alloc: Allocator) void {
        alloc.free(self.missing);
    }

    pub fn ok(self: *const VerifyResult) bool {
        return self.missing.len == 0;
    }
};

/// Current on-disk format version for the `entries` file — see
/// `entries_format_version` and the format doc below.
const current_entries_format_version: u8 = 1;

/// Flat serialization: `u8` format version, `u32` entry count, then per
/// entry — `u32` path length, path bytes, 32-byte blob hash, `u64` size
/// (LE), `u64` mode (LE), `i128` mtime (LE). Field widths match `Entry`'s
/// own types exactly (and the same widths `node.zig`'s leaf-entry wire
/// format already uses for size/mode/mtime) — no narrowing casts. No
/// tree structure, no page chunking — this is just "the list," written
/// out plainly.
///
/// The leading version byte exists so a future change to this format
/// (an added field, varint lengths, whatever) has a way to tell "old-
/// format valid file" apart from "new-format valid file" apart from
/// "corrupt file" — reserved now, while there's presumably no data in
/// the wild yet to migrate, since retrofitting it later (onto files
/// with no version byte at all) is the expensive path.
///
/// Pre-computes the exact output size and reserves it up front, so the
/// loop below can use `appendSliceAssumeCapacity` instead of paying for
/// repeated geometric growth on a potentially large entry list.
fn serializeEntries(alloc: Allocator, entries: []const Entry) ![]u8 {
    var total_size: usize = 1 + 4; // format version + entry count
    for (entries) |e| {
        total_size += 4; // path length
        total_size += e.path.len;
        total_size += 32; // blob hash
        total_size += 8; // size
        total_size += 8; // mode
        total_size += 16; // mtime
    }

    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacityPrecise(alloc, total_size);

    out.appendAssumeCapacity(current_entries_format_version);

    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, @intCast(entries.len), .little);
    out.appendSliceAssumeCapacity(&count_buf);

    for (entries) |e| {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(e.path.len), .little);
        out.appendSliceAssumeCapacity(&len_buf);
        out.appendSliceAssumeCapacity(e.path);
        out.appendSliceAssumeCapacity(&e.blob_hash);

        var size_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &size_buf, e.size, .little);
        out.appendSliceAssumeCapacity(&size_buf);

        var mode_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &mode_buf, e.mode, .little);
        out.appendSliceAssumeCapacity(&mode_buf);

        var mtime_buf: [16]u8 = undefined;
        std.mem.writeInt(i128, &mtime_buf, e.mtime, .little);
        out.appendSliceAssumeCapacity(&mtime_buf);
    }

    return try out.toOwnedSlice(alloc);
}

fn deserializeEntries(alloc: Allocator, bytes: []const u8, index: *EntryIndex) !void {
    if (bytes.len < 1) return error.CorruptStagingEntries;
    var pos: usize = 0;

    const version = bytes[0];
    pos += 1;
    if (version != current_entries_format_version) return error.UnsupportedStagingFormat;

    if (pos + 4 > bytes.len) return error.CorruptStagingEntries;
    const entry_count = std.mem.readInt(u32, bytes[pos..][0..4], .little);
    pos += 4;

    try index.reserve(entry_count);

    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        if (pos + 4 > bytes.len) return error.CorruptStagingEntries;
        const path_len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;

        if (pos + path_len > bytes.len) return error.CorruptStagingEntries;
        const path_slice = bytes[pos..][0..path_len];
        merkle_mod.validatePath(path_slice) catch return error.CorruptStagingEntries;
        pos += path_len;

        if (pos + 32 > bytes.len) return error.CorruptStagingEntries;
        var blob_hash: Hash = undefined;
        @memcpy(&blob_hash, bytes[pos..][0..32]);
        pos += 32;

        if (pos + 8 > bytes.len) return error.CorruptStagingEntries;
        const size = std.mem.readInt(u64, bytes[pos..][0..8], .little);
        pos += 8;

        if (pos + 8 > bytes.len) return error.CorruptStagingEntries;
        const mode = std.mem.readInt(u64, bytes[pos..][0..8], .little);
        pos += 8;

        if (pos + 16 > bytes.len) return error.CorruptStagingEntries;
        const mtime = std.mem.readInt(i128, bytes[pos..][0..16], .little);
        pos += 16;

        // Only allocate now, immediately before handing ownership to
        // appendUnique — see the comment above for why.
        const path = try alloc.dupe(u8, path_slice);

        index.appendUnique(.{
            .path = path,
            .blob_hash = blob_hash,
            .size = size,
            .mode = mode,
            .mtime = mtime,
        }) catch |err| switch (err) {
            // appendUnique already frees `path` (and the rest of the
            // entry) on failure via its own internal errdefer — nothing
            // more to free here.
            error.DuplicatePath => return error.CorruptStagingEntries,
            else => return err,
        };
    }
}

test "staging addFile stores blob and upserts entry" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "first" });

    var os_fs = OsFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, os_fs.fs(), "merk/objects");
    var staging = Staging.init(alloc, os_fs.fs(), "merk");
    defer staging.deinit();

    const hash1 = try staging.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");
    try testing.expectEqual(@as(usize, 1), staging.count());
    try testing.expect(object_store.exists(hash1));

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "second" });
    const hash2 = try staging.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");
    try testing.expectEqual(@as(usize, 1), staging.count());
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));
    try testing.expect(object_store.exists(hash2));
}

test "staging stateOf reports deleted file" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    const entry = Entry{
        .path = try alloc.dupe(u8, "missing.txt"),
        .blob_hash = crypto.blake3("missing"),
        .size = 7,
        .mode = 0o100644,
        .mtime = 123,
    };
    defer alloc.free(entry.path);

    try testing.expectEqual(WorktreeState.deleted, try staging.stateOfInDir(tmp_dir.dir, "missing.txt", entry));
}

test "staging lookup works after addFile without an intervening save" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "zzz.txt", .data = "z" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "aaa.txt", .data = "a" });

    var os_fs = OsFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, os_fs.fs(), "merk/objects");
    var staging = Staging.init(alloc, os_fs.fs(), "merk");
    defer staging.deinit();

    // Insert lexicographically out of order (z before a). A binary-search
    // lookup over an unsorted `entries` array would fail to find "aaa.txt"
    // here; the path_index map must not care about ordering.
    _ = try staging.addFileFromDir(&object_store, tmp_dir.dir, "zzz.txt", "zzz.txt");
    _ = try staging.addFileFromDir(&object_store, tmp_dir.dir, "aaa.txt", "aaa.txt");

    try testing.expect(staging.lookup("zzz.txt") != null);
    try testing.expect(staging.lookup("aaa.txt") != null);
    try testing.expect(staging.lookup("missing.txt") == null);
}

test "staging upsert replaces an existing entry in place" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "v1" });

    var os_fs = OsFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, os_fs.fs(), "merk/objects");
    var staging = Staging.init(alloc, os_fs.fs(), "merk");
    defer staging.deinit();

    _ = try staging.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");
    try tmp_dir.dir.writeFile(.{ .sub_path = "note.txt", .data = "v2-longer" });
    _ = try staging.addFileFromDir(&object_store, tmp_dir.dir, "note.txt", "note.txt");

    try testing.expectEqual(@as(usize, 1), staging.count());
    const entry = staging.lookup("note.txt") orelse return error.ExpectedEntry;
    try testing.expectEqual(@as(u64, 9), entry.size);
}

test "staging remove drops a tracked path and reports NotFound afterward" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    try staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "keep.txt"),
        .blob_hash = crypto.blake3("keep"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "drop.txt"),
        .blob_hash = crypto.blake3("drop"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.index.sortAndReindex();

    try staging.remove("drop.txt");
    try testing.expectEqual(@as(usize, 1), staging.count());
    try testing.expect(staging.lookup("drop.txt") == null);
    try testing.expect(staging.lookup("keep.txt") != null);
    try testing.expectError(error.NotFound, staging.remove("drop.txt"));
}

test "staging save and load round-trip as a flat list" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();
    try staging.index.entries.append(alloc, .{
        .path = try alloc.dupe(u8, "src/main.zig"),
        .blob_hash = crypto.blake3("main"),
        .size = 4,
        .mode = 0o100644,
        .mtime = 123,
    });
    // Appended directly to index.entries, bypassing put()/addFile() (the
    // only paths that set `dirty` themselves) -- mark it dirty by hand
    // so save() doesn't see a clean flag and skip the write.
    staging.dirty = true;
    try staging.save();

    try testing.expect(mem_fs.hasFile("merk/entries"));
    try testing.expect(!mem_fs.hasFile("merk/root"));

    var loaded = Staging.init(alloc, mem_fs.fs(), "merk");
    defer loaded.deinit();
    try loaded.load();

    try testing.expectEqual(@as(usize, 1), loaded.index.entries.items.len);
    try testing.expectEqualStrings("src/main.zig", loaded.index.entries.items[0].path);
    try testing.expectEqualSlices(u8, &crypto.blake3("main"), &loaded.index.entries.items[0].blob_hash);
    try testing.expectEqual(@as(u64, 4), loaded.index.entries.items[0].size);
    try testing.expectEqual(@as(u64, 0o100644), loaded.index.entries.items[0].mode);
    try testing.expectEqual(@as(i128, 123), loaded.index.entries.items[0].mtime);
}

test "staging save and load round-trip many entries out of insertion order" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    for (0..140) |i| {
        const path = try std.fmt.allocPrint(alloc, "src/file-{d:0>3}.zig", .{i});
        try staging.index.entries.append(alloc, .{
            .path = path,
            .blob_hash = crypto.blake3(path),
            .size = i,
            .mode = 0o100644,
            .mtime = @intCast(i),
        });
    }

    // Same as above -- direct index.entries manipulation doesn't flip
    // `dirty` on its own.
    staging.dirty = true;
    try staging.save();

    var loaded = Staging.init(alloc, mem_fs.fs(), "merk");
    defer loaded.deinit();
    try loaded.load();
    try testing.expectEqual(@as(usize, 140), loaded.index.entries.items.len);
    try testing.expect(loaded.lookup("src/file-042.zig") != null);
}

test "staging replaceAll discards current entries and persists the replacement" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();
    try staging.put(.{
        .path = try alloc.dupe(u8, "old.txt"),
        .blob_hash = crypto.blake3("old"),
        .size = 3,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.save();

    var replacement: ArrayList(Entry) = .empty;
    try replacement.append(alloc, .{
        .path = try alloc.dupe(u8, "new.txt"),
        .blob_hash = crypto.blake3("new"),
        .size = 3,
        .mode = 0o100644,
        .mtime = 2,
    });
    try staging.replaceAll(replacement.items);
    replacement.deinit(alloc); // ownership of each entry's .path moved into staging.index

    try testing.expectEqual(@as(usize, 1), staging.count());
    try testing.expect(staging.lookup("old.txt") == null);
    try testing.expect(staging.lookup("new.txt") != null);

    var loaded = Staging.init(alloc, mem_fs.fs(), "merk");
    defer loaded.deinit();
    try loaded.load();
    try testing.expectEqual(@as(usize, 1), loaded.count());
    try testing.expect(loaded.lookup("new.txt") != null);
}

test "staging replaceAll with an empty slice clears staging (force reinit path)" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();
    try staging.put(.{
        .path = try alloc.dupe(u8, "a.txt"),
        .blob_hash = crypto.blake3("a"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.save();

    // This is the exact call `Repository.init(force=true)` makes — no
    // Merkle tree, no zero_hash, no store lookup involved at all, so
    // there's nothing here to crash the way the original bug did.
    try staging.replaceAll(&.{});

    try testing.expectEqual(@as(usize, 0), staging.count());
}

test "staging contains and totalStagedSize reflect current entries" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    try testing.expect(!staging.contains("a.txt"));
    try testing.expectEqual(@as(u64, 0), staging.totalStagedSize());

    try staging.put(.{
        .path = try alloc.dupe(u8, "a.txt"),
        .blob_hash = crypto.blake3("a"),
        .size = 10,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.put(.{
        .path = try alloc.dupe(u8, "b.txt"),
        .blob_hash = crypto.blake3("b"),
        .size = 25,
        .mode = 0o100644,
        .mtime = 1,
    });

    try testing.expect(staging.contains("a.txt"));
    try testing.expect(!staging.contains("c.txt"));
    try testing.expectEqual(@as(u64, 35), staging.totalStagedSize());

    try staging.remove("a.txt");
    try testing.expect(!staging.contains("a.txt"));
    try testing.expectEqual(@as(u64, 25), staging.totalStagedSize());
}

test "staging entriesUnder returns only the matching directory prefix" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    try staging.put(.{ .path = try alloc.dupe(u8, "README.md"), .blob_hash = crypto.blake3("r"), .size = 1, .mode = 0o100644, .mtime = 1 });
    try staging.put(.{ .path = try alloc.dupe(u8, "src/a.zig"), .blob_hash = crypto.blake3("a"), .size = 1, .mode = 0o100644, .mtime = 1 });
    try staging.put(.{ .path = try alloc.dupe(u8, "src/b.zig"), .blob_hash = crypto.blake3("b"), .size = 1, .mode = 0o100644, .mtime = 1 });
    try staging.save(); // sorts and reindexes, which entriesUnder relies on

    const under_src = staging.entriesUnder("src/");
    try testing.expectEqual(@as(usize, 2), under_src.len);
    try testing.expectEqual(@as(usize, 0), staging.entriesUnder("docs/").len);
}

test "staging save is a no-op once clean, and dirty again after a mutation" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    // Nothing staged yet, nothing to save.
    try testing.expect(!staging.dirty);
    try staging.save();
    try testing.expect(!mem_fs.hasFile("merk/entries"));

    try staging.put(.{
        .path = try alloc.dupe(u8, "a.txt"),
        .blob_hash = crypto.blake3("a"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try testing.expect(staging.dirty);

    try staging.save();
    try testing.expect(!staging.dirty);
    try testing.expect(mem_fs.hasFile("merk/entries"));

    // Delete the on-disk file out from under staging directly, bypassing
    // Staging's own API -- if save() actually re-wrote it here (instead
    // of skipping because dirty=false), the file would reappear.
    try mem_fs.fs().deleteFile(try staging.entriesPath());
    try staging.save();
    try testing.expect(!mem_fs.hasFile("merk/entries"));

    // A fresh load() clears dirty again.
    try staging.put(.{
        .path = try alloc.dupe(u8, "b.txt"),
        .blob_hash = crypto.blake3("b"),
        .size = 1,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.save();
    try testing.expect(!staging.dirty);
}

test "staging replaceAll writes even when nothing looks dirty" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    // Never mutated via put/addFile/remove, so `dirty` is still false --
    // replaceAll must still persist via forceSave.
    try testing.expect(!staging.dirty);
    try staging.replaceAll(&.{});
    try testing.expect(mem_fs.hasFile("merk/entries"));
}

test "staging addFiles stages every path on success" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "a.txt", .data = "a" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "b.txt", .data = "b" });

    var os_fs = OsFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, os_fs.fs(), "merk/objects");
    var staging = Staging.init(alloc, os_fs.fs(), "merk");
    defer staging.deinit();

    const hashes = try staging.addFilesFromDir(&object_store, tmp_dir.dir, ".", &.{ "a.txt", "b.txt" });
    defer alloc.free(hashes);

    try testing.expectEqual(@as(usize, 2), hashes.len);
    try testing.expectEqual(@as(usize, 2), staging.count());
    try testing.expect(staging.contains("a.txt"));
    try testing.expect(staging.contains("b.txt"));
}

test "staging addFiles rolls back to the pre-call state on a mid-batch failure" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "a.txt", .data = "a" });
    // "missing.txt" is deliberately never created, so the second path in
    // the batch fails to open.

    var os_fs = OsFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, os_fs.fs(), "merk/objects");
    var staging = Staging.init(alloc, os_fs.fs(), "merk");
    defer staging.deinit();

    // Something already staged before the batch call -- must survive
    // the rollback exactly as it was.
    try staging.put(.{
        .path = try alloc.dupe(u8, "preexisting.txt"),
        .blob_hash = crypto.blake3("pre"),
        .size = 3,
        .mode = 0o100644,
        .mtime = 1,
    });

    try testing.expectError(
        error.FileNotFound,
        staging.addFilesFromDir(&object_store, tmp_dir.dir, ".", &.{ "a.txt", "missing.txt" }),
    );

    // Neither "a.txt" (which succeeded before the failure) nor
    // "missing.txt" should be staged -- the whole batch rolled back.
    try testing.expectEqual(@as(usize, 1), staging.count());
    try testing.expect(!staging.contains("a.txt"));
    try testing.expect(!staging.contains("missing.txt"));
    try testing.expect(staging.contains("preexisting.txt"));
}

test "staging verify reports staged blobs missing from the store" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var os_fs = OsFs.init(tmp_dir.dir);
    const object_store = Store.init(alloc, os_fs.fs(), "merk/objects");
    var staging = Staging.init(alloc, os_fs.fs(), "merk");
    defer staging.deinit();

    // A staged entry whose blob was never actually written to the
    // store -- simulates the store having been pruned/corrupted out
    // from under staging.
    try staging.put(.{
        .path = try alloc.dupe(u8, "ghost.txt"),
        .blob_hash = crypto.blake3("never-written"),
        .size = 5,
        .mode = 0o100644,
        .mtime = 1,
    });

    var result = try staging.verify(&object_store);
    defer result.deinit(alloc);

    try testing.expect(!result.ok());
    try testing.expectEqual(@as(usize, 1), result.missing.len);
    try testing.expectEqualStrings("ghost.txt", result.missing[0].path);
}

test "staging load rejects a duplicate path as corrupt rather than creating a ghost entry" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();

    // Hand-build a serialized payload with "dup.txt" listed twice, since
    // there's no public API that would ever produce this legitimately —
    // this simulates a corrupted or hand-edited `entries` file.
    const e1 = Entry{
        .path = try alloc.dupe(u8, "dup.txt"),
        .blob_hash = crypto.blake3("v1"),
        .size = 2,
        .mode = 0o100644,
        .mtime = 1,
    };
    defer alloc.free(e1.path);
    const e2 = Entry{
        .path = try alloc.dupe(u8, "dup.txt"),
        .blob_hash = crypto.blake3("v2"),
        .size = 2,
        .mode = 0o100644,
        .mtime = 2,
    };
    defer alloc.free(e2.path);

    const bytes = try serializeEntries(alloc, &.{ e1, e2 });
    defer alloc.free(bytes);

    var scratch = EntryIndex.init(alloc);
    defer scratch.deinit();
    try testing.expectError(error.CorruptStagingEntries, deserializeEntries(alloc, bytes, &scratch));
}

test "staging load leaves prior in-memory state untouched when the file is corrupt" {
    const alloc = testing.allocator;
    var mem_fs = MemoryFs.init(alloc);
    defer mem_fs.deinit();

    var staging = Staging.init(alloc, mem_fs.fs(), "merk");
    defer staging.deinit();
    try staging.put(.{
        .path = try alloc.dupe(u8, "kept.txt"),
        .blob_hash = crypto.blake3("kept"),
        .size = 4,
        .mode = 0o100644,
        .mtime = 1,
    });
    try staging.save();

    // Corrupt the on-disk file directly (truncate mid-record), bypassing
    // Staging's own API entirely.
    const entries_path = try staging.entriesPath();
    const good_bytes = (try mem_fs.fs().readFile(alloc, entries_path)).?;
    defer alloc.free(good_bytes);
    const truncated = good_bytes[0 .. good_bytes.len - 1];
    try mem_fs.fs().writeFile(alloc, entries_path, truncated);

    // Stage something new in memory before attempting the failing load.
    try staging.put(.{
        .path = try alloc.dupe(u8, "new.txt"),
        .blob_hash = crypto.blake3("new"),
        .size = 3,
        .mode = 0o100644,
        .mtime = 2,
    });

    try testing.expectError(error.CorruptStagingEntries, staging.load());

    // Both entries staged before the failed load must still be present —
    // load() must not have partially overwritten self.index.
    try testing.expect(staging.lookup("kept.txt") != null);
    try testing.expect(staging.lookup("new.txt") != null);
}
