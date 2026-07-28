const std = @import("std");

const node = @import("node.zig");
const tree = @import("tree.zig");
const diff = @import("diff.zig");

pub const LeafEntry = node.LeafEntry;
pub const ChildRef = node.ChildRef;
pub const Page = node.Page;
pub const DiffError = node.DiffError;

pub const build = tree.build;

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
