const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wuffs_dep = b.dependency("wuffs", .{});
    const wuffs_src_file = wuffs_dep.path("release/c/wuffs-v0.3.c");

    // files
    const lib = b.addStaticLibrary(.{
        .name = "wuffs",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib.root_module.addCMacro("WUFFS_IMPLEMENTATION", "");

    // Define WUFFS_CONFIG__STATIC_FUNCTIONS (combined with WUFFS_IMPLEMENTATION)
    // to make all of Wuffs' functions have static storage.
    //
    // This can help the compiler ignore or discard unused code, which can produce
    // faster compiles and smaller binaries. Other motivations are discussed in the
    // "ALLOW STATIC IMPLEMENTATION" section of
    // https://raw.githubusercontent.com/nothings/stb/master/docs/stb_howto.txt

    // NOTE(jae): wuffs_png__decoder__decode_image_config won't be found in build if this is on.
    // lib.root_module.addCMacro("WUFFS_CONFIG__STATIC_FUNCTIONS", "");

    // Defining the WUFFS_CONFIG__MODULE* macros are optional, but it lets users of
    // release/c/etc.c choose which parts of Wuffs to build. That file contains the
    // entire Wuffs standard library, implementing a variety of codecs and file
    // formats. Without this macro definition, an optimizing compiler or linker may
    // very well discard Wuffs code for unused codecs, but listing the Wuffs
    // modules we use makes that process explicit. Preprocessing means that such
    // code simply isn't compiled.
    lib.root_module.addCMacro("WUFFS_CONFIG__MODULES", "");
    lib.root_module.addCMacro("WUFFS_CONFIG__MODULE__ADLER32", "");
    lib.root_module.addCMacro("WUFFS_CONFIG__MODULE__BASE", "");
    lib.root_module.addCMacro("WUFFS_CONFIG__MODULE__CRC32", "");
    lib.root_module.addCMacro("WUFFS_CONFIG__MODULE__DEFLATE", "");
    lib.root_module.addCMacro("WUFFS_CONFIG__MODULE__PNG", "");
    lib.root_module.addCMacro("WUFFS_CONFIG__MODULE__ZLIB", "");

    lib.addCSourceFile(.{
        .file = wuffs_src_file,
        .flags = &.{"-fno-sanitize=undefined"},
    });
    b.installArtifact(lib);

    // Module

    // NOTE(jae): 2025-03-23
    // Patched wuffs-v0.3.c
    // Changed: sizeof__wuffs_png__decoder() -> sizeof__wuffs_png__decoder(void) to avoid Wasm issues
    var c_translate = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = wuffs_src_file,
    });
    c_translate.defineCMacroRaw("WUFFS_CONFIG__STATIC_FUNCTIONS");
    // c_translate.defineCMacroRaw("WUFFS_IMPLEMENTATION");
    // c_translate.defineCMacroRaw("WUFFS_CONFIG__MODULES");
    // c_translate.defineCMacroRaw("WUFFS_CONFIG__MODULE__ADLER32");
    // c_translate.defineCMacroRaw("WUFFS_CONFIG__MODULE__BASE");
    // c_translate.defineCMacroRaw("WUFFS_CONFIG__MODULE__CRC32");
    // c_translate.defineCMacroRaw("WUFFS_CONFIG__MODULE__DEFLATE");
    // c_translate.defineCMacroRaw("WUFFS_CONFIG__MODULE__PNG");
    // c_translate.defineCMacroRaw("WUFFS_CONFIG__MODULE__ZLIB");
    _ = b.addModule("wuffs", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = c_translate.getOutput(),
    });
}
