const std = @import("std");
const stderr = std.io.getStdErr().writer();

const project_name = "x86-jit";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common = b.dependency("zighh", .{}).module("common");
    const blox = b.dependency("blox", .{}).module("blox");

    // module
    const mod = b.addModule(project_name, .{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &.{
            .{ .name = "common", .module = common },
            .{ .name = "blox", .module = blox },
        },
    });

    // example
    const example = b.addExecutable(.{
        .name = "example",
        .root_source_file = .{ .path = "example/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    example.addModule("blox", blox);
    example.addModule(project_name, mod);

    const install = b.addInstallArtifact(example, .{});
    const install_step = b.step("example", "install the example");
    install_step.dependOn(&install.step);

    // run example
    const run = b.addRunArtifact(example);
    run.step.dependOn(&example.step);
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "run the example");
    run_step.dependOn(&run.step);

    // test
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    unit_tests.addModule("common", common);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
