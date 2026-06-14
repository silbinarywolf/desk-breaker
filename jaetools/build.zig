const Build = @import("std").Build;
const Module = Build.Module;
const Dependency = Build.Dependency;
const LazyPath = Build.LazyPath;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add DE (D0gEngine)
    const de_mod = b.addModule("de", .{
        .root_source_file = b.path("modules/de/de.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Setup build options
    {
        // TODO(jae): 2026-05-08
        // If need be in the future, make this configurable

        var build_options = b.addOptions();
        build_options.addOption(bool, "has_sdl", true);
        build_options.addOption(bool, "has_imgui", true);
        // build_options.addOption(bool, "has_freetype", true);
        Build.Module.addOptions(de_mod, "options", build_options);
    }

    // NOTE(jae): 2024-07-31
    // Linux can do Mac cross-compilation if we download the macos-sdk lazy dependency
    //
    // - zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
    // - zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos
    var system_framework_path: ?LazyPath = null;
    var system_include_path: ?LazyPath = null;
    var library_path: ?LazyPath = null;
    if (!target.query.isNative()) {
        if (target.result.os.tag == .macos or target.result.os.tag == .ios) {
            if (b.graph.host.result.os.tag == .windows) {
                @panic("Windows cannot cross-compile to Mac due to symlink not working on all Windows setups: https://github.com/ziglang/zig/issues/17652");
            }
            const macos_sdk_path = if (b.lazyDependency("macos_sdk", .{})) |ld| ld.path("") else b.path("");
            system_framework_path = macos_sdk_path.path(b, "System/Library/Frameworks");
            system_include_path = macos_sdk_path.path(b, "usr/include");
            library_path = macos_sdk_path.path(b, "usr/lib");
        }
    }

    // add SDL
    const sdl_lib = blk: {
        const sdl_dep = b.dependency("sdl", .{
            .target = target,
            .optimize = optimize,
            // .lto = @import("std").zig.LtoMode.thin,
            .system_framework_path = system_framework_path,
            .system_include_path = system_include_path,
            .library_path = library_path,
        });
        const sdl_lib = sdl_dep.artifact("SDL3");

        const sdl_mod = exportAndGetModule(b, sdl_dep, "sdl");
        sdl_mod.linkLibrary(sdl_lib);
        // if (target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
        //     // Add library paths to sdl module
        //     for (sdl_lib.root_module.lib_paths.items) |lib_path| {
        //         sdl_mod.addLibraryPath(lib_path);
        //     }
        // }
        de_mod.addImport("sdl", sdl_mod);

        break :blk sdl_lib;
    };

    // add freetype
    const freetype_lib = blk: {
        const freetype_dep = b.dependency("freetype", .{
            .target = target,
            .optimize = optimize,
        });
        const freetype_lib = freetype_dep.artifact("freetype");

        const freetype_mod = exportAndGetModule(b, freetype_dep, "freetype");
        freetype_mod.linkLibrary(freetype_lib);
        de_mod.addImport("freetype", freetype_mod);
        break :blk freetype_lib;
    };

    // add Imgui
    {
        const imgui_dep = b.dependency("imgui", .{
            .target = target,
            .optimize = optimize,
            .backend = .sdl3,
            .font_backend = .freetype,
            // NOTE(jae): 2026-06-14
            // Only need system_framework_path for ImGui+SDL support
            .system_framework_path = system_framework_path,
            // .system_include_path = system_include_path,
            // .library_path = library_path,
        });
        const imgui_lib = imgui_dep.artifact("imgui");

        // Must link "freetype" to "imgui" or else we get: 'ft2build.h' file not found
        imgui_lib.root_module.linkLibrary(freetype_lib);
        // Must link "sdl" to "imgui" or else we can get: 'SDL3/SDL.h' file not found
        imgui_lib.root_module.linkLibrary(sdl_lib);

        const imgui_mod = exportAndGetModule(b, imgui_dep, "imgui");
        imgui_mod.linkLibrary(imgui_lib);
        de_mod.addImport("imgui", imgui_mod);
    }

    // Export system framework path and library path
    if (system_framework_path) |path| {
        b.addNamedLazyPath("system_framework_path", path);
    }
    if (library_path) |path| {
        b.addNamedLazyPath("library_path", path);
    }
}

fn exportAndGetModule(b: *Build, dep: *Dependency, name: []const u8) *Module {
    const mod = dep.module(name);
    b.modules.put(b.graph.arena, b.dupe(name), mod) catch @panic("OOM");
    return mod;
}
