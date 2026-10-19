const std = @import("std");
const Phpz = @import("phpz").Phpz;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const php_include_dir = b.option([]const u8, "php-include-dir", "PHP include directory") orelse "/usr/include/php";

    const phpz = Phpz.init(b.dependency("phpz", .{}), .{
        .translator = .{
            .c_source_file = b.path("nbt_bench.h"),
            .target = target,
            .optimize = optimize,
        },
        .php_include_dir = .{ .cwd_relative = php_include_dir },
        .shared = true,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("nbt", b.dependency("nbt", .{ .target = target, .optimize = optimize }).module("nbt"));

    const extension = phpz.addExtension(b, .{ .name = "nbt_bench", .root_module = root_module });
    const info = b.addOptions();
    info.addOption([:0]const u8, "name", "nbt_bench");
    info.addOption([:0]const u8, "version", "0.1.0");
    extension.root_module.addOptions("extension_info", info);

    const copy = std.Build.Step.UpdateSourceFiles.create(b);
    copy.addCopyFileToSource(extension.getEmittedBin(), "modules/nbt_bench.so");
    b.getInstallStep().dependOn(&copy.step);
}
