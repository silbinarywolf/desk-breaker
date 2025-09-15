const std = @import("std");

const Dependency = std.Build.Dependency;
const LazyPath = std.Build.LazyPath;

// borrowed logic from: https://github.com/mitchellh/zig-build-freetype/blob/main/build.zig
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.option(Platform, "platform", "The platform to build for. (ie. PSP)") orelse .none;

    const freetype: LazyPath = blk: {
        const dep: *Dependency = b.lazyDependency("freetype", .{}) orelse {
            break :blk b.path("");
        };
        std.fs.accessAbsolute(dep.path("include/ft2build.h").getPath(b), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidDependency,
            else => return err,
        };
        break :blk dep.path("");
    };
    const freetype_include_path = freetype.path(b, "include");

    // const libpng_enabled = b.option(bool, "enable-libpng", "Build libpng") orelse false;
    const libpng_enabled = false;

    const lib = b.addLibrary(.{
        .name = "freetype",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    if (target.result.os.tag == .linux) {
        lib.linkSystemLibrary("m");
    }

    // const zlib_dep = b.dependency("zlib", .{ .target = target, .optimize = optimize });
    // lib.linkLibrary(zlib_dep.artifact("z"));
    // if (libpng_enabled) {
    //     const libpng_dep = b.dependency("libpng", .{ .target = target, .optimize = optimize });
    //     lib.linkLibrary(libpng_dep.artifact("png"));
    // }
    lib.addIncludePath(freetype_include_path);

    // Macros
    lib.root_module.addCMacro("FT2_BUILD_LIBRARY", "1");
    lib.root_module.addCMacro("HAVE_UNISTD_H", "1");
    lib.root_module.addCMacro("HAVE_FCNTL_H", "1");
    if (target.result.os.tag == .freestanding or target.result.abi == .none) {
        // Disable ftell, etc
        lib.root_module.addCMacro("FT_CONFIG_OPTION_DISABLE_STREAM_SUPPORT", "1");
    }

    // NOTE(jae): 2025-02-02
    // Experiment with trying to get this building with Emscripten
    // if (target.result.os.tag == .emscripten) {
    //     lib.root_module.addCMacro("longjmp", "emscripten_longjmp");
    //     lib.root_module.addCMacro("setjmp", "emscripten_setjmp");
    // }

    const flags = &[_][]const u8{
        "-fno-sanitize=undefined",
    };
    if (libpng_enabled) lib.root_module.addCMacro("FT_CONFIG_OPTION_USE_PNG", "1");
    // TODO(JAE): 2024-04-08
    // add zlib to build
    // "-DFT_CONFIG_OPTION_SYSTEM_ZLIB=1",
    // if (libzlib_enabled) lib.root_module.addCMacro("FT_CONFIG_OPTION_SYSTEM_ZLIB", "1");

    lib.addCSourceFiles(.{
        .root = freetype,
        .files = srcs,
        .flags = flags,
    });
    // lib.installHeader(b.path("include/freetype-zig.h"), "freetype-zig.h");
    // lib.installHeader(freetype.path(b, "include/ft2build.h"), "ft2build.h");
    // lib.installHeadersDirectory(freetype.path(b, "include/freetype"), "freetype");

    const os_tag = target.result.os.tag;
    switch (os_tag) {
        .windows => {
            lib.addCSourceFiles(.{
                .root = freetype,
                .files = &.{
                    "builds/windows/ftsystem.c",
                    "builds/windows/ftdebug.c",
                },
                .flags = flags,
            });
            lib.addWin32ResourceFile(.{
                .file = freetype.path(b, "src/base/ftver.rc"),
            });
        },
        else => {
            if (target.result.os.tag == .linux and platform == .none) {
                lib.addCSourceFiles(.{
                    .root = freetype,
                    .files = &.{
                        "builds/unix/ftsystem.c",
                        "src/base/ftdebug.c",
                    },
                    .flags = flags,
                });
            } else {
                lib.addCSourceFiles(.{
                    .root = freetype,
                    .files = &.{
                        "src/base/ftsystem.c",
                        "src/base/ftdebug.c",
                    },
                    .flags = flags,
                });
            }
        },
    }
    b.installArtifact(lib);

    var c_translate = b.addTranslateC(.{
        .target = target,
        .optimize = .ReleaseFast,
        .root_source_file = b.path("include/freetype-zig.h"),
    });
    c_translate.addIncludePath(b.path("include"));
    c_translate.addIncludePath(freetype_include_path);

    _ = c_translate.addModule("freetype");
}

const Platform = enum {
    none,
    psp,
};

const headers = &.{
    "png.h",
    "pngconf.h",
    "pngdebug.h",
    "pnginfo.h",
    "pngpriv.h",
    "pngstruct.h",
};

const srcs = &.{
    "src/autofit/autofit.c",
    "src/base/ftbase.c",
    "src/base/ftbbox.c",
    "src/base/ftbdf.c",
    "src/base/ftbitmap.c",
    "src/base/ftcid.c",
    "src/base/ftfstype.c",
    "src/base/ftgasp.c",
    "src/base/ftglyph.c",
    "src/base/ftgxval.c",
    "src/base/ftinit.c",
    "src/base/ftmm.c",
    "src/base/ftotval.c",
    "src/base/ftpatent.c",
    "src/base/ftpfr.c",
    "src/base/ftstroke.c",
    "src/base/ftsynth.c",
    "src/base/fttype1.c",
    "src/base/ftwinfnt.c",
    "src/bdf/bdf.c",
    "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",
    "src/cff/cff.c",
    "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",
    "src/lzw/ftlzw.c",
    "src/pcf/pcf.c",
    "src/pfr/pfr.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/svg/svg.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/type42/type42.c",
    "src/winfonts/winfnt.c",
};
