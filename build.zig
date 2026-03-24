pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_mod = b.addModule("trex", .{
        .root_source_file = b.path("trex.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Keep the CLI for the repo checkout, but do not require it in the packaged dependency.
    if (std.fs.cwd().access("main.zig", .{})) |_| {
        const exe = b.addExecutable(.{
            .name = "trex",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "trex", .module = lib_mod },
                },
            }),
        });
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.addArgs(b.args orelse &.{});
        const run_step = b.step("run", "Run trex");
        run_step.dependOn(&run_cmd.step);
    } else |_| {}

    // tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_trex.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_run.step);
}

const std = @import("std");
