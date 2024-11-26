const std = @import("std");
const Dependency = std.Build.Dependency;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const imgui_dep: *Dependency = blk: {
        const local_dep = b.dependency("imgui-local", .{});
        std.fs.accessAbsolute(local_dep.path("imgui.cpp").getPath(b), .{}) catch |err| switch (err) {
            error.FileNotFound => {
                break :blk b.lazyDependency("imgui-remote", .{}) orelse return error.MissingDependency;
            },
            else => return err,
        };
        break :blk local_dep;
    };
    const imgui = imgui_dep.path("");
    const imgui_include_path = imgui;
    const zig_imgui_backend_include_path = b.path("imgui_backend_headers");

    const cimgui_dep: *Dependency = blk: {
        const local_dep = b.dependency("cimgui-local", .{});
        std.fs.accessAbsolute(local_dep.path("cimgui.cpp").getPath(b), .{}) catch |err| switch (err) {
            error.FileNotFound => {
                break :blk b.lazyDependency("cimgui-remote", .{}) orelse return error.MissingDependency;
            },
            else => return err,
        };
        break :blk local_dep;
    };
    const cimgui = cimgui_dep.path("");
    const cimgui_include_path = cimgui;

    // cimgui expects imgui to exist in this specific structure
    // - ./imgui/imgui.h
    // - ./imgui/imgui_internal.h
    //
    // So we can just pull down cimgui as an external dependency, fake that structure here
    const zig_cimgui_headers_path = b.path("cimgui_headers");

    const lib = b.addStaticLibrary(.{
        .name = "imgui",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib.linkLibCpp();

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
        .flags = &.{"-std=c++11"},
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
            .flags = &.{"-std=c++11"},
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
        lib.addCSourceFiles(.{
            .root = imgui,
            .files = &.{
                "backends/imgui_impl_sdl3.cpp",
                "backends/imgui_impl_sdlrenderer3.cpp",
            },
            .flags = &.{"-std=c++11"},
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
        .flags = &.{"-std=c++11"},
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

    // SDL Translate C-code
    var c_translate = b.addTranslateC(.{
        // NOTE(jae): 2024-11-05
        // Translating C-header API only so we use host so that Android builds
        // will compile correctly.
        .target = b.host,
        .optimize = .ReleaseFast,
        .root_source_file = b.path("src/imgui.h"),
    });
    c_translate.addIncludeDir(cimgui_include_path.getPath(b));
    c_translate.addIncludeDir(zig_cimgui_headers_path.getPath(b));
    c_translate.addIncludeDir(zig_imgui_backend_include_path.getPath(b));

    _ = b.addModule("imgui", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = c_translate.getOutput(),
    });
}
