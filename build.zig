const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.addModule("imprynt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = core });
    b.step("check", "Compile tests without running them").dependOn(&tests.step);
    b.step("test", "Run unit and isolated filesystem tests").dependOn(&b.addRunArtifact(tests).step);
}
