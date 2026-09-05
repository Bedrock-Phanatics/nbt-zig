const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nbt = b.addModule("nbt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nbt", .module = nbt }},
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests and compile the benchmark");
    test_step.dependOn(&run_tests.step);

    const bench_nbt = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench = b.addExecutable(.{
        .name = "nbt-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "nbt", .module = bench_nbt }},
        }),
    });
    test_step.dependOn(&bench.step);

    const fuzz_options = b.addOptions();
    fuzz_options.addOption(usize, "iterations", b.option(
        usize,
        "fuzz-iterations",
        "Number of deterministic decoder fuzz cases",
    ) orelse 100_000);
    const fuzz = b.addExecutable(.{
        .name = "nbt-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "nbt", .module = nbt },
                .{ .name = "config", .module = fuzz_options.createModule() },
            },
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz);
    const fuzz_step = b.step("fuzz", "Run deterministic decoder fuzz cases");
    fuzz_step.dependOn(&run_fuzz.step);
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run reproducible ReleaseFast benchmarks");
    bench_step.dependOn(&run_bench.step);
}
