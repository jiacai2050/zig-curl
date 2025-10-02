const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const Module = Build.Module;
const Allocator = std.mem.Allocator;
const SanitizeC = std.zig.SanitizeC;

const MODULE_NAME = "curl";

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const link_vendor = b.option(bool, "link_vendor", "Whether link to vendored libcurl (default: true)") orelse true;
    const sanitize_c = b.option(SanitizeC, "sanitize_c", "Enable compiler sanitizers (default: null)");

    const module = b.addModule(MODULE_NAME, .{
        .root_source_file = b.path("src/root.zig"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    const manifest = try parseManifest(b);
    defer manifest.deinit(b.allocator);

    const opt = b.addOptions();
    opt.addOption([]const u8, "version", manifest.version);
    module.addImport("build_info", opt.createModule());

    var libcurl: ?*Step.Compile = null;
    if (link_vendor) {
        if (buildLibcurl(b, target, optimize, sanitize_c)) |v| {
            libcurl = v;
            module.linkLibrary(v);
        } else {
            return;
        }
    }

    inline for (.{ "basic", "post", "upload", "advanced", "multi", "header" }) |name| {
        try addExample(b, name, module, libcurl, target, optimize);
    }

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        }),
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
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .link_libc = true,
                .target = target,
                .optimize = optimize,
            }),
        });

        check_exe.root_module.addImport(MODULE_NAME, module);
        check_step.dependOn(&check_exe.step);
    }
}

fn buildLibcurl(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_c: ?std.zig.SanitizeC,
) ?*Step.Compile {
    const curl = @import("libs/curl.zig").create(b, target, optimize, sanitize_c);
    const tls = @import("libs/mbedtls.zig").create(b, target, optimize, sanitize_c);
    const zlib = @import("libs/zlib.zig").create(b, target, optimize, sanitize_c);
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
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
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

const Manifest = struct {
    version: []const u8,

    fn deinit(self: Manifest, allocator: Allocator) void {
        allocator.free(self.version);
    }
};

fn parseManifest(b: *Build) !Manifest {
    const input = @embedFile("build.zig.zon");
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(b.allocator);
    const parsed = std.zon.parse.fromSlice(
        Manifest,
        b.allocator,
        input,
        &diagnostics,
        .{ .free_on_error = true, .ignore_unknown_fields = true },
    ) catch |err| {
        std.debug.print("Parse diagnostics:\n{f}\n", .{diagnostics});
        return err;
    };

    return parsed;
}
