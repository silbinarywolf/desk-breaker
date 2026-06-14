//! Freetype Library (barebones) compilation library

const std = @import("std");

const Dependency = std.Build.Dependency;
const LazyPath = std.Build.LazyPath;

// Borrowed logic from: https://github.com/mitchellh/zig-build-freetype/blob/main/build.zig
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const freetype_dep = b.dependency("freetype", .{});
    const freetype = freetype_dep.path("");
    const freetype_include_path = freetype_dep.path("include");

    var mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(freetype_include_path);
    if (target.result.os.tag == .linux) {
        mod.linkSystemLibrary("m", .{});
    }

    // Macros
    mod.addCMacro("FT2_BUILD_LIBRARY", "1");
    mod.addCMacro("HAVE_UNISTD_H", "1");
    mod.addCMacro("HAVE_FCNTL_H", "1");
    if (target.result.os.tag == .freestanding) {
        // Disable ftell, etc
        mod.addCMacro("FT_CONFIG_OPTION_DISABLE_STREAM_SUPPORT", "1");
    }

    // Add files
    const c_flags = &[_][]const u8{
        "-fno-sanitize=undefined",
    };
    mod.addCSourceFiles(.{
        .root = freetype,
        .files = freetype_src_files,
        .flags = c_flags,
    });

    const os_tag = target.result.os.tag;
    switch (os_tag) {
        .windows => {
            mod.addCSourceFiles(.{
                .root = freetype,
                .files = &.{
                    "builds/windows/ftsystem.c",
                    "builds/windows/ftdebug.c",
                },
                .flags = c_flags,
            });
            mod.addWin32ResourceFile(.{
                .file = freetype.path(b, "src/base/ftver.rc"),
            });
        },
        .linux => {
            mod.addCSourceFiles(.{
                .root = freetype,
                .files = &.{
                    "builds/unix/ftsystem.c",
                    "src/base/ftdebug.c",
                },
                .flags = c_flags,
            });
        },
        else => {
            mod.addCSourceFiles(.{
                .root = freetype,
                .files = &.{
                    "src/base/ftsystem.c",
                    "src/base/ftdebug.c",
                },
                .flags = c_flags,
            });
        },
    }
    const lib = b.addLibrary(.{
        .name = "freetype",
        .linkage = .static,
        .root_module = mod,
    });
    lib.installHeadersDirectory(freetype_include_path.path(b, "freetype"), "freetype", .{});
    lib.installHeader(freetype_include_path.path(b, "ft2build.h"), "ft2build.h");
    b.installArtifact(lib);

    var c_translate = b.addTranslateC(.{
        .target = target,
        .optimize = .ReleaseFast,
        .root_source_file = b.path("include/freetype-zig.h"),
    });
    c_translate.addIncludePath(freetype_include_path);

    _ = c_translate.addModule("freetype");
}

const freetype_src_files = &[_][]const u8{
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
