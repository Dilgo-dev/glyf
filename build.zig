// glyf build script.
// Exposes `zig build`, `zig build run`, and `zig build test`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "glyf",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run glyf");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const pty_mod = b.createModule(.{
        .root_source_file = b.path("src/pty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const pty_tests = b.addTest(.{ .root_module = pty_mod });
    const run_pty_tests = b.addRunArtifact(pty_tests);

    const vt_mod = b.createModule(.{
        .root_source_file = b.path("src/vt.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vt_tests = b.addTest(.{ .root_module = vt_mod });
    const run_vt_tests = b.addRunArtifact(vt_tests);

    const grid_mod = b.createModule(.{
        .root_source_file = b.path("src/grid.zig"),
        .target = target,
        .optimize = optimize,
    });
    const grid_tests = b.addTest(.{ .root_module = grid_mod });
    const run_grid_tests = b.addRunArtifact(grid_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_pty_tests.step);
    test_step.dependOn(&run_vt_tests.step);
    test_step.dependOn(&run_grid_tests.step);
}
