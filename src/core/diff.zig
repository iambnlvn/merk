const algorithms = @import("./diff/diff_algorithms.zig");
const snapshot = @import("./diff/diff_snapshot.zig");
const render_mod = @import("./diff/diff_render.zig");
const patch_mod = @import("./diff/diff_patch.zig");
const interactive_mod = @import("./diff/diff_interactive.zig");

pub const Algorithm = algorithms.Algorithm;
pub const Op = algorithms.Op;
pub const LineDelta = algorithms.LineDelta;
pub const WordDelta = algorithms.WordDelta;
pub const FileDiff = algorithms.FileDiff;
pub const CommitDiff = algorithms.CommitDiff;
pub const FileSnapshot = algorithms.FileSnapshot;

pub const RenderConfig = render_mod.RenderConfig;
pub const Format = render_mod.Format;
pub const Level = render_mod.Level;
pub const Context = render_mod.Context;
pub const GroupBy = render_mod.GroupBy;
pub const FileStatus = render_mod.FileStatus;
pub const ChangeFilter = render_mod.ChangeFilter;
pub const DiffSummary = render_mod.DiffSummary;
pub const DirGroup = render_mod.DirGroup;

pub const HunkRange = patch_mod.HunkRange;
pub const hunkRanges = patch_mod.hunkRanges;
pub const applySelected = patch_mod.applySelected;

pub const InteractiveOutcome = interactive_mod.InteractiveOutcome;
pub const Decision = interactive_mod.Decision;
pub const runInteractive = interactive_mod.run;

pub const diffFile = algorithms.diffFile;
pub const diffFileWith = algorithms.diffFileWith;
pub const diffCommit = algorithms.diffCommit;
pub const diffCommitWith = algorithms.diffCommitWith;

pub const diffSnapshotRoots = snapshot.diffSnapshotRoots;
pub const diffCommits = snapshot.diffCommits;
pub const diffCommitAgainstParent = snapshot.diffCommitAgainstParent;

pub const render = render_mod.renderCommit;
pub const renderFile = render_mod.renderFileDiff;
pub const renderWordDiff = render_mod.renderWordDiff;
pub const summarize = render_mod.summarize;
pub const fileStatus = render_mod.fileStatus;
pub const groupByDirectory = render_mod.groupByDirectory;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
