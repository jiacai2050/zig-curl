const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const Module = Build.Module;
const Allocator = std.mem.Allocator;
const SanitizeC = std.zig.SanitizeC;

const MODULE_NAME = "curl";
const EXAMPLE_NAMES = .{ "basic", "post", "upload", "advanced", "multi", "header" };

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const link_vendor = b.option(bool, "link_vendor", "Whether link to vendored libcurl (default: true)") orelse true;
    const sanitize_c = b.option(SanitizeC, "sanitize_c", "Enable compiler sanitizers (default: null)");
    const mbedtls_pthreads = b.option(bool, "mbedtls_pthreads", "Enable mbedtls pthread support (default: false)") orelse false;
    const manifest = try parseManifest(b);
    defer manifest.deinit(b.allocator);

    // Register the "curl" module unconditionally so consumers can always call `dep.module("curl")`
    const module = b.addModule(MODULE_NAME, .{
        .root_source_file = b.path("src/root.zig"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });

    const opt = b.addOptions();
    opt.addOption([]const u8, "version", manifest.version);
    module.addImport("build_info", opt.createModule());

    // Resolve backend and vendor dependencies before configuring C bindings
    var curl_include_path: ?std.Build.LazyPath = null;
    if (link_vendor) {
        const curl_dep = b.lazyDependency("curl", .{});
        const mbedtls_dep = b.lazyDependency("mbedtls", .{});
        const zlib_dep = b.lazyDependency("zlib", .{});

        // Exit early if any vendor dependency is not yet downloaded, enabling concurrent fetching
        if (curl_dep == null or mbedtls_dep == null or zlib_dep == null) {
            return;
        }

        const libcurl = buildLibcurl(b, target, optimize, sanitize_c, mbedtls_pthreads, curl_dep.?, mbedtls_dep.?, zlib_dep.?);
        curl_include_path = curl_dep.?.path("include");
        module.linkLibrary(libcurl);
    } else {
        module.linkSystemLibrary("curl", .{});
    }

    // Setup C bindings only after dependencies and include paths are fully resolved
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    if (curl_include_path) |include_path| {
        translate_c.addIncludePath(include_path);
    } else {
        translate_c.linkSystemLibrary("curl", .{});
    }
    module.addImport("c", translate_c.createModule());

    inline for (EXAMPLE_NAMES) |name| {
        try addExample(b, name, module, target, optimize);
    }

    const main_tests = b.addTest(.{
        .root_module = module,
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const doc_obj = b.addObject(.{
        .name = "docs",
        .root_module = module,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = doc_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    const check_step = b.step("check", "Used for checking the library and examples");
    check_step.dependOn(&main_tests.step);
    inline for (EXAMPLE_NAMES) |name| {
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
    mbedtls_pthreads: bool,
    curl_dep: *Build.Dependency,
    mbedtls_dep: *Build.Dependency,
    zlib_dep: *Build.Dependency,
) *Step.Compile {
    const libcurl = @import("libs/curl.zig").create(b, target, optimize, sanitize_c, mbedtls_pthreads, curl_dep);
    const tls = @import("libs/mbedtls.zig").create(b, target, optimize, sanitize_c, mbedtls_pthreads, mbedtls_dep);
    const zlib = @import("libs/zlib.zig").create(b, target, optimize, sanitize_c, zlib_dep);

    libcurl.root_module.linkLibrary(tls);
    libcurl.root_module.linkLibrary(zlib);
    return libcurl;
}

fn addExample(
    b: *Build,
    comptime name: []const u8,
    curl_module: *Module,
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
    const parsed = std.zon.parse.fromSliceAlloc(
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
