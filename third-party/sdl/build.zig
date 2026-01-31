const std = @import("std");
const builtin = @import("builtin");

const Dependency = std.Build.Dependency;
const LazyPath = std.Build.LazyPath;
const SdlBuildGenerator = @import("tools/SdlBuildGenerator.zig");
const SDLConfig = @import("src/build/sdlbuild.zig").SDLConfig;
const sdlsrc = @import("src/build/sdlbuild.zig");

const pspBuildConfig: SDLConfig = @import("src/build/psp_build_config.zig").config;
const emscriptenBuildConfig: SDLConfig = @import("src/build/emscripten_build_config.zig").config;

const Platform = enum {
    none,
    psp,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_path: LazyPath = blk: {
        const dep: *Dependency = b.lazyDependency("sdl3", .{}) orelse break :blk b.path("");
        // std.fs.accessAbsolute(dep.path("src/SDL.c").getPath(b), .{}) catch |err| switch (err) {
        //     error.FileNotFound => return error.InvalidDependency,
        //     else => return err,
        // };
        break :blk dep.path("");
    };
    // Generate source file stuff
    const do_sdl_codegen = b.option(bool, "generate", "run code generation") orelse false;
    if (do_sdl_codegen) {
        var gen = try SdlBuildGenerator.init(b, sdl_path.getPath(b));
        defer gen.deinit();
        try gen.generateSdlConfig();
        try gen.generateSdlBuild();
        try gen.formatAndWriteFile(b.pathJoin(&.{ b.path("").getPath(b), "src", "build", "sdlbuild.zig" }));
        return;
    }

    const sdl_api_include_path = sdl_path.path(b, "include");
    const sdl_build_config_include_path = sdl_api_include_path.path(b, "build_config");

    // Export SDL3 include path that contains "SDL3/SDL.h" so that libraries like ImGui can use them
    // for their renderer backends
    b.addNamedLazyPath("include_path", sdl_api_include_path);

    // Set endianness explicitly for arches like the PSP
    const sdl_byteorder = switch (target.result.cpu.arch.endian()) {
        .little => "SDL_LIL_ENDIAN",
        .big => "SDL_BIG_ENDIAN",
    };

    const platform = b.option(Platform, "platform", "The platform to build for. (ie. PSP)") orelse .none;

    const use_cmake = target.result.os.tag == .linux and !target.result.abi.isAndroid() and platform == .none;
    if (!use_cmake) {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const lib = b.addLibrary(.{
            .name = "SDL3",
            .root_module = mod,
            .linkage = if (!target.result.abi.isAndroid())
                .static
            else
                .dynamic,
        });
        mod.addCSourceFiles(.{
            .root = sdl_path,
            .files = &generic_src_files,
            .flags = &.{ "-D_REENTRANT", "-pthread" },
        });
        mod.addIncludePath(sdl_path.path(b, "src")); // SDL_internal.h, etc
        mod.addIncludePath(sdl_api_include_path); // SDL3/*.h, etc

        // Set for SDL_revision.h
        // - If building with cmake, SDL_revision.h generally sets 'SDL_REVISION' to 'SDL-3.1.3-no-vcs'
        // - If building SDL3 via Github Actions, it sets this to: "Github Workflow"
        mod.addCMacro("SDL_VENDOR_INFO", "\"zig-sdl3\"");

        // Used for SDL_egl.h and SDL_opengles2.h
        mod.addCMacro("SDL_USE_BUILTIN_OPENGL_DEFINITIONS", "1");

        // Set endianness explicitly for arches like the PSP
        mod.addCMacro("SDL_BYTEORDER", sdl_byteorder);

        if (target.result.abi.isAndroid()) {
            mod.addCSourceFiles(.{
                .root = sdl_path,
                .files = &android_src_files,
            });
            mod.addCSourceFiles(.{
                .root = sdl_path,
                .files = &android_src_cpp_files,
                .flags = &.{"-std=c++11"},
            });
            mod.link_libcpp = true;

            // This is needed for "src/render/opengles/SDL_render_gles.c" to compile
            mod.addCMacro("GL_GLEXT_PROTOTYPES", "1");

            // https://github.com/libsdl-org/SDL/blob/release-2.30.6/Android.mk#L82C62-L82C69
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("GLESv1_CM", .{});
            mod.linkSystemLibrary("GLESv2", .{});
            mod.linkSystemLibrary("OpenSLES", .{});
            mod.linkSystemLibrary("log", .{});
            mod.linkSystemLibrary("android", .{});

            // SDLActivity.java's getMainFunction defines the entrypoint as "SDL_main"
            // So your main / root file will need something like this for Android
            //
            // fn android_sdl_main() callconv(.C) void {
            //    _ = std.start.callMain();
            // }
            // comptime {
            //    if (builtin.abi == .android) @export(android_sdl_main, .{ .name = "SDL_main", .linkage = .strong });
            // }

            // Add Java files to dependency
            const java_dir = sdl_path.path(b, "android-project/app/src/main/java/org/libsdl/app");
            const java_files: []const []const u8 = &.{
                "SDL.java",
                "SDLActivity.java",
                "SDLAudioManager.java",
                "SDLControllerManager.java",
                "SDLDummyEdit.java",
                "SDLInputConnection.java",
                "SDLSurface.java",
                "HIDDevice.java",
                "HIDDeviceBLESteamController.java",
                "HIDDeviceManager.java",
                "HIDDeviceUSB.java",
            };
            const java_write_files = b.addNamedWriteFiles("sdljava");
            for (java_files) |java_file_basename| {
                _ = java_write_files.addCopyFile(java_dir.path(b, java_file_basename), java_file_basename);
            }
        } else if (platform == .psp) {
            const use_sdl3_directly = false;

            if (use_sdl3_directly) {
                mod.root_source_file = b.path("src/stub.zig");
            } else {
                mod.addCSourceFiles(.{
                    .root = sdl_path,
                    .files = &psp_src_files,
                });
            }

            // This enables the SDL_PLATFORM_PSP macro within SDL
            mod.addCMacro("__PSP__", "1");
            mod.addCMacro("SDL_PLATFORM_PSP", "1");

            const sdl_config = pspBuildConfig;

            mod.addCMacro("USING_GENERATED_CONFIG_H", "");
            const config_header = b.addConfigHeader(.{
                .style = .{ .cmake = sdl_api_include_path.path(b, b.pathJoin(&.{
                    "build_config",
                    "SDL_build_config.h.cmake",
                })) },
                .include_path = "SDL_build_config.h",
            }, sdl_config);
            mod.addConfigHeader(config_header);
            lib.installConfigHeader(config_header);

            // Taken from: https://github.com/libsdl-org/SDL/blob/release-3.2.16/CMakeLists.txt#L2790
            // if (use_sdl3_directly) {
            //     mod.linkSystemLibrary("SDL3", .{});
            // } else {
            //     mod.linkSystemLibrary("GL", .{ .weak = true });
            //     mod.linkSystemLibrary("pspvram");
            //     mod.linkSystemLibrary("pspaudio");
            //     mod.linkSystemLibrary("pspvfpu");
            //     mod.linkSystemLibrary("pspdisplay");
            //     mod.linkSystemLibrary("pspgu");
            //     mod.linkSystemLibrary("pspge");
            //     mod.linkSystemLibrary("psphprm");
            //     mod.linkSystemLibrary("pspctrl");
            //     mod.linkSystemLibrary("psppower");
            // }
            mod.linkSystemLibrary("GL", .{});
            mod.linkSystemLibrary("pspvram", .{});
            mod.linkSystemLibrary("pspaudio", .{});
            mod.linkSystemLibrary("pspvfpu", .{});
            mod.linkSystemLibrary("pspdisplay", .{});
            mod.linkSystemLibrary("pspgu", .{});
            mod.linkSystemLibrary("pspge", .{});
            mod.linkSystemLibrary("psphprm", .{});
            mod.linkSystemLibrary("pspctrl", .{});
            mod.linkSystemLibrary("psppower", .{});
        } else {
            switch (target.result.os.tag) {
                .windows => {
                    mod.addCMacro("HAVE_MODF", "1");

                    // Between Zig 0.13.0 and Zig 0.14.0, "windows.gaming.input.h" was removed from "lib/libc/include/any-windows-any"
                    // This folder brings all headers needed by that one file so that SDL3 can be compiled for Windows.
                    mod.addIncludePath(b.path("upstream/any-windows-any"));

                    mod.addCSourceFiles(.{
                        .root = sdl_path,
                        .files = &windows_src_files,
                    });
                    mod.addCSourceFiles(.{
                        .root = sdl_path,
                        .files = &sdlsrc.video.windows.cpp_files,
                    });
                    mod.addWin32ResourceFile(.{
                        // SDL version
                        .file = sdl_path.path(b, sdlsrc.core.windows.win32_resource_files[0]),
                    });
                    mod.addWin32ResourceFile(.{
                        // HIDAPI version
                        .file = sdl_path.path(b, sdlsrc.hidapi.windows.win32_resource_files[0]),
                        .include_paths = &.{
                            sdl_path.path(b, "src/hidapi/hidapi"),
                        },
                    });
                    mod.linkSystemLibrary("setupapi", .{});
                    mod.linkSystemLibrary("winmm", .{});
                    mod.linkSystemLibrary("gdi32", .{});
                    mod.linkSystemLibrary("imm32", .{});
                    mod.linkSystemLibrary("version", .{});
                    mod.linkSystemLibrary("oleaut32", .{}); // SDL_windowssensor.c, symbol "SysFreeString"
                    mod.linkSystemLibrary("ole32", .{});
                },
                .macos => {
                    // NOTE(jae): 2024-07-07
                    // Cross-compilation from Linux to Mac requires more effort currently (Zig 0.13.0)
                    // See: https://github.com/ziglang/zig/issues/1349

                    mod.addCSourceFiles(.{
                        .root = sdl_path,
                        .files = &darwin_src_files,
                    });
                    mod.addCSourceFiles(.{
                        .root = sdl_path,
                        .files = &objective_c_src_files,
                        .flags = &.{"-fobjc-arc"},
                    });

                    mod.linkFramework("AVFoundation", .{}); // Camera
                    mod.linkFramework("AudioToolbox", .{});
                    mod.linkFramework("Carbon", .{});
                    mod.linkFramework("Cocoa", .{});
                    mod.linkFramework("CoreAudio", .{});
                    mod.linkFramework("CoreMedia", .{});
                    mod.linkFramework("CoreHaptics", .{});
                    mod.linkFramework("CoreVideo", .{});
                    mod.linkFramework("ForceFeedback", .{});
                    mod.linkFramework("GameController", .{});
                    mod.linkFramework("IOKit", .{});
                    mod.linkFramework("Metal", .{});

                    mod.linkFramework("AppKit", .{});
                    mod.linkFramework("CoreFoundation", .{});
                    mod.linkFramework("Foundation", .{});
                    mod.linkFramework("CoreGraphics", .{});
                    mod.linkFramework("CoreServices", .{}); // undefined symbol: _UCKeyTranslate, _Cocoa_AcceptDragAndDrop
                    mod.linkFramework("QuartzCore", .{}); // undefined symbol: OBJC_CLASS_$_CAMetalLayer
                    mod.linkFramework("UniformTypeIdentifiers", .{}); // undefined symbol: _OBJC_CLASS_$_UTType
                    mod.linkSystemLibrary("objc", .{}); // undefined symbol: _objc_release, _objc_begin_catch
                },
                .emscripten => {
                    var sdl_config = emscriptenBuildConfig;

                    // If single threaded isn't explictly set, infer from the Wasm feature set
                    if (mod.single_threaded == null) {
                        if (target.result.os.tag == .emscripten and
                            !std.Target.wasm.featureSetHas(target.result.cpu.features, .atomics))
                        {
                            mod.single_threaded = true;
                        }
                    }

                    if (mod.single_threaded == true) {
                        mod.addCSourceFiles(.{
                            .root = sdl_path,
                            .files = &sdlsrc.thread.generic.c_files,
                        });
                        sdl_config.SDL_THREADS_DISABLED = true;
                        sdl_config.HAVE_GCC_ATOMICS = false;
                    } else {
                        if (!std.Target.wasm.featureSetHas(target.result.cpu.features, .atomics)) {
                            @panic("Must enable atomics for SDL3 emscripten threading");
                        }
                        if (!std.Target.wasm.featureSetHas(target.result.cpu.features, .bulk_memory)) {
                            @panic("Must enable bulk_memory for SDL3 emscripten threading");
                        }
                        mod.addCMacro("__EMSCRIPTEN_PTHREADS__", "1");
                        sdl_config.HAVE_GCC_ATOMICS = true;
                        sdl_config.SDL_THREAD_PTHREAD = true;
                        sdl_config.SDL_THREAD_PTHREAD_RECURSIVE_MUTEX = true;
                        mod.addCSourceFiles(.{
                            .root = sdl_path,
                            .files = &sdlsrc.thread.pthread.c_files,
                            .flags = &.{ "-D_REENTRANT", "-pthread" },
                        });
                    }

                    mod.addCMacro("SDL_PLATFORM_EMSCRIPTEN", "1");
                    mod.addCSourceFiles(.{
                        .root = sdl_path,
                        .files = &emscripten_src_files,
                        .flags = &.{ "-D_REENTRANT", "-pthread" },
                    });
                    mod.addCMacro("USING_GENERATED_CONFIG_H", "");
                    const config_header = b.addConfigHeader(.{
                        .style = .{ .cmake = sdl_api_include_path.path(b, b.pathJoin(&.{
                            "build_config",
                            "SDL_build_config.h.cmake",
                        })) },
                        .include_path = "SDL_build_config.h",
                    }, sdl_config);
                    mod.addConfigHeader(config_header);
                    lib.installConfigHeader(config_header);
                },
                .linux => {
                    @panic("Only building with cmake is supported for now");
                    // NOTE(jae): 2024-10-26
                    // WARNING: Tried to get this working by pulling down dependencies, etc
                    // but ended up being too much of a timesink to keep bothering.
                    //
                    // mod.addCMacro("USING_GENERATED_CONFIG_H", "");
                    // const config_header = b.addConfigHeader(.{
                    //     .style = .{ .cmake = sdl_api_include_path.path(b, b.pathJoin(&.{ "build_config", "SDL_build_config.h.cmake" })) },
                    //     .include_path = "SDL_build_config.h",
                    // }, linuxConfig);
                    // sdl_config_header = config_header;
                    // mod.addConfigHeader(config_header);
                    // mod.installConfigHeader(config_header);
                    //
                    // if (b.lazyDependency("xorgproto", .{})) |xorgproto_dep| {
                    //     // Add X11/X.h
                    //     const xorgproto_include = xorgproto_dep.path("include");
                    //     mod.addIncludePath(xorgproto_include);
                    // }
                    // if (b.lazyDependency("x11", .{})) |x11_dep| {
                    //     // X11/Xmod.h
                    //     const x11_include = x11_dep.path("include");
                    //     mod.addIncludePath(x11_include);
                    //
                    //     mod.addConfigHeader(b.addConfigHeader(.{
                    //         .style = .{ .cmake = x11_include.path(b, "X11/XlibConf.h.in") },
                    //         .include_path = "X11/XlibConf.h",
                    //     }, .{
                    //         // Threading support
                    //         .XTHREADS = true,
                    //         // Use multi-threaded libc functions
                    //         .XUSE_MTSAFE_API = true,
                    //     }));
                    // }
                    //
                    // if (b.lazyDependency("xext", .{})) |xext_dep| {
                    //     // X11/extensions/Xext.h
                    //     const xext_include = xext_dep.path("include");
                    //     mod.addIncludePath(xext_include);
                    // }
                    //
                    // if (b.lazyDependency("dbus", .{})) |dbus_dep| {
                    //     const dbus_include = dbus_dep.path("");
                    //     mod.addIncludePath(dbus_include);
                    //     mod.addConfigHeader(b.addConfigHeader(.{
                    //         .style = .{ .cmake = dbus_include.path(b, "dbus/dbus-arch-deps.h.in") },
                    //         .include_path = "dbus/dbus-arch-deps.h",
                    //     }, .{
                    //         .DBUS_VERSION = "1.14.10",
                    //         .DBUS_INT16_TYPE = "short",
                    //         .DBUS_INT32_TYPE = "int",
                    //         .DBUS_INT64_TYPE = "long",
                    //         .DBUS_INT64_CONSTANT = "(val##L)",
                    //         .DBUS_UINT64_CONSTANT = "(val##UL)",
                    //         .DBUS_MAJOR_VERSION = 1,
                    //         .DBUS_MINOR_VERSION = 14,
                    //         .DBUS_MICRO_VERSION = 10,
                    //     }));
                    // }
                    //
                    // // Included by:
                    // // - src/video/x11/SDL_x11vulkan.c
                    // // - src/video/khronos/vulkan.h
                    // if (b.lazyDependency("xcb", .{})) |xcb_dep| {
                    //     const xcb_header_writefiles = b.addNamedWriteFiles("xcb_headers");
                    //     const xcb_include = xcb_dep.path("src");
                    //     _ = xcb_header_writefiles.addCopyDirectory(xcb_include, "xcb", .{
                    //         .include_extensions = &.{".h"},
                    //     });
                    //     // Add xcbproto - generated xproto.h header
                    //     _ = xcb_header_writefiles.addCopyDirectory(b.path("third-party/xcbproto/src"), "xcb", .{
                    //         .include_extensions = &.{".h"},
                    //     });
                    //     mod.addIncludePath(xcb_header_writefiles.getDirectory());
                    // }
                    //
                    // if (b.lazyDependency("ibus", .{})) |ibus_dep| {
                    //     //if (b.lazyDependency("glib", .{})) |glib_dep| {
                    //     const glib_include = b.path(b.pathJoin(&.{ "third-party", "glib-types" })); // glib_dep.path("");
                    //     const ibus_include = ibus_dep.path("src");
                    //
                    //     // mod.addIncludePath(.{
                    //     //     .cwd_relative = "/usr/lib/x86_64-linux-gnu/glib-2.0/include",
                    //     // });
                    //     // mod.addIncludePath(.{
                    //     //     .cwd_relative = "/usr/include/glib-2.0",
                    //     // });
                    //     // mod.addIncludePath(glib_include); // glib/galloca.h
                    //     // mod.addIncludePath(glib_include.path(b, "glib")); // "gmod.h"
                    //     mod.addIncludePath(glib_include);
                    //     mod.addIncludePath(ibus_include);
                    //
                    //     mod.addConfigHeader(b.addConfigHeader(.{
                    //         .style = .{ .cmake = ibus_include.path(b, "ibusversion.h.in") },
                    //         .include_path = "ibusversion.h",
                    //     }, .{
                    //         .IBUS_MAJOR_VERSION = 1,
                    //         .IBUS_MINOR_VERSION = 5,
                    //         .IBUS_MICRO_VERSION = 30,
                    //     }));
                    //     // }
                    // }
                    // mod.addIncludePath(b.path("third-party/libudev"));
                    // mod.addCSourceFiles(.{
                    //     .root = sdl_path,
                    //     .files = &linux_src_files,
                    //     .flags = &.{
                    //         // X11/Xproto.h include for xcb/xcb.h complains because it's not xproto.h (lowercase x)
                    //         // "-Wno-nonportable-include-path",
                    //     },
                    // });
                    // mod.addCSourceFiles(.{
                    //     .root = sdl_path,
                    //     .files = &sdlsrc.hidapi.linux.c_files,
                    //     .flags = &.{
                    //         // "-std=c17",
                    //     },
                    // });
                },
                else => {
                    mod.addCMacro("USING_GENERATED_CONFIG_H", "");
                    const config_header = b.addConfigHeader(.{
                        .style = .{ .cmake = sdl_api_include_path.path(b, b.pathJoin(&.{ "build_config", "SDL_build_config.h.cmake" })) },
                        .include_path = "SDL_build_config.h",
                    }, SDLConfig{});
                    mod.addConfigHeader(config_header);
                    lib.installConfigHeader(config_header);
                },
            }
        }
        // NOTE(jae): 2024-07-07
        // This must come *after* addConfigHeader logic above for per-OS so that the include for SDL_build_config.h takes precedence
        mod.addIncludePath(sdl_build_config_include_path);

        // NOTE(jae): 2024-04-07
        // Not installing header as we include/export it from the module
        // mod.installHeadersDirectory("include", "SDL");
        b.installArtifact(lib);
    } else {
        // NOTE(jae): 2024-07-02
        // Compiling on Linux is an involved process with various system include directories
        // for dbus, wayland, x11 and who knows what else.
        //
        // So to avoid that complexity for now, we just follow the SDL3 install instructions and
        // execute "cmake", though we set the "CC" environment variable so it uses the Zig C compiler.
        //
        // sudo apt-get update && sudo apt-get install build-essential make \
        //   pkg-config libasound2-dev libpulse-dev \
        //   libaudio-dev libjack-dev libsndio-dev libx11-dev libxext-dev \
        //   libxrandr-dev libxcursor-dev libxfixes-dev libxi-dev libxss-dev \
        //   libxkbcommon-dev libdrm-dev libgbm-dev libgl1-mesa-dev libgles2-mesa-dev \
        //   libegl1-mesa-dev libdbus-1-dev libibus-1.0-dev libudev-dev fcitx-libs-dev \
        //   libpipewire-0.3-dev libwayland-dev libdecor-0-dev
        const mod = b.createModule(.{
            // NOTE(jae): 2024-07-02
            // Need empty file so that Zig build won't complain
            .root_source_file = b.path("src/stub.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        // Add -Dtarget and -Dcpu arguments to the SDL build
        var sdl_host_arg: []const u8 = "";
        var sdl_cpu_arg: []const u8 = "";
        if (!target.query.isNative()) {
            // ie. "arm-raspberry-linux-gnueabihf"
            sdl_host_arg = try target.result.linuxTriple(b.allocator);
            if (!std.mem.eql(u8, target.result.cpu.model.name, "baseline")) {
                sdl_cpu_arg = target.result.cpu.model.name;
            }
        }

        // Set CC environment variable to use the Zig compiler
        var c_compiler_path = b.fmt("{s} cc", .{b.graph.zig_exe});
        if (sdl_host_arg.len > 0) {
            c_compiler_path = b.fmt("{s} --target={s}", .{ c_compiler_path, sdl_host_arg });
        }
        if (sdl_cpu_arg.len > 0) {
            c_compiler_path = b.fmt("{s} -mcpu={s}", .{ c_compiler_path, sdl_cpu_arg });
        }

        // Setup SDL_config.h (if doesn't exist)
        const cmake_setup = b.addSystemCommand(&(.{
            "cmake",
        }));
        cmake_setup.addArg("-S"); // path to source directory
        cmake_setup.addDirectoryArg(sdl_path);
        cmake_setup.addArg("-B"); // path to build directory
        const build_dir = cmake_setup.addOutputDirectoryArg("sdl3_cmake_build");
        const cmake_build_type: []const u8 = switch (optimize) {
            .Debug => "Debug",
            .ReleaseFast => "Release",
            .ReleaseSafe => "RelWithDebInfo",
            .ReleaseSmall => "MinSizeRel",
        };
        cmake_setup.setEnvironmentVariable("CC", b.fmt("{s}", .{c_compiler_path}));
        cmake_setup.addArg("--fresh"); // Configure a fresh build tree, removing an existing cache file.
        cmake_setup.addArg(b.fmt("-DCMAKE_BUILD_TYPE={s}", .{cmake_build_type}));
        // Fixes using "zig cc" with cmake
        // - CMake Error at CMakeLists.txt:436 (message):
        // - Linker does not support '-Wl,--version-script=xxx.sym'.  This is required
        // cmake_setup.addArg("-DCMAKE_REQUIRED_LINK_OPTIONS=cc");
        // Fixes using "zig cc" with cmake
        // - CMake Warning at cmake/sdlchecks.cmake:176 (message):
        // - You must have SDL_LoadObject() support for dynamic PulseAudio loading
        // - Call Stack (most recent call first):
        cmake_setup.addArg("-DHAVE_DLOPEN=1"); //
        cmake_setup.addArg("-DHAVE_PTHREADS=1");
        cmake_setup.addArg("-DSDL_SHARED=OFF");
        cmake_setup.addArg("-DSDL_STATIC=ON");
        cmake_setup.addArg("-DSDL_TESTS=OFF");
        cmake_setup.addArg("-DSDL_DEPS_SHARED=ON");
        // Building Wayland is a pain in the ass across different Linux OSes, not doing.
        //cmake_setup.addArg("-DSDL_WAYLAND=OFF");
        // Gets removed by Steam install and so I uncomment this for local Linux dev
        // cmake_setup.addArg("-DSDL_JACK=OFF");
        // Disable X11 tests ('Couldn't find dependency package for XTEST')
        cmake_setup.addArg("-DSDL_X11_XTEST=OFF");
        cmake_setup.addArg("-DSDL_VENDOR_INFO=Zig");
        cmake_setup.addArg("-DCMAKE_INSTALL_LIBDIR=lib");

        // NOTE(jae): 2026-01-18
        // These aren't used anymore (or never were?) by SDL and I think its causing Wayland include file issues
        // https://github.com/libsdl-org/SDL/blob/97c1df66a8e945317a4accb24261b868672f7757/.github/workflows/generic.yml#L347
        // cmake_setup.addArg("-DCMAKE_INSTALL_BINDIR=bin");
        // cmake_setup.addArg("-DCMAKE_INSTALL_DATAROOTDIR=share");
        // cmake_setup.addArg("-DCMAKE_INSTALL_INCLUDEDIR=include");
        if (b.verbose) {
            cmake_setup.addArg("-Wdev");
        }

        const cmake_build = buildblk: {
            const cmake_build = b.addSystemCommand(&(.{
                "cmake", "--build",
            }));
            cmake_build.step.dependOn(&cmake_setup.step);
            cmake_build.addDirectoryArg(build_dir);

            // Setup config: https://github.com/libsdl-org/SDL/blob/45dfdfbb7b1ac7d13915997c4faa8132187b74e1/.github/workflows/generic.yml#L302C54-L302C70
            cmake_build.addArg("--config");
            cmake_build.addArg(cmake_build_type);

            // cmake_build.addArgs(&.{ "--target", "package" });

            // If editing SDL3 *.c files, this will use cached copies and only rebuild the *.c files
            // that changed
            for (linux_src_files) |linux_src_file| {
                cmake_build.addFileInput(sdl_path.path(b, linux_src_file));
            }
            // NOTE(jae): 2026-01-18
            // wayland-generated-protocols should output as they have newer features like WL_KEYBOARD_KEY_STATE_REPEATED
            cmake_build.addFileInput(build_dir.path(b, "wayland-generated-protocols/wayland-client-protocol.h"));
            if (b.verbose) {
                cmake_build.addArg("--verbose");
            }
            cmake_build.addArg("--parallel");
            break :buildblk cmake_build;
        };

        const cmake_install = b.addSystemCommand(&(.{
            "cmake", "--install",
        }));
        cmake_install.step.dependOn(&cmake_build.step);
        cmake_install.addDirectoryArg(build_dir);
        // Setup config: https://github.com/libsdl-org/SDL/blob/45dfdfbb7b1ac7d13915997c4faa8132187b74e1/.github/workflows/generic.yml#L302C54-L302C70
        cmake_install.addArg("--config");
        cmake_install.addArg(cmake_build_type);
        cmake_install.addArg("--prefix");
        const sdl3_install_dir = cmake_install.addOutputDirectoryArg("sdl3_install");
        if (b.verbose) {
            cmake_install.addArg("--verbose");
        }

        // add sdl3 as system lib to "stub" library
        mod.addLibraryPath(sdl3_install_dir.path(b, "lib"));
        mod.linkSystemLibrary("SDL3", .{});

        const lib = b.addLibrary(.{
            .name = "SDL3",
            .linkage = .static,
            .root_module = mod,
        });
        lib.step.dependOn(&cmake_build.step);
        lib.step.dependOn(&cmake_install.step);

        b.installArtifact(lib);

        // NOTE(jae): 2024-07-14
        // I experimented with getting SDL2 to build for my Raspberry Pi Zero W
        // - zig build -Doptimize=ReleaseSafe -Dtarget=arm-linux-musleabihf -Dcpu=arm1176jzf_s
        // - https://www.leemeichin.com/posts/gettin-ziggy-with-it-pi-zero.html
        //
        // It ran... but required SDL2 to be installed via apt-get and then failed to initialize
        // EGL with the following settings. So... this needs work to actually work.
        // const is_raspberry_pi = (std.mem.eql(u8, sdl_host_arg, "arm-linux-musleabihf") or std.mem.eql(u8, sdl_host_arg, "arm-linux-gnueabihf")) and
        //     std.mem.eql(u8, sdl_cpu_arg, "arm1176jzf_s");
        // if (is_raspberry_pi) {
        //     // Disable for Raspberry Pi
        //     // https://wiki.libsdl.org/SDL2/README/raspberrypi
        //     cmake_setup.addArg("--disable-pulseaudio");
        //     cmake_setup.addArg("--disable-esd");
        //     // Disable for Raspberry Pi
        //     // NOTE(jae): I was missing headers when compiling on my system so.. goodbye
        //     cmake_setup.addArg("--disable-video-wayland");
        //     cmake_setup.addArg("--disable-video-kmsdrm");
        //     cmake_setup.addArg("--disable-sndio"); // sndio is the software layer of the OpenBSD operating system that manages sound cards and MIDI ports
        // }
    }

    // SDL Translate C-code
    var c_translate = b.addTranslateC(.{
        .target = target,
        .optimize = .ReleaseFast,
        .root_source_file = b.path("src/sdl.h"),
    });
    // Set endianness explicitly for arches like the PSP
    c_translate.defineCMacro("SDL_BYTEORDER", sdl_byteorder);
    c_translate.addIncludePath(sdl_api_include_path);

    var module = b.addModule("sdl", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = c_translate.getOutput(),
    });
    module.addIncludePath(sdl_api_include_path);
}

const generic_src_files = sdlsrc.c_files ++
    sdlsrc.atomic.c_files ++
    sdlsrc.audio.c_files ++
    sdlsrc.camera.c_files ++
    sdlsrc.core.c_files ++
    sdlsrc.cpuinfo.c_files ++
    sdlsrc.dialog.c_files ++
    sdlsrc.dynapi.c_files ++
    sdlsrc.events.c_files ++
    // NOTE(jae): 2025-01-19
    // src/io/SDL_iostream.c is the canonical source now
    // sdlsrc.file.c_files ++
    sdlsrc.filesystem.c_files ++
    sdlsrc.gpu.c_files ++
    sdlsrc.haptic.c_files ++
    sdlsrc.haptic.hidapi.c_files ++
    sdlsrc.hidapi.c_files ++
    sdlsrc.io.c_files ++
    sdlsrc.io.generic.c_files ++
    sdlsrc.joystick.c_files ++
    sdlsrc.joystick.virtual.c_files ++
    sdlsrc.joystick.hidapi.c_files ++
    sdlsrc.libm.c_files ++
    sdlsrc.locale.c_files ++
    sdlsrc.main.c_files ++
    sdlsrc.main.generic.c_files ++
    sdlsrc.misc.c_files ++
    sdlsrc.power.c_files ++
    sdlsrc.process.c_files ++
    sdlsrc.render.c_files ++
    sdlsrc.render.gpu.c_files ++
    sdlsrc.render.software.c_files ++
    sdlsrc.sensor.c_files ++
    sdlsrc.stdlib.c_files ++
    sdlsrc.storage.c_files ++
    sdlsrc.storage.generic.c_files ++
    sdlsrc.thread.c_files ++
    sdlsrc.time.c_files ++
    sdlsrc.timer.c_files ++
    sdlsrc.tray.c_files ++
    sdlsrc.video.c_files ++
    sdlsrc.video.yuv2rgb.c_files;

/// Dummy source files, Android build does not use these
const dummy_src_files =
    sdlsrc.audio.dummy.c_files ++
    sdlsrc.camera.dummy.c_files ++
    sdlsrc.dialog.dummy.c_files ++
    sdlsrc.filesystem.dummy.c_files ++
    sdlsrc.haptic.dummy.c_files ++
    sdlsrc.joystick.dummy.c_files ++
    sdlsrc.loadso.dummy.c_files ++
    sdlsrc.misc.dummy.c_files ++
    sdlsrc.process.dummy.c_files ++
    sdlsrc.sensor.dummy.c_files ++
    sdlsrc.video.dummy.c_files;

const windows_src_files = sdlsrc.audio.directsound.c_files ++
    sdlsrc.audio.disk.c_files ++
    sdlsrc.audio.wasapi.c_files ++
    sdlsrc.camera.mediafoundation.c_files ++
    sdlsrc.core.windows.c_files ++
    sdlsrc.dialog.windows.c_files ++
    sdlsrc.filesystem.windows.c_files ++
    // NOTE(jae): 2025-01-19
    // Currently has missing functions and compilation errors, not supported?
    // sdlsrc.gpu.d3d11.c_files ++
    sdlsrc.gpu.d3d12.c_files ++
    sdlsrc.gpu.vulkan.c_files ++
    sdlsrc.haptic.windows.c_files ++
    sdlsrc.hidapi.windows.c_files ++
    sdlsrc.io.windows.c_files ++
    sdlsrc.joystick.windows.c_files ++
    sdlsrc.loadso.windows.c_files ++
    sdlsrc.locale.windows.c_files ++
    sdlsrc.main.windows.c_files ++
    sdlsrc.misc.windows.c_files ++
    sdlsrc.power.windows.c_files ++
    sdlsrc.process.windows.c_files ++
    sdlsrc.render.direct3d.c_files ++
    sdlsrc.render.direct3d11.c_files ++
    sdlsrc.render.direct3d12.c_files ++
    sdlsrc.render.vulkan.c_files ++
    sdlsrc.render.opengl.c_files ++
    sdlsrc.render.opengles2.c_files ++
    sdlsrc.sensor.windows.c_files ++
    sdlsrc.storage.steam.c_files ++
    // Only need these files from: sdlsrc.thread.generic.c_files
    [_][]const u8{
        "src/thread/generic/SDL_sysrwlock.c",
        "src/thread/generic/SDL_syscond.c",
    } ++
    sdlsrc.thread.windows.c_files ++
    sdlsrc.time.windows.c_files ++
    sdlsrc.timer.windows.c_files ++
    sdlsrc.tray.windows.c_files ++
    sdlsrc.video.offscreen.c_files ++
    sdlsrc.video.windows.c_files ++
    dummy_src_files;

const darwin_src_files = sdlsrc.audio.disk.c_files ++
    sdlsrc.gpu.vulkan.c_files ++
    sdlsrc.haptic.darwin.c_files ++
    sdlsrc.joystick.darwin.c_files ++
    sdlsrc.power.macos.c_files ++
    sdlsrc.time.unix.c_files ++
    sdlsrc.timer.unix.c_files ++
    sdlsrc.filesystem.posix.c_files ++
    sdlsrc.storage.steam.c_files ++
    sdlsrc.loadso.dlopen.c_files ++
    sdlsrc.process.posix.c_files ++
    sdlsrc.render.opengl.c_files ++
    sdlsrc.render.opengles2.c_files ++
    sdlsrc.thread.pthread.c_files ++
    sdlsrc.video.offscreen.c_files ++
    dummy_src_files;

const objective_c_src_files = [_][]const u8{} ++
    sdlsrc.audio.coreaudio.objective_c_files ++
    sdlsrc.camera.coremedia.objective_c_files ++
    sdlsrc.dialog.cocoa.objective_c_files ++
    sdlsrc.filesystem.cocoa.objective_c_files ++
    sdlsrc.gpu.metal.objective_c_files ++
    sdlsrc.joystick.apple.objective_c_files ++
    sdlsrc.locale.macos.objective_c_files ++
    sdlsrc.misc.macos.objective_c_files ++
    sdlsrc.power.uikit.objective_c_files ++
    sdlsrc.render.metal.objective_c_files ++
    sdlsrc.sensor.coremotion.objective_c_files ++
    sdlsrc.tray.cocoa.objective_c_files ++
    sdlsrc.video.cocoa.objective_c_files ++
    sdlsrc.video.uikit.objective_c_files;

const ios_src_files = sdlsrc.hidapi.ios.objective_c_files ++
    // sdlsrc.main.ios.objective_c_files
    sdlsrc.misc.ios.objective_c_files;

const android_src_files = sdlsrc.core.android.c_files ++
    sdlsrc.audio.openslES.c_files ++
    sdlsrc.audio.aaudio.c_files ++
    sdlsrc.camera.android.c_files ++
    sdlsrc.dialog.android.c_files ++
    sdlsrc.filesystem.android.c_files ++
    sdlsrc.filesystem.posix.c_files ++
    sdlsrc.gpu.vulkan.c_files ++
    sdlsrc.haptic.android.c_files ++
    sdlsrc.joystick.android.c_files ++
    sdlsrc.locale.android.c_files ++
    sdlsrc.misc.android.c_files ++
    sdlsrc.power.android.c_files ++
    sdlsrc.process.dummy.c_files ++
    sdlsrc.render.vulkan.c_files ++
    sdlsrc.render.opengl.c_files ++
    sdlsrc.render.opengles2.c_files ++
    sdlsrc.sensor.android.c_files ++
    sdlsrc.time.unix.c_files ++
    sdlsrc.timer.unix.c_files ++
    sdlsrc.tray.dummy.c_files ++
    sdlsrc.loadso.dlopen.c_files ++
    sdlsrc.thread.pthread.c_files ++
    sdlsrc.video.android.c_files;

const android_src_cpp_files = sdlsrc.hidapi.android.cpp_files;

const emscripten_src_files = sdlsrc.audio.emscripten.c_files ++
    sdlsrc.audio.dummy.c_files ++
    sdlsrc.camera.dummy.c_files ++
    sdlsrc.camera.emscripten.c_files ++
    sdlsrc.filesystem.emscripten.c_files ++
    sdlsrc.haptic.dummy.c_files ++
    sdlsrc.joystick.emscripten.c_files ++
    sdlsrc.locale.emscripten.c_files ++
    sdlsrc.misc.emscripten.c_files ++
    sdlsrc.power.emscripten.c_files ++
    sdlsrc.video.dummy.c_files ++
    sdlsrc.video.emscripten.c_files ++
    sdlsrc.video.offscreen.c_files ++
    sdlsrc.loadso.dlopen.c_files ++
    sdlsrc.audio.disk.c_files ++
    sdlsrc.render.opengl.c_files ++
    sdlsrc.render.opengles2.c_files ++
    sdlsrc.sensor.dummy.c_files ++
    sdlsrc.timer.unix.c_files ++
    sdlsrc.tray.dummy.c_files;

const linux_src_files = sdlsrc.audio.aaudio.c_files ++
    sdlsrc.audio.alsa.c_files ++
    sdlsrc.audio.pulseaudio.c_files ++
    sdlsrc.audio.jack.c_files ++
    sdlsrc.audio.pulseaudio.c_files ++
    sdlsrc.audio.sndio.c_files ++
    // sdlsrc.camera.pipewire.c_files ++
    sdlsrc.core.linux.c_files ++
    sdlsrc.filesystem.unix.c_files ++
    sdlsrc.gpu.vulkan.c_files ++
    sdlsrc.haptic.linux.c_files ++
    sdlsrc.joystick.linux.c_files ++
    sdlsrc.loadso.dlopen.c_files ++
    sdlsrc.locale.unix.c_files ++
    // sdlsrc.main.gdk.c_files ++
    sdlsrc.misc.unix.c_files ++
    sdlsrc.power.linux.c_files ++
    sdlsrc.process.posix.c_files ++
    sdlsrc.render.vulkan.c_files ++
    sdlsrc.render.opengl.c_files ++
    sdlsrc.render.opengles2.c_files ++
    sdlsrc.storage.steam.c_files ++
    sdlsrc.timer.unix.c_files ++
    sdlsrc.thread.generic.c_files ++
    sdlsrc.tray.unix.c_files ++
    sdlsrc.video.x11.c_files ++
    sdlsrc.video.wayland.c_files ++
    dummy_src_files;

// Playstation Portable source files (not Vita)
const psp_src_files = sdlsrc.audio.dummy.c_files ++
    sdlsrc.audio.psp.c_files ++
    sdlsrc.filesystem.psp.c_files ++
    sdlsrc.filesystem.posix.c_files ++ // From CmakeLists.txt for 'PSP', SDL_sysfsops.c
    sdlsrc.joystick.psp.c_files ++
    sdlsrc.power.psp.c_files ++
    // Only need these files from: sdlsrc.thread.generic.c_files
    [_][]const u8{
        "src/thread/generic/SDL_syscond.c",
        "src/thread/generic/SDL_systls.c",
        "src/thread/generic/SDL_sysrwlock.c",
    } ++
    sdlsrc.thread.psp.c_files ++
    sdlsrc.locale.psp.c_files ++
    sdlsrc.render.psp.c_files ++
    sdlsrc.sensor.dummy.c_files ++
    sdlsrc.time.psp.c_files ++
    sdlsrc.timer.psp.c_files ++
    sdlsrc.tray.dummy.c_files ++
    sdlsrc.misc.dummy.c_files ++
    sdlsrc.video.offscreen.c_files ++
    sdlsrc.video.psp.c_files;

/// Wraps the given value in quotes, this exists for SDL_*_DYNAMIC macros which
/// in SDL_build_config.h.cmake require wrapping the interpolated value in quotes.
fn cMacroString(comptime value: []const u8) []const u8 {
    return "\"" ++ value ++ "\"";
}
