//NOTE: this is commented out for now, i still like it as it reads better than
//this current build, I'll rewrite it once I find a middle ground between the two

// const std = @import("std");

// fn makeTestModule(
//     b: *std.Build,
//     path: []const u8,
//     target: std.Build.ResolvedTarget,
//     optimize: std.builtin.OptimizeMode,
//     merk: *std.Build.Module,
// ) *std.Build.Module {
//     return b.createModule(.{
//         .root_source_file = b.path(path),
//         .target = target,
//         .optimize = optimize,
//         .imports = &.{
//             .{ .name = "merk", .module = merk },
//         },
//     });
// }

// fn addModuleTest(
//     b: *std.Build,
//     name: []const u8,
//     description: []const u8,
//     path: []const u8,
//     target: std.Build.ResolvedTarget,
//     optimize: std.builtin.OptimizeMode,
//     merk: *std.Build.Module,
// ) *std.Build.Step {
//     const tests = b.addTest(.{
//         .root_module = makeTestModule(
//             b,
//             path,
//             target,
//             optimize,
//             merk,
//         ),
//     });

//     const run = b.addRunArtifact(tests);

//     const step = b.step(name, description);
//     step.dependOn(&run.step);

//     return step;
// }

// pub fn build(b: *std.Build) void {
//     const target = b.standardTargetOptions(.{});
//     const optimize = b.standardOptimizeOption(.{});
//     const mod = b.addModule("merk", .{
//         .root_source_file = b.path("src/root.zig"),
//         .target = target,
//     });

//     const exe = b.addExecutable(.{
//         .name = "merk",
//         .root_module = b.createModule(.{
//             .root_source_file = b.path("src/main.zig"),

//             .target = target,
//             .optimize = optimize,
//             .imports = &.{
//                 .{ .name = "merk", .module = mod },
//             },
//         }),
//     });

//     b.installArtifact(exe);

//     const run_step = b.step("run", "Run the app");

//     const run_cmd = b.addRunArtifact(exe);
//     run_step.dependOn(&run_cmd.step);

//     run_cmd.step.dependOn(b.getInstallStep());

//     if (b.args) |args| {
//         run_cmd.addArgs(args);
//     }

//     const mod_tests = b.addTest(.{
//         .root_module = mod,
//     });

//     const run_mod_tests = b.addRunArtifact(mod_tests);

//     const exe_tests = b.addTest(.{
//         .root_module = exe.root_module,
//     });

//     const run_exe_tests = b.addRunArtifact(exe_tests);

//     const test_step = b.step("test", "Run all tests");
//     test_step.dependOn(&run_mod_tests.step);
//     test_step.dependOn(&run_exe_tests.step);

//     const refs_step = addModuleTest(
//         b,
//         "test-refs",
//         "Run refs subsystem tests",
//         "src/core/refs/refs.zig",
//         target,
//         optimize,
//         mod,
//     );

//     const focus_step = addModuleTest(
//         b,
//         "test-focus",
//         "Run focus unit tests",
//         "src/core/refs/focus.zig",
//         target,
//         optimize,
//         mod,
//     );
//     const obj_step = addModuleTest(
//         b,
//         "test-object",
//         "Run object unit tests",
//         "src/core/object/object.zig",
//         target,
//         optimize,
//         mod,
//     );

//     const commit_step = addModuleTest(
//         b,
//         "test-commit",
//         "Run commit unit tests",
//         "src/core/commit.zig",
//         target,
//         optimize,
//         mod,
//     );

//     const index_step = addModuleTest(
//         b,
//         "test-index",
//         "Run index unit tests",
//         "src/core/index.zig",
//         target,
//         optimize,
//         mod,
//     );

//     const history_step = addModuleTest(
//         b,
//         "test-history",
//         "Run history unit tests",
//         "src/core/history.zig",
//         target,
//         optimize,
//         mod,
//     );

//     const diff_algorithms_step = addModuleTest(
//         b,
//         "test-diff-algorithms",
//         "Run diff algorithm engine unit tests",
//         "src/core/diff/diff_algorithms.zig",
//         target,
//         optimize,
//         mod,
//     );

//     const diff_snapshot_step = addModuleTest(
//         b,
//         "test-diff-snapshot",
//         "Run diff snapshot/merkle adapter unit tests",
//         "src/core/diff.zig",
//         target,
//         optimize,
//         mod,
//     );

//     const diff_render_step = addModuleTest(
//         b,
//         "test-diff-render",
//         "Run diff render unit tests",
//         "src/core/diff/diff_render.zig",
//         target,
//         optimize,
//         mod,
//     );

//     const diff_step = b.step("test-diff", "Run all diff module tests");
//     diff_step.dependOn(diff_algorithms_step);
//     diff_step.dependOn(diff_snapshot_step);
//     diff_step.dependOn(diff_render_step);

//     test_step.dependOn(refs_step);
//     test_step.dependOn(focus_step);
//     test_step.dependOn(obj_step);
//     test_step.dependOn(commit_step);
//     test_step.dependOn(index_step);
//     test_step.dependOn(history_step);
//     test_step.dependOn(diff_step);
// }

const std = @import("std");

