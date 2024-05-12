const std = @import("std");

pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "z",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zlib_dep = b.lazyDependency("zlib", .{
        .target = target,
        .optimize = optimize,
    }) orelse return null;

    inline for (srcs) |s| {
        lib.addCSourceFile(.{
            .file = zlib_dep.path(s),
            .flags = &.{"-std=c89"},
        });
    }
    lib.installHeader(zlib_dep.path("zlib.h"), "zlib.h");
    lib.installHeader(zlib_dep.path("zconf.h"), "zconf.h");
    return lib;
}

const srcs = &.{
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "gzclose.c",
    "gzlib.c",
    "gzread.c",
    "gzwrite.c",
    "inflate.c",
    "infback.c",
    "inftrees.c",
    "inffast.c",
    "trees.c",
    "uncompr.c",
    "zutil.c",
};
