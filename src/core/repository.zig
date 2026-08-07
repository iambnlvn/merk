const repository = @import("./repo/repo.zig");

pub const Repository = repository.Repository;

pub const RepositoryError = repository.RepositoryError;
pub const describe = repository.describe;

pub const InitOptions = repository.InitOptions;
pub const RemoveOptions = repository.RemoveOptions;
pub const MoveOptions = repository.MoveOptions;
pub const ResetMode = repository.ResetMode;
pub const ResetOptions = repository.ResetOptions;

pub const Status = repository.Status;
pub const WorktreeEntryStatus = repository.WorktreeEntryStatus;
pub const UncommitResult = repository.Repository.UncommitResult;

test {
    _ = @import("./repo/repo.zig");
    _ = @import("./repo/repo_test.zig");
    _ = @import("./repo/options.zig");
    _ = @import("./repo/status.zig");
    _ = @import("./repo/errors.zig");
}