fn makeTestModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    merk: *std.Build.Module,
    crypto: *std.Build.Module,
    compression: *std.Build.Module,
    storage: *std.Build.Module,
    merkle: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "merk", .module = merk },
            .{ .name = "crypto", .module = crypto },
            .{ .name = "compression", .module = compression },
            .{ .name = "storage", .module = storage },
            .{ .name = "merkle", .module = merkle },
        },
    });
}

fn addModuleTest(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    merk: *std.Build.Module,
    crypto: *std.Build.Module,
    compression: *std.Build.Module,
    storage: *std.Build.Module,
    merkle: *std.Build.Module,
) *std.Build.Step {
    const tests = b.addTest(.{
        .root_module = makeTestModule(b, path, target, optimize, merk, crypto, compression, storage, merkle),
    });

    const run = b.addRunArtifact(tests);
    const step = b.step(name, description);
    step.dependOn(&run.step);

    return step;
}

const TestSuite = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
};

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
    const mod = b.addModule("merk", .{
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

    const exe = b.addExecutable(.{
        .name = "merk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "merk", .module = mod },
                .{ .name = "crypto", .module = crypto },
                .{ .name = "compression", .module = compression },
                .{ .name = "storage", .module = storage },
                .{ .name = "merkle", .module = merkle },
            },
        }),
    });

    const install_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{
        .custom = "../dist",
    } } });

    b.getInstallStep().dependOn(&install_exe.step);

    // Run application step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Master test step
    const test_step = b.step("test", "Run all tests");

    // Root module & executable validation tests
    const mod_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    const exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));
    test_step.dependOn(&mod_tests.step);
    test_step.dependOn(&exe_tests.step);

    const refs_specs = [_]TestSuite{
        .{ .name = "test-refs", .description = "Run refs subsystem tests", .path = "src/core/refs/refs.zig" },
        .{ .name = "test-focus", .description = "Run focus unit tests", .path = "src/core/refs/focus.zig" },
    };
    const refs_step = b.step("test-refs-subsystem", "Run all refs subsystem tests");
    registerSuite(b, &refs_specs, refs_step, test_step, target, optimize, mod, crypto, compression, storage, merkle);

    const core_specs = [_]TestSuite{
        .{ .name = "test-object", .description = "Run object unit tests", .path = "src/core/object/object.zig" },
        .{ .name = "test-commit", .description = "Run commit unit tests", .path = "src/core/commit.zig" },
        .{ .name = "test-staging", .description = "Run staging area unit tests", .path = "src/core/staging.zig" },
        .{ .name = "test-history", .description = "Run history unit tests", .path = "src/core/history.zig" },
    };
    registerSuite(b, &core_specs, null, test_step, target, optimize, mod, crypto, compression, storage, merkle);

    const diff_algorithms_step = addModuleTest(b, "test-diff-algorithms", "Run diff algorithm engine unit tests", "src/core/diff/diff_algorithms.zig", target, optimize, mod, crypto, compression, storage, merkle);
    const diff_snapshot_step = addModuleTest(b, "test-diff-snapshot", "Run diff snapshot/merkle adapter unit tests", "src/core/diff.zig", target, optimize, mod, crypto, compression, storage, merkle);
    const diff_render_step = addModuleTest(b, "test-diff-render", "Run diff render unit tests", "src/core/diff/diff_render.zig", target, optimize, mod, crypto, compression, storage, merkle);

    const diff_step = b.step("test-diff", "Run all diff module tests");
    const repo_step = addModuleTest(b, "test-repo", "Run repo unit tests", "src/core/repository.zig", target, optimize, mod, crypto, compression, storage, merkle);

    const merkle_specs = [_]TestSuite{
        .{ .name = "test-merkle-diff", .description = "Run merkle diff unit tests", .path = "src/merkle/diff.zig" },
        .{ .name = "test-merkle-entry", .description = "Run merkle entry unit tests", .path = "src/merkle/entry.zig" },
        .{ .name = "test-merkle-page", .description = "Run merkle node unit tests", .path = "src/merkle/page_store.zig" },
        .{ .name = "test-merkle-tree", .description = "Run merkle tree unit tests", .path = "src/merkle/tree.zig" },
    };

    const merkle_step = b.step("test-merkle", "Run all mekle subsystem tests");

    registerSuite(b, &merkle_specs, merkle_step, test_step, target, optimize, mod, crypto, compression, storage, merkle);

    diff_step.dependOn(diff_algorithms_step);
    diff_step.dependOn(diff_snapshot_step);
    diff_step.dependOn(diff_render_step);
    test_step.dependOn(diff_step);
    test_step.dependOn(repo_step);
}

/// Helper function to loop through a slice of test suites, register individual steps,
/// and optionally tie them together into a unified subsystem parent step.
fn registerSuite(
    b: *std.Build,
    specs: []const TestSuite,
    subsystem_step: ?*std.Build.Step,
    master_test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
    crypto: *std.Build.Module,
    compression: *std.Build.Module,
    storage: *std.Build.Module,
    merkle: *std.Build.Module,
) void {
    for (specs) |suite| {
        const step = addModuleTest(b, suite.name, suite.description, suite.path, target, optimize, mod, crypto, compression, storage, merkle);
        if (subsystem_step) |sub| {
            sub.dependOn(step);
        }
        master_test_step.dependOn(step);
    }
    if (subsystem_step) |sub| {
        master_test_step.dependOn(sub);
    }
}
