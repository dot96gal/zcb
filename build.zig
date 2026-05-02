const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zcb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const docs_obj = b.addObject(.{
        .name = "zcb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build API documentation");
    docs_step.dependOn(&install_docs.step);

    const example_basic = b.addExecutable(.{
        .name = "example-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcb", .module = mod },
            },
        }),
    });

    const run_example_basic = b.addRunArtifact(example_basic);
    if (b.args) |args| run_example_basic.addArgs(args);

    const run_example_basic_step = b.step("run-example-basic", "Run basic example");
    run_example_basic_step.dependOn(&run_example_basic.step);

    const example_allow_done = b.addExecutable(.{
        .name = "example-allow-done",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/allow_done.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcb", .module = mod },
            },
        }),
    });

    const run_example_allow_done = b.addRunArtifact(example_allow_done);
    if (b.args) |args| run_example_allow_done.addArgs(args);

    const run_example_allow_done_step = b.step("run-example-allow-done", "Run allow/done example");
    run_example_allow_done_step.dependOn(&run_example_allow_done.step);
}
