const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const Module = Build.Module;
const LazyPath = Build.LazyPath;

const MODULE_NAME = "curl";

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const link_vendor = b.option(bool, "link_vendor", "Whether link with vendored libcurl");

    const libcurl = buildLibcurl(b, target, optimize);
    const module = b.addModule(MODULE_NAME, .{
        .root_source_file = .{ .path = "src/root.zig" },
    });
    if (link_vendor) {
        module.linkLibrary(libcurl);
    }

    try addExample(b, "basic", module, libcurl, target, optimize);
    try addExample(b, "advanced", module, libcurl, target, optimize);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    main_tests.linkLibrary(libcurl);
    main_tests.linkLibC();

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

fn buildLibcurl(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Step.Compile {
    const tls = @import("mbedtls.zig").create(b, target, optimize);
    const zlib = @import("zlib.zig").create(b, target, optimize);
    const libcurl = @import("libcurl.zig").create(b, target, optimize);
    libcurl.linkLibrary(tls);
    libcurl.linkLibrary(zlib);

    b.installArtifact(libcurl);
    return libcurl;
}

fn addExample(
    b: *Build,
    comptime name: []const u8,
    curl_module: *Module,
    libcurl: *Step.Compile,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = LazyPath.relative("examples/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);
    exe.root_module.addImport(MODULE_NAME, curl_module);
    exe.linkLibrary(libcurl);
    exe.linkLibC();

    const run_step = b.step(
        "run-" ++ name,
        std.fmt.comptimePrint("Run {s} example", .{name}),
    );
    run_step.dependOn(&b.addRunArtifact(exe).step);
}
