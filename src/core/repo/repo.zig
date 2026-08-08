//! Core `Repository` implementation. Import this file directly only
//! from within `repository/` (tests) or from the top-level facade,
//! `repository.zig` — every other caller should go through that facade
//! so the internal layout here can keep changing without breaking them.
//!
//! See `errors.zig`'s doc comment for the Options-in / typed-error-out
//! pattern every method here follows, and `status.zig` for why result
//! types carry no formatting logic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const merkle_mod = @import("merkle");
const crypto = @import("crypto");
const storage = @import("storage");

const object_mod = @import("../object/object.zig");
const staging_mod = @import("../staging.zig");
const commit_mod = @import("../commit.zig");
const history_mod = @import("../history.zig");
const refs_mod = @import("../refs/refs.zig");

const options_mod = @import("./options.zig");
const status_mod = @import("./status.zig");
const errors_mod = @import("./errors.zig");

const Hash = crypto.Hash;
const Store = object_mod.Store;
const Staging = staging_mod.Staging;
const History = history_mod.History;
const ReferenceStore = refs_mod.ReferenceStore;
const ChannelName = refs_mod.ChannelName;
pub const CommitRequest = commit_mod.CommitRequest;
const ParentInfo = commit_mod.ParentInfo;
const EntryChange = merkle_mod.EntryChange;
const WorktreeState = merkle_mod.WorktreeState;

pub const RepositoryError = errors_mod.RepositoryError;
pub const describe = errors_mod.describe;

pub const InitOptions = options_mod.InitOptions;
pub const RemoveOptions = options_mod.RemoveOptions;
pub const MoveOptions = options_mod.MoveOptions;
pub const ResetMode = options_mod.ResetMode;
pub const ResetOptions = options_mod.ResetOptions;

pub const Status = status_mod.Status;
pub const WorktreeEntryStatus = status_mod.WorktreeEntryStatus;

const Vfs = storage.Vfs;

const OwnedChannel = struct {
    /// Backing storage `parsed` borrows from. Never read directly by
    /// callers outside this type — go through `get()`.
    raw: []u8,
    parsed: ChannelName,

    fn init(alloc: Allocator, name: []const u8) !OwnedChannel {
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        return .{ .raw = owned, .parsed = try ChannelName.parse(owned) };
    }

    /// Reparses and swaps in `name` as the new active channel,
    /// replacing the old backing storage only after the new one has
    /// been successfully allocated and parsed — so a failed `set`
    /// (bad allocation or an invalid name) leaves the previous channel
    /// fully intact rather than half-updated.
    fn set(self: *OwnedChannel, alloc: Allocator, name: []const u8) !void {
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        const parsed = try ChannelName.parse(owned);

        alloc.free(self.raw);
        self.raw = owned;
        self.parsed = parsed;
    }

    fn get(self: *const OwnedChannel) ChannelName {
        return self.parsed;
    }

    fn deinit(self: *OwnedChannel, alloc: Allocator) void {
        alloc.free(self.raw);
    }
};

pub const InitResult = struct {
    repository: *Repository,
    action: Action,

    pub const Action = enum { initialized, reinitialized };
};

