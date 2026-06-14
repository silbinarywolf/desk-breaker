const std = @import("std");
const ArrayList = std.ArrayList;

const Dependency = std.Build.Dependency;
const LazyPath = std.Build.LazyPath;

const Backend = enum {
    none,
    sdl3,
};

const FontBackend = enum {
    /// Default will use the stb_freetype font renderer
    default,
    /// Freetype requires you link a "freetype" library to the "imgui" artifact or else you will
    /// get the following error: 'ft2build.h' file not found
    ///     const imgui_lib = imgui_dep.artifact("imgui");
    ///     imgui_lib.root_module.linkLibrary(freetype_lib);
    freetype,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend_renderer: Backend = b.option(
        Backend,
        "backend",
        "The backend to compile ImGui with. ie. sdl3",
    ) orelse .none;
    const font_backend: FontBackend = b.option(
        FontBackend,
        "font_backend",
        "The font backend to use, either default or FreeType",
    ) orelse .default;
    const disable_default_font: bool = b.option(
        bool,
        "disable_default_font",
        "IMGUI_DISABLE_DEFAULT_FONT: Disable default embedded fonts (ProggyClean/ProggyForever), remove ~9 KB + ~14 KB from output binary. AddFontDefaultXXX() functions will assert.",
    ) orelse false;

    // NOTE(jae): 2026-05-21
    // Do a unity build (one c++ file to rebuild all of imgui) as it can lead to more effecient code generation.
    // This doesn't impact stack traces so I see no reason not to do it by default.
    const is_unity_build = true;

    const imgui: LazyPath = b.dependency("imgui", .{}).path("");
    const imgui_include_path = imgui;
    const zig_imgui_backend_include_path = b.path("imgui_backend_headers");

    const cimgui: LazyPath = b.dependency("cimgui", .{}).path("");
    const cimgui_include_path = cimgui;

    // cimgui expects imgui to exist in this specific structure
    // - ./imgui/imgui.h
    // - ./imgui/imgui_internal.h
    //
    // So we can just pull down cimgui as an external dependency, fake that structure here
    const zig_cimgui_headers_path = b.path("cimgui_headers");

    const imgui_define_macros: []const []const u8 = blk: {
        const gpa = b.allocator;
        var list: ArrayList([]const u8) = .empty;
        try list.appendSlice(gpa, &[_][]const u8{
            // Add config options as listed here:
            // https://github.com/ocornut/imgui/blob/master/imconfig.h

            // Don't define obsolete functions/enums/behaviors. Consider enabling from time to time after updating to clean your code of obsolete function/names.
            // "IMGUI_DISABLE_OBSOLETE_FUNCTIONS", // Must be commented out if 'IMGUI_DEBUG_HIGHLIGHT_ALL_ID_CONFLICTS' is enabled, errors with ImGui 1.92.8-docking
            "IMGUI_DISABLE_DEFAULT_SHELL_FUNCTIONS",
            "IMGUI_DISABLE_FILE_FUNCTIONS",
            // "IMGUI_DISABLE_STB_SPRINTF_IMPLEMENTATION", // only disabled if IMGUI_USE_STB_SPRINTF is defined.
        });
        if (disable_default_font) {
            try list.append(gpa, "IMGUI_DISABLE_DEFAULT_FONT");
        }
        // TODO: Make this toggleable
        // if (optimize == .Debug or optimize == .ReleaseSafe) {
        //     try list.append(gpa, "IMGUI_DEBUG_HIGHLIGHT_ALL_ID_CONFLICTS");
        // }
        if (optimize != .Debug) {
            try list.appendSlice(gpa, &[_][]const u8{
                "IMGUI_DISABLE_DEMO_WINDOWS",
                // "IMGUI_DISABLE_DEBUG_TOOLS", // NOTE(jae): Disabling this breaks cimgui in ReleaseSafe/Fast builds
            });
        }
        if (font_backend == .freetype) {
            try list.appendSlice(gpa, &.{
                "IMGUI_ENABLE_FREETYPE",
                "IMGUI_DISABLE_STB_TRUETYPE_IMPLEMENTATION",
            });
        }
        const zig_backend_include_macro = switch (backend_renderer) {
            .none => "",
            .sdl3 => "ZIG_IMGUI_BACKEND_SDL3",
        };
        if (zig_backend_include_macro.len > 0) {
            try list.append(gpa, zig_backend_include_macro);
        }
        break :blk try list.toOwnedSlice(gpa);
    };

    const default_cpp_flags = [_][]const u8{ "-std=c++11", "-nostdinc++" };
    const psp_cpp_flags = default_cpp_flags ++ [_][]const u8{ "-fno-exceptions", "-fno-rtti" };

    const cpp_flags: []const []const u8 = switch (target.result.os.tag) {
        .freestanding => &psp_cpp_flags,
        else => &default_cpp_flags,
    };

    // ImGui files
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    switch (target.result.os.tag) {
        .windows => mod.linkSystemLibrary("imm32", .{}),
        else => {},
    }

    if (is_unity_build) {
        mod.addCSourceFile(.{
            .file = b.path("src/zig_imgui_unity.cpp"),
            .flags = cpp_flags,
        });
        mod.addIncludePath(imgui);
        mod.addIncludePath(cimgui);
    } else {
        mod.addCSourceFiles(.{
            .root = imgui,
            .files = &.{
                "imgui.cpp",
                "imgui_demo.cpp",
                "imgui_draw.cpp",
                "imgui_tables.cpp",
                "imgui_widgets.cpp",
            },
            .flags = cpp_flags,
        });
    }
    for (imgui_define_macros) |imgui_define_macro| {
        mod.addCMacro(imgui_define_macro, "1");
    }
    mod.addCMacro("IMGUI_IMPL_API", "extern \"C\""); // export "{imgui-folder}/backends/*.cpp"
    mod.addIncludePath(imgui_include_path);
    switch (font_backend) {
        .default => {},
        .freetype => {
            if (!is_unity_build) {
                mod.addCSourceFiles(.{
                    .root = imgui,
                    .files = &.{
                        "misc/freetype/imgui_freetype.cpp",
                    },
                    .flags = cpp_flags,
                });
            }
            mod.addIncludePath(imgui.path(b, "misc/freetype"));
        },
    }
    // NOTE(jae): 2026-05-21
    // Keeping "cimgui" files distinct in this block, may want to switch to the official C-bindings later: github.com/dearimgui/dear_bindings/
    {
        if (is_unity_build) {
            mod.addIncludePath(cimgui);
        } else {
            mod.addCSourceFiles(.{
                .root = cimgui,
                .files = &.{
                    "cimgui.cpp",
                },
                .flags = cpp_flags,
            });
        }
        switch (font_backend) {
            .default => {},
            .freetype => {
                mod.addCMacro("CIMGUI_FREETYPE", "1");

                // NOTE(jae): 2026-05-08
                // Force disable StbTruetype font loader otherwise Zig can get "use of undeclared identifier 'ImFontAtlasGetFontLoaderForStbTruetype'"
                mod.addCMacro("ImFontAtlasGetFontLoaderForStbTruetype()", "NULL");
            },
        }
        mod.addIncludePath(cimgui_include_path);
        mod.addIncludePath(zig_cimgui_headers_path);
    }

    switch (backend_renderer) {
        .none => {},
        .sdl3 => {
            if (!is_unity_build) {
                // ImGui SDL3 backend files
                //
                // NOTE(jae): 2026-05-18
                // For this to work it expects the downstream SDL3 library to add the headers to the main linked module
                // via `sdl_lib.installHeadersDirectory(sdl3_dep.path("include/SDL3"), "SDL3")`
                mod.addCSourceFiles(.{
                    .root = imgui,
                    .files = &.{
                        "backends/imgui_impl_sdl3.cpp",
                        "backends/imgui_impl_sdlrenderer3.cpp",
                    },
                    .flags = cpp_flags,
                });

                // NOTE(jae): 2026-05-18
                // Just using b.installHeadersDirectory
                // mod.addIncludePath(sdl_include_path);
            }
        },
    }

    const lib = b.addLibrary(.{
        .name = "imgui",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Imgui Translate C-code
    var c_translate = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/zig_translate_c_imgui.h"),
    });
    for (imgui_define_macros) |define_macro| {
        c_translate.defineCMacro(define_macro, "1");
    }
    c_translate.addIncludePath(cimgui_include_path);
    c_translate.addIncludePath(zig_cimgui_headers_path);
    c_translate.addIncludePath(zig_imgui_backend_include_path);

    _ = b.addModule("imgui", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/imgui-gen.zig"),
        // .root_source_file = c_translate.getOutput(),
    });

    // Export paths
    b.addNamedLazyPath("imgui_include_path", imgui_include_path);
}
