const algorithms = @import("./diff/diff_algorithms.zig");
const interactive_mod = @import("./diff/diff_interactive.zig");
const patch_mod = @import("./diff/diff_patch.zig");
const render_mod = @import("./diff/diff_render.zig");
const snapshot = @import("./diff/diff_snapshot.zig");

pub const Algorithm = algorithms.Algorithm;
pub const CommitDiff = algorithms.CommitDiff;
pub const FileDiff = algorithms.FileDiff;

pub const diffFile = algorithms.diffFile;
pub const diffFileWith = algorithms.diffFileWith;

pub const runInteractive = interactive_mod.run;

pub const ChangeFilter = render_mod.ChangeFilter;
pub const Context = render_mod.Context;

pub const Format = render_mod.Format;
pub const GroupBy = render_mod.GroupBy;
pub const Level = render_mod.Level;
pub const RenderConfig = render_mod.RenderConfig;
pub const DiffSummary = render_mod.DiffSummary;
pub const fileStatus = render_mod.fileStatus;
pub const groupByDirectory = render_mod.groupByDirectory;
pub const renderCommit = render_mod.renderCommit;
pub const renderFileDiff = render_mod.renderFileDiff;
pub const renderFiltered = render_mod.renderFiltered;
pub const summarize = render_mod.summarize;
pub const diffCommitAgainstParent = snapshot.diffCommitAgainstParent;
pub const diffCommits = snapshot.diffCommits;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
