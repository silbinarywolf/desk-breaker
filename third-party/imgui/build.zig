const std = @import("std");
const ArrayList = std.ArrayList;

const Dependency = std.Build.Dependency;
const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const optional_freetype_include_path = b.option(
        LazyPath,
        "freetype_include_path",
        "Used to compile with FreeType support and include <ft2build.h>",
    );
    const optional_sdl_include_path = b.option(
        LazyPath,
        "sdl_include_path",
        "Used to compile SDL platform/rendering backends",
    );

    const imgui: LazyPath = blk: {
        const dep: *Dependency = b.lazyDependency("imgui", .{}) orelse {
            break :blk b.path("");
        };
        // std.fs.accessAbsolute(dep.path("imgui.cpp").getPath(b), .{}) catch |err| switch (err) {
        //     error.FileNotFound => return error.InvalidDependency,
        //     else => return err,
        // };
        break :blk dep.path("");
    };
    const imgui_include_path = imgui;
    const zig_imgui_backend_include_path = b.path("imgui_backend_headers");

    const cimgui: LazyPath = blk: {
        const dep: *Dependency = b.lazyDependency("cimgui", .{}) orelse break :blk b.path("");
        break :blk dep.path("");
    };
    const cimgui_include_path = cimgui;

    // cimgui expects imgui to exist in this specific structure
    // - ./imgui/imgui.h
    // - ./imgui/imgui_internal.h
    //
    // So we can just pull down cimgui as an external dependency, fake that structure here
    const zig_cimgui_headers_path = b.path("cimgui_headers");

    const imgui_define_macros: []const []const u8 = blk: {
        var list: ArrayList([]const u8) = .empty;
        try list.appendSlice(b.allocator, &[_][]const u8{
            // Add config options as listed here:
            // https://github.com/ocornut/imgui/blob/master/imconfig.h
            "IMGUI_DISABLE_DEFAULT_SHELL_FUNCTIONS",
            "IMGUI_DISABLE_FILE_FUNCTIONS",
            "IMGUI_DISABLE_STB_SPRINTF_IMPLEMENTATION",
        });
        if (optimize != .Debug) {
            try list.appendSlice(b.allocator, &[_][]const u8{
                "IMGUI_DISABLE_DEMO_WINDOWS",
                // "IMGUI_DISABLE_DEBUG_TOOLS",
            });
        }
        if (optional_freetype_include_path) |_| {
            try list.appendSlice(b.allocator, &.{
                "IMGUI_ENABLE_FREETYPE",
                "IMGUI_DISABLE_STB_TRUETYPE_IMPLEMENTATION",
            });
        }
        break :blk try list.toOwnedSlice(b.allocator);
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
    mod.addIncludePath(imgui_include_path);
    for (imgui_define_macros) |imgui_define_macro| {
        mod.addCMacro(imgui_define_macro, "1");
    }
    mod.addCMacro("IMGUI_IMPL_API", "extern \"C\""); // export "{imgui-folder}/backends/*.cpp"
    switch (target.result.os.tag) {
        .windows => {
            mod.linkSystemLibrary("imm32", .{});
        },
        else => {},
    }

    // ImGui enable freetype
    if (optional_freetype_include_path) |freetype_include_path| {
        mod.addCSourceFiles(.{
            .root = imgui,
            .files = &.{
                "misc/freetype/imgui_freetype.cpp",
            },
            .flags = cpp_flags,
        });
        mod.addIncludePath(freetype_include_path);
        mod.addIncludePath(imgui.path(b, "misc/freetype"));
    }

    // ImGui SDL3 backend files
    if (optional_sdl_include_path) |sdl_include_path| {
        mod.addCMacro("SDL_BYTEORDER", switch (target.result.cpu.arch.endian()) {
            .little => "SDL_LIL_ENDIAN",
            .big => "SDL_BIG_ENDIAN",
        });
        mod.addCSourceFiles(.{
            .root = imgui,
            .files = &.{
                "backends/imgui_impl_sdl3.cpp",
                "backends/imgui_impl_sdlrenderer3.cpp",
            },
            .flags = cpp_flags,
        });
        mod.addIncludePath(sdl_include_path);
    }

    // cimgui files
    {
        const cimgui_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        });
        cimgui_mod.addCSourceFiles(.{
            .root = cimgui,
            .files = &.{
                "cimgui.cpp",
            },
            .flags = cpp_flags,
        });
        for (imgui_define_macros) |imgui_define_macro| {
            cimgui_mod.addCMacro(imgui_define_macro, "1");
        }
        cimgui_mod.addCMacro("IMGUI_IMPL_API", "extern \"C\"");
        if (optional_freetype_include_path) |_| {
            cimgui_mod.addCMacro("CIMGUI_FREETYPE", "1");
        }
        cimgui_mod.addIncludePath(imgui_include_path);
        cimgui_mod.addIncludePath(cimgui_include_path);
        cimgui_mod.addIncludePath(zig_cimgui_headers_path);
        const cimgui_lib = b.addLibrary(.{
            .name = "cimgui",
            .root_module = cimgui_mod,
            .linkage = .static,
        });
        mod.linkLibrary(cimgui_lib);
    }
    b.installArtifact(b.addLibrary(.{
        .name = "imgui",
        .linkage = .static,
        .root_module = mod,
    }));

    // Imgui Translate C-code
    var c_translate = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/imgui.h"),
    });
    if (optional_freetype_include_path) |_| {
        c_translate.defineCMacro("IMGUI_ENABLE_FREETYPE", "1");
    }
    c_translate.addIncludePath(cimgui_include_path);
    c_translate.addIncludePath(zig_cimgui_headers_path);
    c_translate.addIncludePath(zig_imgui_backend_include_path);

    _ = b.addModule("imgui", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = c_translate.getOutput(),
    });

    // Export paths
    b.addNamedLazyPath("imgui_include_path", imgui_include_path);
}
