const std = @import("std");

pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "z",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.addCSourceFiles(.{ .files = srcs, .flags = &.{"-std=c89"} });
    lib.installHeader(.{ .path = "libs/zlib/zlib.h" }, "zlib.h");
    lib.installHeader(.{ .path = "libs/zlib/zconf.h" }, "zconf.h");
    return lib;
}

const srcs = &.{
    "libs/zlib/adler32.c",
    "libs/zlib/compress.c",
    "libs/zlib/crc32.c",
    "libs/zlib/deflate.c",
    "libs/zlib/gzclose.c",
    "libs/zlib/gzlib.c",
    "libs/zlib/gzread.c",
    "libs/zlib/gzwrite.c",
    "libs/zlib/inflate.c",
    "libs/zlib/infback.c",
    "libs/zlib/inftrees.c",
    "libs/zlib/inffast.c",
    "libs/zlib/trees.c",
    "libs/zlib/uncompr.c",
    "libs/zlib/zutil.c",
};
