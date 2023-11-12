const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = std.zig.CrossTarget.parse(.{
        .arch_os_abi = "x86_64-linux",
    }) catch unreachable;

    const optimize = b.standardOptimizeOption(.{});

    const common = b.dependency("zighh", .{}).module("common");

    const exe = b.addExecutable(.{
        .name = "forthlike-x86-jit",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("common", common);
    b.installArtifact(exe);

    // run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // test
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    unit_tests.addModule("common", common);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
