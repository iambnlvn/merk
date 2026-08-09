const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const crypto = b.addModule("crypto", .{
        .root_source_file = b.path("src/crypto/crypto.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compression = b.addModule("compression", .{
        .root_source_file = b.path("src/compression/compression.zig"),
        .target = target,
        .optimize = optimize,
    });
    const storage = b.addModule("storage", .{
        .root_source_file = b.path("src/storage/storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    const merkle = b.addModule("merkle", .{
        .root_source_file = b.path("src/merkle/merkle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "crypto", .module = crypto },
            .{ .name = "storage", .module = storage },
        },
    });
    const merk = b.addModule("merk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "crypto", .module = crypto },
            .{ .name = "compression", .module = compression },
            .{ .name = "storage", .module = storage },
            .{ .name = "merkle", .module = merkle },
        },
    });

    const app_imports = &[_]std.Build.Module.Import{
        .{ .name = "merk", .module = merk },
        .{ .name = "crypto", .module = crypto },
        .{ .name = "compression", .module = compression },
        .{ .name = "storage", .module = storage },
        .{ .name = "merkle", .module = merkle },
    };

    const debug_exe = b.addExecutable(.{
        .name = "merk-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/merk-debug.zig"),
            .target = target,
            .optimize = optimize,
            .imports = app_imports,
        }),
    });
    b.installArtifact(debug_exe);
    b.installArtifact(debug_exe);

    const run_debug = b.addRunArtifact(debug_exe);
    const run_debug_step = b.step("debug", "Run the repository debug/test harness");
    run_debug_step.dependOn(&run_debug.step);

    const exe = b.addExecutable(.{
        .name = "merk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = app_imports,
        }),
    });

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "../dist" } },
    });
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const master_test_step = b.step("test", "Run all tests");

    const mod_tests = b.addRunArtifact(b.addTest(.{ .root_module = merk }));
    const exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));
    master_test_step.dependOn(&mod_tests.step);
    master_test_step.dependOn(&exe_tests.step);

    for (test_groups) |group| {
        var group_step: ?*std.Build.Step = null;

        if (group.step_name) |step_name| {
            group_step = b.step(step_name, group.step_desc);
            master_test_step.dependOn(group_step.?);
        }

        for (group.suites) |suite| {
            const suite_test = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(suite.path),
                    .target = target,
                    .optimize = optimize,
                    .imports = app_imports,
                }),
            });

            const run_suite = b.addRunArtifact(suite_test);
            const suite_step = b.step(suite.name, suite.desc);
            suite_step.dependOn(&run_suite.step);

            if (group_step) |gs| {
                gs.dependOn(suite_step);
            } else {
                master_test_step.dependOn(suite_step);
            }
        }
    }
}

const TestSuite = struct {
    name: []const u8,
    desc: []const u8,
    path: []const u8,
};

const TestGroup = struct {
    step_name: ?[]const u8,
    step_desc: []const u8 = "",
    suites: []const TestSuite,
};

/// Declarative list of all test groups and their specific suite files.
const test_groups = [_]TestGroup{
    .{
        .step_name = "test-refs-subsystem",
        .step_desc = "Run all refs subsystem tests",
        .suites = &.{
            .{
                .name = "test-refs",
                .desc = "Run refs subsystem tests",
                .path = "src/core/refs/refs.zig",
            },
            .{
                .name = "test-current",
                .desc = "Run current unit tests",
                .path = "src/core/refs/current.zig",
            },
        },
    },
    .{
        .step_name = "test-object",
        .step_desc = "Run object unit tests",
        .suites = &.{
            .{
                .name = "test-obj",
                .desc = "Run object unit tests",
                .path = "src/core/object/object.zig",
            },
            .{
                .name = "test-object-format",
                .desc = "Run current unit tests",
                .path = "src/core/object/object_format.zig",
            },
        },
    },
    .{
        .step_name = null, // Merged directly into the master `test` step
        .suites = &.{
            .{
                .name = "test-staging",
                .desc = "Run staging area unit tests",
                .path = "src/core/staging.zig",
            },
            .{
                .name = "test-history",
                .desc = "Run history unit tests",
                .path = "src/core/history.zig",
            },
            .{
                .name = "test-repo",
                .desc = "Run repo unit tests",
                .path = "src/core/repository.zig",
            },
        },
    },
    .{
        .step_name = "test-diff",
        .step_desc = "Run all diff module tests",
        .suites = &.{
            .{
                .name = "test-diff-algorithms",
                .desc = "Run diff algorithm tests",
                .path = "src/core/diff/diff_algorithms.zig",
            },
            .{
                .name = "test-diff-snapshot",
                .desc = "Run diff snapshot tests",
                .path = "src/core/diff.zig",
            },
            .{
                .name = "test-diff-render",
                .desc = "Run diff render unit tests",
                .path = "src/core/diff/diff_render.zig",
            },
        },
    },
    .{
        .step_name = "test-merkle",
        .step_desc = "Run all merkle subsystem tests",
        .suites = &.{
            .{
                .name = "test-merkle-diff",
                .desc = "Run merkle diff unit tests",
                .path = "src/merkle/diff.zig",
            },
            .{
                .name = "test-merkle-entry",
                .desc = "Run merkle entry unit tests",
                .path = "src/merkle/entry.zig",
            },
            .{
                .name = "test-merkle-page",
                .desc = "Run merkle node unit tests",
                .path = "src/merkle/page_store.zig",
            },
            .{
                .name = "test-merkle-tree",
                .desc = "Run merkle tree unit tests",
                .path = "src/merkle/tree.zig",
            },
        },
    },
    .{
        .step_name = "test-commit",
        .step_desc = "Run all commit subsystem tests",
        .suites = &.{
            .{
                .name = "test-commit-deps",
                .desc = "Run dep unit tests",
                .path = "src/core/commit/dependency.zig",
            },
            .{
                .name = "test-commit-identity",
                .desc = "Run commit identity tests",
                .path = "src/core/commit/identity.zig",
            },
            .{
                .name = "test-commit-message",
                .desc = "Run commit message tests",
                .path = "src/core/commit/message.zig",
            },
            .{
                .name = "test-commit-metadata",
                .desc = "Run commit metadata tests",
                .path = "src/core/commit/metadata.zig",
            },
            .{
                .name = "test-commit-parent",
                .desc = "Run commit parent tests",
                .path = "src/core/commit/parent.zig",
            },
            .{
                .name = "test-commit-signature",
                .desc = "Run commit signature tests",
                .path = "src/core/commit/signature.zig",
            },
            .{
                .name = "test-commit-snapshot",
                .desc = "Run commit snapshot tests",
                .path = "src/core/commit/snapshot.zig",
            },
            .{
                .name = "test-commit-wire",
                .desc = "Run commit wire tree tests",
                .path = "src/core/commit/wire.zig",
            },
        },
    },
};
