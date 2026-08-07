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
    /// Owned backing storage for `current_track.raw`.
    current_track_name: []u8,
    current_track: ChannelName,

    /// Create a repository. `fs` must already be rooted at the control
    /// directory. Fails with `error.AlreadyInitialized` if Focus is
    /// already set there, unless `options.force` is set — see
    /// `InitOptions.force`'s doc comment for exactly what force does
    /// and doesn't touch.
    ///
    /// Returns `*Repository`: `History` holds raw `*const Store` /
    /// `*const PageStore` pointers, so `Repository` must live at one
    /// fixed heap address for its whole lifetime — never move or copy
    /// a `Repository` value once one of these has been created.
    pub fn init(alloc: Allocator, fs: Vfs, root: []const u8, init_options: InitOptions) !*Repository {
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
            // `staging.load()` just picked up from the old one.
            try self.staging.resetTo(&self.page_store, crypto.zero_hash);
        }

        try self.staging.save();
        try self.ref_store.setCurrentToChannel(self.current_track);

        return self;
    }

    /// Open an existing repository. `error.NotARepository` if no Focus
    /// file exists yet; `error.DetachedFocus` if Focus points directly
    /// at a commit rather than a track (see `RepositoryError`).
    pub fn open(alloc: Allocator, fs: Vfs, root: []const u8) !*Repository {
        const ref_store = ReferenceStore.init(alloc, fs);
        const state = (try ref_store.currentState()) orelse return error.NotARepository;
        defer state.deinit(alloc);

        const channel_name = switch (state) {
            .symbolic => |s| s,
            .detached => return error.DetachedFocus,
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
        // area gets its own "staging/{root,pages/}" subtree there,
        // separate from the "index/pages" tree `page_store` above uses
        // for commit snapshots.
        self.staging = Staging.init(alloc, fs, "staging");
        errdefer self.staging.deinit();
        try self.staging.load();

        self.root = try alloc.dupe(u8, root);
        errdefer alloc.free(self.root);

        self.current_track_name = try alloc.dupe(u8, channel_name);
        errdefer alloc.free(self.current_track_name);
        self.current_track = try ChannelName.parse(self.current_track_name);

        self.ref_store = ReferenceStore.init(alloc, fs);

        self.history = try History.init(alloc, fs, "history", &self.store, &self.page_store);

        return self;
    }

    pub fn deinit(self: *Repository) void {
        self.staging.deinit();
        self.history.deinit();
        self.alloc.free(self.root);
        self.alloc.free(self.current_track_name);
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

    /// Commit the currently-staged area as a child of the current
    /// track's HEAD (or as a root commit if the track has none yet).
    pub fn commit(self: *Repository, request: CommitRequest) !Hash {
        const repo_head = try self.ref_store.readChannel(self.current_track);

        var parent_buf: [1]ParentInfo = undefined;
        const parents: []const ParentInfo = if (repo_head) |h| blk: {
            parent_buf[0] = .{ .hash = h, .kind = .normal };
            break :blk parent_buf[0..1];
        } else &.{};

        const tree_root = try merkle_mod.build(self.alloc, &self.page_store, self.staging.allEntries());

        return self.history.commit(self.current_track, tree_root, parents, request);
    }

    pub fn status(self: *Repository) !Status {
        const head_snapshot = try self.headSnapshot();
        const staged = try self.staging.diffAgainst(head_snapshot);
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
        return self.staging.diffAgainst(try self.headSnapshot());
    }

    /// Move the current track to `reset_options.target` per
    /// `reset_options.mode`. See `ResetMode` for what each level touches.
    pub fn reset(self: *Repository, reset_options: ResetOptions) !void {
        try self.ref_store.updateChannel(self.current_track, reset_options.target);
        if (reset_options.mode == .soft) return;

        var c = try commit_mod.read(self.alloc, &self.store, reset_options.target);
        defer c.deinit(self.alloc);

        try self.staging.resetTo(&self.page_store, c.snapshot);

        if (reset_options.mode == .hard) try self.writeEntriesToWorktree();
    }

    /// Overwrite specific tracked worktree paths with their staged
    /// content — the worktree-writing half of `restore` (without
    /// `--staged`). Every path must already be tracked, validated up
    /// front so a bad path partway through a multi-path restore doesn't
    /// leave some files overwritten and others not.
    pub fn restorePaths(self: *Repository, paths: []const []const u8) !void {
        for (paths) |p| {
            if (self.staging.lookup(p) == null) return error.NotTracked;
        }
        for (paths) |p| {
            const entry = self.staging.lookup(p).?;
            try self.writeBlobToWorktree(p, entry.blob_hash);
        }
    }

    /// Writes one blob's content to `<root>/<path>` on the real
    /// filesystem, creating parent directories as needed. The one place
    /// staged content gets materialized into the worktree —
    /// `reset(.hard)` and `restorePaths` both go through this instead of
    /// each having their own copy of the join/mkdir/writeFile sequence.
    fn writeBlobToWorktree(self: *Repository, path: []const u8, blob_hash: Hash) !void {
        const dir = std.fs.cwd();
        const obj = try self.store.get(blob_hash);
        defer self.alloc.free(obj.payload);

        const full_path = try std.fs.path.join(self.alloc, &.{ self.root, path });
        defer self.alloc.free(full_path);

        if (std.fs.path.dirname(full_path)) |d| try dir.makePath(d);
        try dir.writeFile(.{ .sub_path = full_path, .data = obj.payload });
    }

    fn writeEntriesToWorktree(self: *Repository) !void {
        for (self.staging.allEntries()) |entry| {
            try self.writeBlobToWorktree(entry.path, entry.blob_hash);
        }
    }

    pub fn log(self: *Repository, filter: history_mod.EdgeFilter) !?history_mod.RevWalk {
        return self.history.log(self.current_track, filter);
    }

    /// Current track's HEAD commit hash, or `null` if the track has no
    /// commits yet. Every history-facing command (`show`, `commit`,
    /// `uncommit`) needs this — public so they read it here instead of
    /// reaching into `ref_store` directly.
    pub fn head(self: *Repository) !?Hash {
        return self.ref_store.readChannel(self.current_track);
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

    /// Moves the current track back one commit (a soft undo — the
    /// staging area is left exactly as it was, so the undone commit's changes stay
    /// staged and ready to edit or re-commit). If HEAD is the root
    /// commit, there's no parent to move to, so this deletes the track's
    /// ref entirely instead — the same "no ref file yet" state every
    /// other command already treats as "no commits" (`head()` returning
    /// `null`, `commit`'s root-commit path).
    ///
    /// Errors with `error.NoCommits` if the track has no commits, or
    /// `error.MergeCommit` if HEAD has more than one parent — uncommit
    /// only supports linear history right now.
    pub fn uncommit(self: *Repository) !UncommitResult {
        const head_hash = (try self.head()) orelse return error.NoCommits;

        var c = try commit_mod.read(self.alloc, &self.store, head_hash);
        defer c.deinit(self.alloc);

        if (c.parents.len > 1) return error.MergeCommit;

        if (c.parents.len == 0) {
            try self.ref_store.deleteChannel(self.current_track);
            return .{ .undone = head_hash, .new_head = null };
        }

        const parent_hash = c.parents[0].hash;
        try self.ref_store.updateChannel(self.current_track, parent_hash);
        return .{ .undone = head_hash, .new_head = parent_hash };
    }

    fn headSnapshot(self: *Repository) !Hash {
        const head_hash = (try self.head()) orelse return crypto.zero_hash;
        var c = try commit_mod.read(self.alloc, &self.store, head_hash);
        defer c.deinit(self.alloc);
        return c.snapshot;
    }
};
