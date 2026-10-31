const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mp3 = b.addModule("mp3", .{
        .root_source_file = b.path("src/mp3/mp3.zig"),
        .target = target,
        .optimize = optimize,
    });

    const player = b.addModule("player", .{
        .root_source_file = b.path("src/player.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Audio output goes through the default-output AudioUnit (see coreaudio.zig).
    if (target.result.os.tag == .macos) player.linkFramework("AudioToolbox", .{});

    const exe = b.addExecutable(.{
        .name = "fauxlkman",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mp3", .module = mp3 },
                .{ .name = "player", .module = player },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run fauxlkman").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    const mp3_tests = b.addTest(.{ .root_module = mp3 });
    test_step.dependOn(&b.addRunArtifact(mp3_tests).step);
    const player_tests = b.addTest(.{ .root_module = player });
    test_step.dependOn(&b.addRunArtifact(player_tests).step);
    const creation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/creation_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "player", .module = player }},
    }) });
    test_step.dependOn(&b.addRunArtifact(creation_tests).step);
}
