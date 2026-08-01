const std = @import("std");

fn makeTestModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    merk: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "merk", .module = merk },
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
) *std.Build.Step {
    const tests = b.addTest(.{
        .root_module = makeTestModule(
            b,
            path,
            target,
            optimize,
            merk,
        ),
    });

    const run = b.addRunArtifact(tests);

    const step = b.step(name, description);
    step.dependOn(&run.step);

    return step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("merk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "merk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "merk", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const refs_step = addModuleTest(
        b,
        "test-refs",
        "Run refs subsystem tests",
        "src/core/refs/refs.zig",
        target,
        optimize,
        mod,
    );

    const focus_step = addModuleTest(
        b,
        "test-focus",
        "Run focus unit tests",
        "src/core/refs/focus.zig",
        target,
        optimize,
        mod,
    );
    const obj_step = addModuleTest(
        b,
        "test-object",
        "Run object unit tests",
        "src/core/object/object.zig",
        target,
        optimize,
        mod,
    );

    const commit_step = addModuleTest(
        b,
        "test-commit",
        "Run commit unit tests",
        "src/core/commit.zig",
        target,
        optimize,
        mod,
    );

    const index_step = addModuleTest(
        b,
        "test-index",
        "Run index unit tests",
        "src/core/index.zig",
        target,
        optimize,
        mod,
    );

    const history_step = addModuleTest(
        b,
        "test-history",
        "Run history unit tests",
        "src/core/history.zig",
        target,
        optimize,
        mod,
    );
    test_step.dependOn(refs_step);
    test_step.dependOn(focus_step);
    test_step.dependOn(obj_step);
    test_step.dependOn(commit_step);
    test_step.dependOn(index_step);
    test_step.dependOn(history_step);
}
