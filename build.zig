const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mp3 = b.addModule("mp3", .{
        .root_source_file = b.path("src/mp3/mp3.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "fauxlkman",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mp3", .module = mp3 }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run fauxlkman").dependOn(&run_cmd.step);

    const mp3_tests = b.addTest(.{ .root_module = mp3 });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(mp3_tests).step);
}
