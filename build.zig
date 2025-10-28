const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");

    const sgr = b.addModule("sgr", .{
        .root_source_file = b.path("sgr.zig"),

        .target = target,
        .optimize = optimize,
    });

    const kompot = b.addModule("kompot", .{
        .root_source_file = b.path("src/root.zig"),

        .imports = &.{},

        .target = target,
        .optimize = optimize,
    });

    {
        const kompot_tests = b.addTest(.{
            .name = "kompot_tests",

            .root_module = kompot,

            .use_llvm = true,

            // .test_runner = .{
            //     .path = b.path("test_runner.zig"),
            //     .mode = .simple,
            // },
        });
        kompot_tests.root_module.addImport("kompot", kompot);
        kompot_tests.root_module.addImport("sgr", sgr);

        var run_kompot_tests = b.addRunArtifact(kompot_tests);
        run_kompot_tests.has_side_effects = true;
        test_step.dependOn(&run_kompot_tests.step);
    }
}
