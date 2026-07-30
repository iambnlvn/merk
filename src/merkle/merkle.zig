const std = @import("std");

const node = @import("node.zig");
const tree = @import("tree.zig");
const diff = @import("diff.zig");
const entry = @import("entry.zig");
const page_store = @import("page_store.zig");

pub const MAGIC = node.MAGIC;
pub const VERSION = node.VERSION;
pub const PAGE_SIZE = node.PAGE_SIZE;
pub const LEAF_PAGE = node.LEAF_PAGE;
pub const INTERNAL_PAGE = node.INTERNAL_PAGE;
pub const PathKey = node.PathKey;
pub const DiffError = node.DiffError;
pub const LeafEntry = node.LeafEntry;
pub const ChildRef = node.ChildRef;
pub const Page = node.Page;
pub const hashEq = node.hashEq;
pub const foldHashPrefix = node.foldHashPrefix;
pub const build = tree.build;

pub const Entry = entry.Entry;
pub const WorktreeState = entry.WorktreeState;
pub const ChangeKind = entry.ChangeKind;
pub const EntryChange = entry.EntryChange;
pub const freeChanges = entry.freeChanges;
pub const pathKey = entry.pathKey;
pub const pathLessThan = entry.pathLessThan;
pub const validatePath = entry.validatePath;

pub const collect = tree.collect;

pub const PageStore = page_store.PageStore;

pub const diffRoots = diff.diffRoots;

test {
    _ = @import("entry.zig");
    // Forces the test runner to walk into every submodule's test blocks,
    // regardless of whether the runtime call graph reaches them — otherwise
    // a file only ever called from inside another merkle/ file (never
    // imported at a level zig build test's root reaches) can have its tests
    // silently skipped rather than erroring.
    std.testing.refAllDecls(@This());
}
