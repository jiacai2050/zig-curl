const std = @import("std");
const SanitizeC = std.zig.SanitizeC;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const link_vendor = b.option(bool, "link_vendor", "Whether link to vendored libcurl (default: true)");
    const sanitize_c = b.option(SanitizeC, "sanitize_c", "Enable compiler sanitizers (default: null)");
    const mbedtls_pthreads = b.option(bool, "mbedtls_pthreads", "Enable mbedtls pthread support (default: false)");

    const curl_dep = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = link_vendor orelse true,
        .sanitize_c = sanitize_c,
        .mbedtls_pthreads = mbedtls_pthreads orelse false,
    });

    const exe = b.addExecutable(.{
        .name = "downstream-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("curl", curl_dep.module("curl"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the downstream test app");
    run_step.dependOn(&run_cmd.step);
}
