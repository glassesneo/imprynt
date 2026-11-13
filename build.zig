const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.addModule("imprynt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli = b.addModule("cli", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "imprynt", .module = core }},
        .strip = optimize != .debug,
    });
    const executable = b.addExecutable(.{ .name = "imprynt", .root_module = cli });
    b.installArtifact(executable);
    const cli_tests = b.addTest(.{ .root_module = cli });
    const test_step = b.step("test", "Run unit and isolated filesystem tests");
    const check_step = b.step("check", "Compile tests without running them");
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    check_step.dependOn(&cli_tests.step);
    const tests = b.addTest(.{ .root_module = core });
    check_step.dependOn(&tests.step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
