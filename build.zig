const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const Module = Build.Module;

const MODULE_NAME = "curl";

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const link_vendor = b.option(bool, "link_vendor", "Whether link to vendored libcurl (default: true)") orelse true;

    const module = b.addModule(MODULE_NAME, .{
        .root_source_file = b.path("src/root.zig"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });

    var libcurl: ?*Step.Compile = null;
    if (link_vendor) {
        if (buildLibcurl(b, target, optimize)) |v| {
            libcurl = v;
            module.linkLibrary(v);
        } else {
            return;
        }
    }

    try addExample(b, "basic", module, libcurl, target, optimize);
    try addExample(b, "advanced", module, libcurl, target, optimize);
    try addExample(b, "multi", module, libcurl, target, optimize);
    try addExample(b, "header", module, libcurl, target, optimize);

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (libcurl) |lib| {
        main_tests.linkLibrary(lib);
    } else {
        main_tests.linkSystemLibrary("curl");
    }

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const check_step = b.step("check", "Used for checking the library");
    inline for (.{ "basic", "advanced", "multi" }) |name| {
        const check_exe = b.addExecutable(.{
            .name = "check-" ++ name,
            .root_source_file = b.path("examples/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        check_exe.root_module.addImport(MODULE_NAME, module);
        check_step.dependOn(&check_exe.step);
    }
}

fn buildLibcurl(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*Step.Compile {
    const curl = @import("libs/curl.zig").create(b, target, optimize);
    const tls = @import("libs/mbedtls.zig").create(b, target, optimize);
    const zlib = @import("libs/zlib.zig").create(b, target, optimize);
    if (curl == null or tls == null or zlib == null) {
        return null;
    }

    const libcurl = curl.?;
    libcurl.linkLibrary(tls.?);
    libcurl.linkLibrary(zlib.?);
    return libcurl;
}

fn addExample(
    b: *Build,
    comptime name: []const u8,
    curl_module: *Module,
    libcurl: ?*Step.Compile,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("examples/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    b.installArtifact(exe);

    exe.root_module.addImport(MODULE_NAME, curl_module);
    if (libcurl) |lib| {
        exe.linkLibrary(lib);
    } else {
        exe.linkSystemLibrary("curl");
    }

    const run_step = b.step(
        "run-" ++ name,
        std.fmt.comptimePrint("Run {s} example", .{name}),
    );
    run_step.dependOn(&b.addRunArtifact(exe).step);
}
