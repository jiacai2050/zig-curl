const std = @import("std");
const Build = std.Build;
const Module = Build.Module;
const LazyPath = Build.LazyPath;

const MODULE_NAME = "curl";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule(MODULE_NAME, .{
        .source_file = .{ .path = "src/main.zig" },
    });

    const libcurl = b.dependency("libcurl", .{ .target = target, .optimize = optimize });
    b.installArtifact(libcurl.artifact("curl"));

    try addExample(b, "basic", module, libcurl, target, optimize);
    try addExample(b, "advanced", module, libcurl, target, optimize);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.addModule(MODULE_NAME, module);
    main_tests.linkLibrary(libcurl.artifact("curl"));

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

fn addExample(
    b: *std.Build,
    comptime name: []const u8,
    curl_module: *Module,
    libcurl: *Build.Dependency,
    target: std.zig.CrossTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = LazyPath.relative("examples/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);
    exe.addModule(MODULE_NAME, curl_module);
    exe.linkLibrary(libcurl.artifact("curl"));

    const run_step = b.step("run-" ++ name, std.fmt.comptimePrint("Run {s} example", .{name}));
    run_step.dependOn(&b.addRunArtifact(exe).step);
}