pub const Repository = struct {
    alloc: Allocator,
    fs: Vfs,
    /// Worktree root (plain OS path, not `fs`-relative).
    root: []const u8,
    store: Store,
    page_store: merkle_mod.PageStore,
    staging: Staging,
    history: History,
    ref_store: ReferenceStore,
    /// Owned backing storage for `channel.get().raw`.
    channel: OwnedChannel,

    /// Create a repository. `fs` must already be rooted at the control
    /// directory. Fails with `error.AlreadyInitialized` if Focus is
    /// already set there, unless `options.force` is set — see
    /// `InitOptions.force`'s doc comment for exactly what force does
    /// and doesn't touch.
    pub fn init(alloc: Allocator, fs: Vfs, root: []const u8, init_options: InitOptions) !InitResult {
        const probe = ReferenceStore.init(alloc, fs);
        const already_initialized = if (try probe.currentState()) |existing| blk: {
            existing.deinit(alloc);
            break :blk true;
        } else false;

        if (already_initialized and !init_options.force) return error.AlreadyInitialized;

        const self = try openInternal(alloc, fs, root, "main");
        errdefer self.deinit();

        if (already_initialized) {
            // Reinitializing over an existing repo: start from an empty
            // staging area rather than whatever `openInternal`'s
            // `staging.load()` just picked up from the old one. This is
            // a plain list clear now — no zero_hash, no store lookup,
            // nothing that can fail with NotFound. `replaceAll` persists
            // on its own, so no separate `save()` is needed here.
            try self.staging.replaceAll(&.{});
        } else {
            try self.staging.save();
        }

        try self.ref_store.setCurrentToChannel(self.channel.get());
        return .{
            .repository = self,
            .action = if (already_initialized) .reinitialized else .initialized,
        };
    }

    /// Open an existing repository. `error.NotARepository` if no Focus
    /// file exists yet; `error.DetachedCurrent` if Focus points directly
    /// at a commit rather than a track (see `RepositoryError`).
    pub fn open(alloc: Allocator, fs: Vfs, root: []const u8) !*Repository {
        const ref_store = ReferenceStore.init(alloc, fs);
        const state = (try ref_store.currentState()) orelse return error.NotARepository;
        defer state.deinit(alloc);

        const channel_name = switch (state) {
            .symbolic => |s| s,
            .detached => return error.DetachedCurrent,
        };

        return openInternal(alloc, fs, root, channel_name);
    }

    fn openInternal(alloc: Allocator, fs: Vfs, root: []const u8, channel_name: []const u8) !*Repository {
        // Allocate first and fill fields in place: `&self.store` /
        // `&self.page_store` below must point at this struct's final,
        // permanent address, not at a local that vanishes when this
        // function returns (returning `Repository` by value would copy
        // it to a new address and leave History's pointers dangling —
        // that was the actual bug behind the earlier crash).
        const self = try alloc.create(Repository);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.fs = fs;
        self.store = Store.init(alloc, fs, "objects");
        self.page_store = merkle_mod.PageStore.init(alloc, fs, "index/pages");

        // fs is already rooted at the control directory; the staging
        // area's on-disk state is just "staging/entries" — a flat list,
        // no tree, no pages of its own. Any Merkle tree built from
        // staged content is built directly into `self.page_store`
        // below, on demand (see `stagingTreeRoot`) — there is
        // deliberately only ever one page store in this repository.
        self.staging = Staging.init(alloc, fs, "staging");
        errdefer self.staging.deinit();
        try self.staging.load();

        self.root = try alloc.dupe(u8, root);
        errdefer alloc.free(self.root);

        self.channel = try OwnedChannel.init(alloc, channel_name);
        errdefer self.channel.deinit(alloc);
        self.ref_store = ReferenceStore.init(alloc, fs);

        self.history = try History.init(alloc, fs, "history", &self.store, &self.page_store);

        return self;
    }

    pub fn deinit(self: *Repository) void {
        self.staging.deinit();
        self.history.deinit();
        self.alloc.free(self.root);
        self.channel.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Rejects absolute paths and `..` segments. Every repo-relative path
    /// argument (`add`/`rm`/`mv`/`restore`) goes through this first, so the
    /// CLI layer doesn't have to reimplement the same two checks per
    /// command — and any other caller of these methods gets the same
    /// guarantee for free.
    fn validateRelativePath(path: []const u8) RepositoryError!void {
        if (std.fs.path.isAbsolute(path)) return error.AbsolutePath;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (std.mem.eql(u8, segment, "..")) return error.PathEscapesRoot;
        }
    }

    /// Stage a batch of repo-relative paths. Errors partway through
    /// leave already-staged paths staged — callers wanting all-or-nothing
    /// semantics should snapshot `self.staging.allEntries()` first.
    pub fn add(self: *Repository, paths: []const []const u8) !void {
        for (paths) |p| try validateRelativePath(p);
        for (paths) |p| _ = try self.staging.addFile(&self.store, self.root, p);
        try self.staging.save();
    }

    /// Unstage a path (drop it from the staging area without touching
    /// the worktree file). Mirrors `git reset <path>`, not `checkout`.
    pub fn unstage(self: *Repository, path: []const u8) !void {
        try self.unstagePaths(&.{path});
    }

    /// Unstage several paths at once, validated up front and saved once
    /// at the end — cheaper than calling `unstage` in a loop, which would
    /// re-save after every single path.
    pub fn unstagePaths(self: *Repository, paths: []const []const u8) !void {
        for (paths) |p| {
            if (self.staging.lookup(p) == null) return error.NotTracked;
        }
        for (paths) |p| try self.staging.remove(p);
        try self.staging.save();
    }

    /// Untrack paths, and unless `options.cached`, delete them from the
    /// worktree too. Every path must already be tracked, validated up
    /// front for the same reason as `unstagePaths`.
    pub fn removePaths(self: *Repository, paths: []const []const u8, remove_options: RemoveOptions) !void {
        for (paths) |p| {
            if (self.staging.lookup(p) == null) return error.NotTracked;
        }

        const dir = std.fs.cwd();
        for (paths) |p| {
            if (!remove_options.cached) {
                const full_path = try std.fs.path.join(self.alloc, &.{ self.root, p });
                defer self.alloc.free(full_path);

                dir.deleteFile(full_path) catch |err| switch (err) {
                    error.FileNotFound => {}, // already gone on disk; still untrack it
                    else => return err,
                };
            }
            try self.staging.remove(p);
        }
        try self.staging.save();
    }

    /// Rename a tracked path on disk and in the staging area. Content doesn't
    /// change — only the location — so the blob hash carries over as-is
    /// rather than being recomputed from a re-read.
    pub fn movePath(self: *Repository, from: []const u8, to: []const u8, move_options: MoveOptions) !void {
        try validateRelativePath(from);
        try validateRelativePath(to);
        if (std.mem.eql(u8, from, to)) return error.SamePath;

        if (self.staging.lookup(from) == null) return error.NotTracked;
        if (!move_options.force and self.staging.lookup(to) != null) return error.DestinationTracked;

        const from_full = try std.fs.path.join(self.alloc, &.{ self.root, from });
        defer self.alloc.free(from_full);
        const to_full = try std.fs.path.join(self.alloc, &.{ self.root, to });
        defer self.alloc.free(to_full);

        if (std.fs.path.dirname(to_full)) |d| try std.fs.cwd().makePath(d);
        try std.fs.cwd().rename(from_full, to_full);

        try self.staging.remove(from);
        _ = try self.staging.addFile(&self.store, self.root, to);
        try self.staging.save();
    }

    /// Builds a Merkle tree from the current staging entries directly
    /// into `self.page_store` — the repository's one permanent page
    /// store — and returns its root hash. There is no cached tree on
    /// `Staging` to go stale: this rebuilds from `staging.allEntries()`
    /// every call. That's cheap, not wasteful — `PageStore.put` skips
    /// any page whose hash already exists on disk, so a rebuild against
    /// unchanged content touches no new storage. Every caller that needs
    /// a hash for the staged tree (commit, status, diffStaged) goes
    /// through this, so there is exactly one place staged content ever
    /// becomes a tree, and it's always the permanent store.
    fn stagingTreeRoot(self: *Repository) !Hash {
        return merkle_mod.build(self.alloc, &self.page_store, self.staging.allEntries());
    }

    /// Commit the currently-staged area as a child of the current
    /// track's HEAD (or as a root commit if the track has none yet).
    pub fn commit(self: *Repository, request: CommitRequest) !Hash {
        const repo_head = try self.ref_store.readChannel(self.channel.get());

        var parent_buf: [1]ParentInfo = undefined;
        const parents: []const ParentInfo = if (repo_head) |h| blk: {
            parent_buf[0] = .{ .hash = h, .kind = .normal };
            break :blk parent_buf[0..1];
        } else &.{};

        const tree_root = try self.stagingTreeRoot();
        return self.history.commit(self.channel.get(), tree_root, parents, request);
    }

    pub fn status(self: *Repository) !Status {
        const head_snapshot = try self.headSnapshot();
        const staged_root = try self.stagingTreeRoot();
        const staged = try merkle_mod.diffRoots(self.alloc, &self.page_store, head_snapshot, staged_root);
        errdefer merkle_mod.freeChanges(self.alloc, staged);

        var unstaged: std.ArrayList(WorktreeEntryStatus) = .empty;
        errdefer unstaged.deinit(self.alloc);
        for (self.staging.allEntries()) |entry| {
            const state = try self.staging.stateOf(self.root, entry);
            if (state != .clean) try unstaged.append(self.alloc, .{ .path = entry.path, .state = state });
        }

        return .{ .staged = staged, .unstaged = try unstaged.toOwnedSlice(self.alloc) };
    }

    /// Diff between two arbitrary commits' snapshots. Caller frees with
    /// `merkle_mod.freeChanges`.
    pub fn diffCommits(self: *Repository, from: Hash, to: Hash) ![]EntryChange {
        return merkle_mod.diffRoots(self.alloc, &self.page_store, from, to);
    }

    /// Diff HEAD against the currently staged area — same data as
    /// `status().staged`, exposed directly for a plain `merk diff --staged`.
    pub fn diffStaged(self: *Repository) ![]EntryChange {
        const staged_root = try self.stagingTreeRoot();
        return merkle_mod.diffRoots(self.alloc, &self.page_store, try self.headSnapshot(), staged_root);
    }

    /// Move the current track to `reset_options.target` per
    /// `reset_options.mode`. See `ResetMode` for what each level touches.
    ///
    /// The target is always read and validated as a real, readable commit
    /// BEFORE anything is mutated — for every mode, including `.soft`. A
    /// bad or unreadable target (typo, wrong-repo hash, corrupt object)
    /// must fail here with the current track fully untouched, not after
    /// the ref has already been repointed at something that turns out not
    /// to exist.
    pub fn reset(self: *Repository, reset_options: ResetOptions) !void {
        var c = commit_mod.read(self.alloc, &self.store, reset_options.target) catch |err| switch (err) {
            error.NotFound => return error.RevNotFound,
            else => return err,
        };
        defer c.deinit(self.alloc);

        if (reset_options.mode == .soft) {
            try self.ref_store.updateChannel(self.channel.get(), reset_options.target);
            return;
        }

        // Collect the target commit's entries from the shared store —
        // the only store any commit's pages ever live in — then hand
        // ownership straight to staging as a plain list. No tree gets
        // rebuilt or persisted for staging itself.
        var collected: std.ArrayList(merkle_mod.Entry) = .empty;
        errdefer {
            for (collected.items) |*e| e.deinit(self.alloc);
            collected.deinit(self.alloc);
        }
        try merkle_mod.collect(self.alloc, &self.page_store, c.snapshot, &collected);

        // Only now, with the target proven valid and its entries already
        // in hand, do we start mutating anything.
        try self.ref_store.updateChannel(self.channel.get(), reset_options.target);
        try self.staging.replaceAll(collected.items);
        collected.deinit(self.alloc);

        if (reset_options.mode == .hard) try self.writeEntriesToWorktree();
    }

    /// Overwrite specific tracked worktree paths with their staged
    /// content — the worktree-writing half of `restore` (without
    /// `--staged`). Every path must already be tracked, validated up
    /// front so a bad path partway through a multi-path restore doesn't
    /// leave some files overwritten and others not.
    pub fn restorePaths(self: *Repository, paths: []const []const u8) !void {
        for (paths) |p| {
            try validateRelativePath(p);

            const entry = self.staging.lookup(p) orelse return error.NotTracked;
            if (!self.store.exists(entry.blob_hash)) return error.BlobMissing;
        }

        // execute restoration. writeBlobToWorktree handles parent
        // directory creation, the directory-collision check, and atomic
        // replacement of any existing file
        for (paths) |p| {
            const entry = self.staging.lookup(p).?;
            try self.writeBlobToWorktree(p, entry.blob_hash);
        }
    }
    /// Writes one blob's content to `<root>/<path>` on the real filesystem,
    /// creating parent directories as needed. The one place staged content
    /// gets materialized into the worktree — `reset(.hard)` and
    /// `restorePaths` both go through this instead of each having their own
    /// copy of the join/mkdir/writeFile sequence.
    ///
    /// Writes via a temp file + rename so a failure partway through (blob
    /// missing, disk full, process killed) never destroys content that was
    /// already at `path` — the old file is only replaced once the new
    /// content is fully and successfully written.
    fn writeBlobToWorktree(self: *Repository, path: []const u8, blob_hash: Hash) !void {
        const dir = std.fs.cwd();
        const obj = try self.store.get(blob_hash);
        defer self.alloc.free(obj.payload);

        const full_path = try std.fs.path.join(self.alloc, &.{ self.root, path });
        defer self.alloc.free(full_path);

        if (std.fs.path.dirname(full_path)) |d| {
            dir.makePath(d) catch |err| switch (err) {
                error.NotDir => return error.ObstructedPath,
                else => |e| return e,
            };
        }

        // Reject only if something *else* occupies the target path.
        // A stat failure that isn't FileNotFound (permissions, symlink
        // loops, ...) must propagate rather than being treated as "safe".
        if (dir.statFile(full_path)) |stat| {
            if (stat.kind == .directory) return error.IsADirectory;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }

        const dir_path = std.fs.path.dirname(full_path) orelse ".";
        const base_name = std.fs.path.basename(full_path);

        var tmp_name_buf: [std.fs.max_name_bytes]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(
            &tmp_name_buf,
            ".{s}.merk-tmp-{d}",
            .{ base_name, std.time.nanoTimestamp() },
        );

        const tmp_path = try std.fs.path.join(self.alloc, &.{ dir_path, tmp_name });
        defer self.alloc.free(tmp_path);

        {
            const file = try dir.createFile(tmp_path, .{});
            defer file.close();
            try file.writeAll(obj.payload);
        }
        errdefer dir.deleteFile(tmp_path) catch {};

        // Atomic on POSIX (rename(2) replaces the destination in one step).
        // ?TO confime onn windows, Zig's Dir.rename uses MOVEFILE_REPLACE_EXISTING, so it
        // also replaces an existing target
        try dir.rename(tmp_path, full_path);
    }
    fn writeEntriesToWorktree(self: *Repository) !void {
        for (self.staging.allEntries()) |entry| {
            try self.writeBlobToWorktree(entry.path, entry.blob_hash);
        }
    }

    pub fn log(self: *Repository, filter: history_mod.EdgeFilter) !?history_mod.RevWalk {
        return self.history.log(self.channel.get(), filter);
    }

    /// Current track's HEAD commit hash, or `null` if the track has no
    /// commits yet. Every history-facing command (`show`, `commit`,
    /// `uncommit`) needs this — public so they read it here instead of
    /// reaching into `ref_store` directly.
    pub fn head(self: *Repository) !?Hash {
        return self.ref_store.readChannel(self.channel.get());
    }

    /// Resolves a commit reference: a full 64-char hex hash, or an 8+
    /// char prefix resolved against the object store. `show` and `diff
    /// --rev` both take commit arguments and previously each implemented
    /// prefix resolution slightly differently — this is the one place
    /// that logic lives now, so a hash that works in one works in the
    /// other.
    pub fn resolveRev(self: *Repository, raw: []const u8) !Hash {
        return crypto.fromHex(raw) catch {
            return self.store.resolveHashPrefix(raw) catch |err| switch (err) {
                error.Ambiguous => error.AmbiguousRev,
                error.NotFound => error.RevNotFound,
                else => error.InvalidRev,
            };
        };
    }

    pub const UncommitResult = struct {
        undone: Hash,
        /// `null` means the undone commit was the root commit — the
        /// track now has no commits at all, same as before the first
        /// commit was ever made.
        new_head: ?Hash,
    };

    pub const UncommitMode = enum {
        /// Default. Only moves/deletes the ref — staging and worktree
        /// untouched (whatever staging held before uncommit, it still holds).
        soft,
        /// Staging rebuilt from the parent commit's tree (or emptied, at
        /// root); worktree untouched. Delegates to `reset(.mixed)`.
        mixed,
        /// Staging AND worktree rewritten to match the parent commit (or
        /// cleared, at root). Delegates to `reset(.hard)`. Destructive to
        /// any post-commit edits — see `confirm_root_hard` for the root case.
        hard,
        /// Staging rebuilt from CURRENT DISK CONTENT of every tracked path,
        /// so edits made after the commit are preserved as the new staged
        /// state. Fails with `error.TrackedPathsMissing` if any tracked
        /// path was deleted from disk since the commit, rather than
        /// guessing whether that deletion was intentional.
        keep,
    };

    pub const UncommitOptions = struct {
        mode: UncommitMode = .soft,
        /// Must be `true` when `mode == .hard` and the commit being undone
        /// is the repository's root commit. A root has no parent tree to
        /// fall back to, so hard-uncommitting it deletes tracked files from
        /// the worktree with nothing left in any reachable ref pointing at
        /// their content (the blobs survive in the object store, but only
        /// reachable by raw hash). Defaults to `false` so this never
        /// happens without explicit confirmation from the caller/CLI.
        confirm_root_hard: bool = false,
    };

    /// Rehashes every currently-tracked path from disk and rewrites staging
    /// to match — the worktree-facing counterpart to `stagingTreeRoot`, used
    /// by `uncommit(.keep)`. Mirrors `add()`'s mutate-then-save pattern.
    ///
    /// Snapshots the tracked-path list up front: `staging.addFile` mutates
    /// `self.staging`'s internal entry list in place, so looping over
    /// `allEntries()` directly while calling it would walk a slice being
    /// rewritten out from under us.
    ///
    /// Validates that every tracked path still exists before touching
    /// anything — a path missing from disk returns `error.TrackedPathsMissing`
    /// rather than silently dropping it from the new staged tree, since a
    /// missing file might be an intentional cleanup or might not be, and
    /// only the caller can know which.
    fn syncStagingFromDisk(self: *Repository) !void {
        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |p| self.alloc.free(p);
            paths.deinit(self.alloc);
        }
        for (self.staging.allEntries()) |entry| {
            try paths.append(self.alloc, try self.alloc.dupe(u8, entry.path));
        }

        var missing: std.ArrayList([]const u8) = .empty;
        defer missing.deinit(self.alloc); // items borrowed from `paths`, freed there

        for (paths.items) |p| {
            const full_path = try std.fs.path.join(self.alloc, &.{ self.root, p });
            defer self.alloc.free(full_path);
            std.fs.cwd().access(full_path, .{}) catch |err| switch (err) {
                error.FileNotFound => try missing.append(self.alloc, p),
                else => return err,
            };
        }
        if (missing.items.len > 0) return error.TrackedPathsMissing;

        // All present — safe to rehash and persist.
        for (paths.items) |p| _ = try self.staging.addFile(&self.store, self.root, p);
        try self.staging.save();
    }

    /// Deletes every currently-tracked path from the worktree without
    /// touching staging — the root-commit counterpart to `reset(.hard)`'s
    /// worktree rewrite, used only when uncommitting a root commit in
    /// `.hard` mode (there's no parent tree to write instead, only nothing).
    fn deleteTrackedWorktreeFiles(self: *Repository) !void {
        const dir = std.fs.cwd();
        for (self.staging.allEntries()) |entry| {
            const full_path = try std.fs.path.join(self.alloc, &.{ self.root, entry.path });
            defer self.alloc.free(full_path);
            dir.deleteFile(full_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    pub fn uncommit(self: *Repository, uncommit_options: UncommitOptions) !UncommitResult {
        const head_hash = (try self.head()) orelse return error.NoCommits;

        var c = try commit_mod.read(self.alloc, &self.store, head_hash);
        defer c.deinit(self.alloc);

        if (c.parents.len > 1) return error.MergeCommit;
        const parent_hash: ?Hash = if (c.parents.len == 0) null else c.parents[0].hash;

        // Everything below validates and mutates staging/worktree BEFORE
        // touching the ref, so any failure (missing tracked path, missing
        // confirmation) leaves the repository exactly as it was.
        switch (uncommit_options.mode) {
            .soft => {},

            .keep => try self.syncStagingFromDisk(),

            .mixed => {
                if (parent_hash) |ph| {
                    try self.reset(.{ .target = ph, .mode = .mixed }); // reset() moves the ref itself
                } else {
                    try self.staging.replaceAll(&.{});
                }
            },

            .hard => {
                if (parent_hash) |ph| {
                    try self.reset(.{ .target = ph, .mode = .hard }); // reset() moves the ref itself
                } else {
                    if (!uncommit_options.confirm_root_hard) return error.RootHardUncommitRequiresConfirmation;
                    try self.deleteTrackedWorktreeFiles();
                    try self.staging.replaceAll(&.{});
                }
            },
        }

        // .mixed/.hard with a parent already moved the ref via reset() above.
        const ref_already_moved = (parent_hash != null) and
            (uncommit_options.mode == .mixed or uncommit_options.mode == .hard);

        if (!ref_already_moved) {
            if (parent_hash) |ph| {
                try self.ref_store.updateChannel(self.channel.get(), ph);
            } else {
                try self.ref_store.deleteChannel(self.channel.get());
            }
        }

        return .{ .undone = head_hash, .new_head = parent_hash };
    }

    fn headSnapshot(self: *Repository) !Hash {
        const head_hash = (try self.head()) orelse return crypto.zero_hash;
        var c = try commit_mod.read(self.alloc, &self.store, head_hash);
        defer c.deinit(self.alloc);
        return c.snapshot;
    }
};
