const std = @import("std");

const Dependency = std.Build.Dependency;
const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const imgui: LazyPath = blk: {
        const dep: *Dependency = b.lazyDependency("imgui", .{}) orelse {
            break :blk b.path("");
        };
        std.fs.accessAbsolute(dep.path("imgui.cpp").getPath(b), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidDependency,
            else => return err,
        };
        break :blk dep.path("");
    };
    const imgui_include_path = imgui;
    const zig_imgui_backend_include_path = b.path("imgui_backend_headers");

    const cimgui: LazyPath = blk: {
        const dep: *Dependency = b.lazyDependency("cimgui", .{}) orelse {
            break :blk b.path("");
        };
        std.fs.accessAbsolute(dep.path("cimgui.cpp").getPath(b), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidDependency,
            else => return err,
        };
        break :blk dep.path("");
    };
    const cimgui_include_path = cimgui;

    // cimgui expects imgui to exist in this specific structure
    // - ./imgui/imgui.h
    // - ./imgui/imgui_internal.h
    //
    // So we can just pull down cimgui as an external dependency, fake that structure here
    const zig_cimgui_headers_path = b.path("cimgui_headers");

    const lib = b.addLibrary(.{
        .name = "imgui",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.linkLibCpp();

    // Settings
    lib.root_module.addCMacro("IMGUI_DISABLE_DEFAULT_SHELL_FUNCTIONS", "1");
    lib.root_module.addCMacro("IMGUI_DISABLE_FILE_FUNCTIONS", "1");
    // lib.root_module.addCMacro("IMGUI_DISABLE_DEMO_WINDOWS", "1");
    // lib.root_module.addCMacro("IMGUI_DISABLE_DEBUG_TOOLS", "1");

    const default_cpp_flags = [_][]const u8{ "-std=c++11", "-nostdinc++" };
    const psp_cpp_flags = default_cpp_flags ++ [_][]const u8{ "-fno-exceptions", "-fno-rtti", "-fno-use-cxa-atexit" };

    const cpp_flags: []const []const u8 = switch (target.result.os.tag) {
        .freestanding => &psp_cpp_flags,
        else => &default_cpp_flags,
    };

    // ImGui files
    lib.addCSourceFiles(.{
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
    lib.addIncludePath(imgui_include_path);

    // ImGui enable freetype
    const has_freetype = b.option(bool, "enable_freetype", "Build ImGui with freetype instead of stb_truetype") orelse false;
    if (has_freetype) {
        lib.root_module.addCMacro("IMGUI_ENABLE_FREETYPE", "1");
        lib.root_module.addCMacro("CIMGUI_FREETYPE", "1");

        // HACK: Stop error "use of undeclared identifier 'ImFontAtlasGetBuilderForStbTruetype'" when compiling with Freetype
        lib.root_module.addCMacro("ImFontAtlasGetBuilderForStbTruetype()", "NULL");

        lib.addCSourceFiles(.{
            .root = imgui,
            .files = &.{
                "misc/freetype/imgui_freetype.cpp",
            },
            .flags = cpp_flags,
        });
        lib.addIncludePath(imgui.path(b, "misc/freetype"));

        // NOTE(jae): 2024-07-01
        // We add the <ft2build.h> include dependency in the parent build.zig
        // for (freetype_lib.root_module.include_dirs.items) |freetype_include_dir| {
        //     switch (freetype_include_dir) {
        //         .path => |p| imgui_lib.addIncludePath(p),
        //         else => {}, // std.debug.panic("unhandled path from SDL: {s}", .{@tagName(sdl_include_dir)}),
        //     }
        // }
    }

    // ImGui SDL3 backend files
    {
        // Set endianness explicitly for arches like the PSP
        const sdl_byteorder = switch (target.result.cpu.arch.endian()) {
            .little => "SDL_LIL_ENDIAN",
            .big => "SDL_BIG_ENDIAN",
        };
        lib.root_module.addCMacro("SDL_BYTEORDER", sdl_byteorder);
        lib.root_module.addCSourceFiles(.{
            .root = imgui,
            .files = &.{
                "backends/imgui_impl_sdl3.cpp",
                "backends/imgui_impl_sdlrenderer3.cpp",
            },
            .flags = cpp_flags,
        });
        // NOTE(jae): 2024-07-01
        // We add the <SDL.h> include dependency in the parent build.zig
        // for (sdl_lib.root_module.include_dirs.items) |sdl_include_dir| {
        //     switch (sdl_include_dir) {
        //         .path => |p| imgui_lib.addIncludePath(p),
        //         else => {}, // std.debug.panic("unhandled path from SDL: {s}", .{@tagName(sdl_include_dir)}),
        //     }
        // }
    }

    // cimgui files
    lib.addCSourceFiles(.{
        .root = cimgui,
        .files = &.{
            "cimgui.cpp",
        },
        .flags = cpp_flags,
    });
    lib.addIncludePath(cimgui_include_path);
    lib.addIncludePath(zig_cimgui_headers_path);
    lib.root_module.addCMacro("IMGUI_IMPL_API", "extern \"C\""); // export "{imgui-folder}/backends/*.cpp"
    switch (target.result.os.tag) {
        .windows => {
            lib.linkSystemLibrary("imm32");
        },
        else => {},
    }
    b.installArtifact(lib);

    // Imgui Translate C-code
    var c_translate = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/imgui.h"),
    });
    if (has_freetype) {
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
}
