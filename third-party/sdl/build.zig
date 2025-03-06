const std = @import("std");
const builtin = @import("builtin");

const Dependency = std.Build.Dependency;
const LazyPath = std.Build.LazyPath;
const SDLBuildGenerator = @import("tools/gen_sdlbuild.zig").SDLBuildGenerator;
const SDLConfig = @import("src/build/sdlbuild.zig").SDLConfig;
const sdlsrc = @import("src/build/sdlbuild.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_path: LazyPath = blk: {
        const dep: *Dependency = b.lazyDependency("sdl3", .{}) orelse {
            break :blk b.path("");
        };
        std.fs.accessAbsolute(dep.path("src/SDL.c").getPath(b), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidDependency,
            else => return err,
        };
        break :blk dep.path("");
    };

    const sdl_api_include_path = sdl_path.path(b, "include");
    const sdl_build_config_include_path = sdl_api_include_path.path(b, "build_config");

    // Generate source file stuff
    const do_sdl_codegen = b.option(bool, "generate", "run code generation") orelse false;
    if (do_sdl_codegen) {
        var gen = try SDLBuildGenerator.init(b.allocator, sdl_path.getPath(b));
        defer gen.deinit();
        try gen.generateSDLConfig();
        try gen.generateSDLBuild();
        try gen.formatAndWriteFile(b.pathJoin(&.{ b.path("").getPath(b), "src", "build", "sdlbuild.zig" }));
    }

    const use_cmake = target.result.os.tag == .linux and target.result.abi != .android;
    if (!use_cmake) {
        const lib = if (target.result.abi != .android) b.addStaticLibrary(.{
            .name = "SDL3",
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) else b.addSharedLibrary(.{
            .name = "SDL3",
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        lib.addCSourceFiles(.{
            .root = sdl_path,
            .files = &generic_src_files,
        });
        lib.addIncludePath(sdl_path.path(b, "src")); // SDL_internal.h, etc
        lib.addIncludePath(sdl_api_include_path); // SDL3/*.h, etc

        // Set for SDL_revision.h
        // - If building with cmake, SDL_revision.h generally sets 'SDL_REVISION' to 'SDL-3.1.3-no-vcs'
        // - If building SDL3 via Github Actions, it sets this to: "Github Workflow"
        lib.root_module.addCMacro("SDL_VENDOR_INFO", "\"zig-sdl3\"");

        // Used for SDL_egl.h and SDL_opengles2.h
        lib.root_module.addCMacro("SDL_USE_BUILTIN_OPENGL_DEFINITIONS", "1");

        if (target.result.abi == .android) {
            lib.root_module.addCSourceFiles(.{
                .root = sdl_path,
                .files = &android_src_files,
            });

            const has_hidapi = true;
            if (has_hidapi) {
                lib.root_module.addCSourceFiles(.{
                    .root = sdl_path,
                    .files = &android_src_cpp_files,
                    .flags = &.{"-std=c++11"},
                });
                lib.linkLibCpp();
            }

            // This is needed for "src/render/opengles/SDL_render_gles.c" to compile
            lib.root_module.addCMacro("GL_GLEXT_PROTOTYPES", "1");

            // https://github.com/libsdl-org/SDL/blob/release-2.30.6/Android.mk#L82C62-L82C69
            lib.linkSystemLibrary("dl");
            lib.linkSystemLibrary("GLESv1_CM");
            lib.linkSystemLibrary("GLESv2");
            lib.linkSystemLibrary("OpenSLES");
            lib.linkSystemLibrary("log");
            lib.linkSystemLibrary("android");

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
        } else {
            switch (target.result.os.tag) {
                .windows => {
                    lib.root_module.addCMacro("HAVE_MODF", "1");

                    // Between Zig 0.13.0 and Zig 0.14.0, "windows.gaming.input.h" was removed from "lib/libc/include/any-windows-any"
                    // This folder brings all headers needed by that one file so that SDL3 can be compiled for Windows.
                    lib.addIncludePath(b.path("upstream/any-windows-any"));

                    lib.addCSourceFiles(.{
                        .root = sdl_path,
                        .files = &windows_src_files,
                    });
                    lib.addWin32ResourceFile(.{
                        // SDL version
                        .file = sdl_path.path(b, sdlsrc.core.windows.win32_resource_files[0]),
                    });
                    lib.addWin32ResourceFile(.{
                        // HIDAPI version
                        .file = sdl_path.path(b, sdlsrc.hidapi.windows.win32_resource_files[0]),
                        .include_paths = &.{
                            sdl_path.path(b, "src/hidapi/hidapi"),
                        },
                    });
                    lib.linkSystemLibrary("setupapi");
                    lib.linkSystemLibrary("winmm");
                    lib.linkSystemLibrary("gdi32");
                    lib.linkSystemLibrary("imm32");
                    lib.linkSystemLibrary("version");
                    lib.linkSystemLibrary("oleaut32"); // SDL_windowssensor.c, symbol "SysFreeString"
                    lib.linkSystemLibrary("ole32");
                },
                .macos => {
                    // NOTE(jae): 2024-07-07
                    // Cross-compilation from Linux to Mac requires more effort currently (Zig 0.13.0)
                    // See: https://github.com/ziglang/zig/issues/1349

                    lib.addCSourceFiles(.{
                        .root = sdl_path,
                        .files = &darwin_src_files,
                    });
                    lib.addCSourceFiles(.{
                        .root = sdl_path,
                        .files = &objective_c_src_files,
                        .flags = &.{"-fobjc-arc"},
                    });

                    lib.linkFramework("AVFoundation"); // Camera
                    lib.linkFramework("AudioToolbox");
                    lib.linkFramework("Carbon");
                    lib.linkFramework("Cocoa");
                    lib.linkFramework("CoreAudio");
                    lib.linkFramework("CoreMedia");
                    lib.linkFramework("CoreHaptics");
                    lib.linkFramework("CoreVideo");
                    lib.linkFramework("ForceFeedback");
                    lib.linkFramework("GameController");
                    lib.linkFramework("IOKit");
                    lib.linkFramework("Metal");

                    lib.linkFramework("AppKit");
                    lib.linkFramework("CoreFoundation");
                    lib.linkFramework("Foundation");
                    lib.linkFramework("CoreGraphics");
                    lib.linkFramework("CoreServices"); // undefined symbol: _UCKeyTranslate, _Cocoa_AcceptDragAndDrop
                    lib.linkFramework("QuartzCore"); // undefined symbol: OBJC_CLASS_$_CAMetalLayer
                    lib.linkFramework("UniformTypeIdentifiers"); // undefined symbol: _OBJC_CLASS_$_UTType
                    lib.linkSystemLibrary("objc"); // undefined symbol: _objc_release, _objc_begin_catch
                },
                .emscripten => {
                    const is_single_threaded = if (lib.root_module.single_threaded) |st| st else false;
                    if (is_single_threaded) {
                        lib.addCSourceFiles(.{
                            .root = sdl_path,
                            .files = &sdlsrc.thread.generic.c_files,
                        });
                        @panic("SDL3: have not setup build to support single threaded");
                    } else {
                        lib.addCSourceFiles(.{
                            .root = sdl_path,
                            .files = &sdlsrc.thread.pthread.c_files,
                        });
                    }

                    lib.root_module.addCMacro("SDL_PLATFORM_EMSCRIPTEN", "1");
                    if (!is_single_threaded) {
                        lib.root_module.addCMacro("__EMSCRIPTEN_PTHREADS__", "1");
                    }
                    // NOTE(jae): 2025-02-02
                    // SDL_iostream.c needs this and doesn't include SDL_build_config.h
                    lib.root_module.addCMacro("HAVE_STDIO_H", "1");
                    lib.addCSourceFiles(.{
                        .root = sdl_path,
                        .files = &emscripten_src_files,
                    });

                    lib.root_module.addCMacro("USING_GENERATED_CONFIG_H", "");
                    const config_header = b.addConfigHeader(.{
                        .style = .{ .cmake = sdl_api_include_path.path(b, b.pathJoin(&.{
                            "build_config",
                            "SDL_build_config_emscripten.h",
                        })) },
                        .include_path = "SDL_build_config.h",
                    }, .{});
                    // const config_header = b.addConfigHeader(.{
                    //     .style = .{ .cmake = sdl_api_include_path.path(b, b.pathJoin(&.{ "build_config", "SDL_build_config.h.cmake" })) },
                    //     .include_path = "SDL_build_config.h",
                    // }, SDLConfig{
                    //     .SDL_TIMER_UNIX = true,
                    //     .SDL_FILESYSTEM_EMSCRIPTEN = true,
                    //     .SDL_POWER_EMSCRIPTEN = true,
                    //     .SDL_JOYSTICK_EMSCRIPTEN = true,
                    //     .SDL_AUDIO_DRIVER_EMSCRIPTEN = true,
                    //     .SDL_VIDEO_DRIVER_EMSCRIPTEN = true,
                    //     .SDL_CAMERA_DRIVER_EMSCRIPTEN = true,
                    //     .SDL_HAPTIC_DISABLED = true,
                    //     .HAVE_STDARG_H = true,
                    //     .HAVE_STDDEF_H = true,
                    //     .HAVE_STDINT_H = true,
                    //     // NOTE(jae): 2025-02-02
                    //     // SDL_iostream.c needs this
                    //     .HAVE_STDIO_H = true,
                    //     .SDL_THREAD_PTHREAD = !is_single_threaded,
                    //     .SDL_THREAD_PTHREAD_RECURSIVE_MUTEX = !is_single_threaded,
                    // });

                    lib.addConfigHeader(config_header);
                    lib.installConfigHeader(config_header);
                },
                .linux => {
                    @panic("Only building with cmake is supported for now");
                    // NOTE(jae): 2024-10-26
                    // WARNING: Tried to get this working by pulling down dependencies, etc
                    // but ended up being too much of a timesink to keep bothering.
                    //
                    // lib.root_module.addCMacro("USING_GENERATED_CONFIG_H", "");
                    // const config_header = b.addConfigHeader(.{
                    //     .style = .{ .cmake = sdl_api_include_path.path(b, b.pathJoin(&.{ "build_config", "SDL_build_config.h.cmake" })) },
                    //     .include_path = "SDL_build_config.h",
                    // }, linuxConfig);
                    // sdl_config_header = config_header;
                    // lib.addConfigHeader(config_header);
                    // lib.installConfigHeader(config_header);
                    //
                    // if (b.lazyDependency("xorgproto", .{})) |xorgproto_dep| {
                    //     // Add X11/X.h
                    //     const xorgproto_include = xorgproto_dep.path("include");
                    //     lib.addIncludePath(xorgproto_include);
                    // }
                    // if (b.lazyDependency("x11", .{})) |x11_dep| {
                    //     // X11/Xlib.h
                    //     const x11_include = x11_dep.path("include");
                    //     lib.addIncludePath(x11_include);
                    //
                    //     lib.addConfigHeader(b.addConfigHeader(.{
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
                    //     lib.addIncludePath(xext_include);
                    // }
                    //
                    // if (b.lazyDependency("dbus", .{})) |dbus_dep| {
                    //     const dbus_include = dbus_dep.path("");
                    //     lib.addIncludePath(dbus_include);
                    //     lib.addConfigHeader(b.addConfigHeader(.{
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
                    //     lib.addIncludePath(xcb_header_writefiles.getDirectory());
                    // }
                    //
                    // if (b.lazyDependency("ibus", .{})) |ibus_dep| {
                    //     //if (b.lazyDependency("glib", .{})) |glib_dep| {
                    //     const glib_include = b.path(b.pathJoin(&.{ "third-party", "glib-types" })); // glib_dep.path("");
                    //     const ibus_include = ibus_dep.path("src");
                    //
                    //     // lib.addIncludePath(.{
                    //     //     .cwd_relative = "/usr/lib/x86_64-linux-gnu/glib-2.0/include",
                    //     // });
                    //     // lib.addIncludePath(.{
                    //     //     .cwd_relative = "/usr/include/glib-2.0",
                    //     // });
                    //     // lib.addIncludePath(glib_include); // glib/galloca.h
                    //     // lib.addIncludePath(glib_include.path(b, "glib")); // "glib.h"
                    //     lib.addIncludePath(glib_include);
                    //     lib.addIncludePath(ibus_include);
                    //
                    //     lib.addConfigHeader(b.addConfigHeader(.{
                    //         .style = .{ .cmake = ibus_include.path(b, "ibusversion.h.in") },
                    //         .include_path = "ibusversion.h",
                    //     }, .{
                    //         .IBUS_MAJOR_VERSION = 1,
                    //         .IBUS_MINOR_VERSION = 5,
                    //         .IBUS_MICRO_VERSION = 30,
                    //     }));
                    //     // }
                    // }
                    // lib.addIncludePath(b.path("third-party/libudev"));
                    // lib.addCSourceFiles(.{
                    //     .root = sdl_path,
                    //     .files = &linux_src_files,
                    //     .flags = &.{
                    //         // X11/Xproto.h include for xcb/xcb.h complains because it's not xproto.h (lowercase x)
                    //         // "-Wno-nonportable-include-path",
                    //     },
                    // });
                    // lib.addCSourceFiles(.{
                    //     .root = sdl_path,
                    //     .files = &sdlsrc.hidapi.linux.c_files,
                    //     .flags = &.{
                    //         // "-std=c17",
                    //     },
                    // });
                },
                else => {
                    lib.root_module.addCMacro("USING_GENERATED_CONFIG_H", "");
                    const config_header = b.addConfigHeader(.{
                        .style = .{ .cmake = sdl_api_include_path.path(b, b.pathJoin(&.{ "build_config", "SDL_build_config.h.cmake" })) },
                        .include_path = "SDL_build_config.h",
                    }, SDLConfig{});

                    lib.addConfigHeader(config_header);
                    lib.installConfigHeader(config_header);
                },
            }
        }
        // NOTE(jae): 2024-07-07
        // This must come *after* addConfigHeader logic above for per-OS so that the include for SDL_build_config.h takes precedence
        lib.addIncludePath(sdl_build_config_include_path);

        // NOTE(jae): 2024-04-07
        // Not installing header as we include/export it from the module
        // lib.installHeadersDirectory("include", "SDL");
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
        const lib = b.addStaticLibrary(.{
            .name = "SDL3",
            // NOTE(jae): 2024-07-02
            // Need empty file so that Zig build won't complain
            .root_source_file = b.path("src/linux.zig"),
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
        var c_compiler_path = b.fmt("{s} cc -std=c89", .{b.graph.zig_exe});
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
        cmake_setup.addArg("-DSDL_DISABLE_INSTALL_DOCS=ON");
        cmake_setup.addArg("-DSDL_TESTS=OFF");
        // Building Wayland is a pain in the ass across different Linux OSes, not doing.
        // cmake_setup.addArg("-DSDL_WAYLAND=OFF");
        // Gets removed by Steam install and so I uncomment this for local Linux dev
        // cmake_setup.addArg("-DSDL_JACK=OFF");
        cmake_setup.addArg("-DSDL_VENDOR_INFO=Zig");
        cmake_setup.addArg("-DCMAKE_INSTALL_BINDIR=bin");
        cmake_setup.addArg("-DCMAKE_INSTALL_DATAROOTDIR=share");
        cmake_setup.addArg("-DCMAKE_INSTALL_INCLUDEDIR=include");
        cmake_setup.addArg("-DCMAKE_INSTALL_LIBDIR=lib");
        if (b.verbose) {
            cmake_setup.addArg("-Wdev");
        }

        const cmake_build = b.addSystemCommand(&(.{
            "cmake", "--build",
        }));
        cmake_build.step.dependOn(&cmake_setup.step);
        // If editing SDL3 *.c files, this will use cached copies and only rebuild the *.c files
        // that changed
        for (linux_src_files) |linux_src_file| {
            cmake_build.addFileInput(sdl_path.path(b, linux_src_file));
        }
        cmake_build.addDirectoryArg(build_dir);
        // Setup config: https://github.com/libsdl-org/SDL/blob/45dfdfbb7b1ac7d13915997c4faa8132187b74e1/.github/workflows/generic.yml#L302C54-L302C70
        cmake_build.addArg("--config");
        cmake_build.addArg(cmake_build_type);
        if (b.verbose) {
            cmake_build.addArg("--verbose");
        }
        cmake_build.addArg("--parallel");

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
        lib.addLibraryPath(sdl3_install_dir.path(b, "lib"));
        lib.linkSystemLibrary("SDL3");
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
        // NOTE(jae): 2024-11-05
        // Translating C-header API only so we use host so that Android builds
        // will compile correctly.
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .root_source_file = b.path("src/sdl.h"),
    });
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
    sdlsrc.tray.unix.c_files ++
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
    sdlsrc.loadso.dlopen.c_files ++
    sdlsrc.thread.pthread.c_files ++
    sdlsrc.video.android.c_files;

const android_src_cpp_files = sdlsrc.hidapi.android.cpp_files;

const emscripten_src_files = sdlsrc.audio.emscripten.c_files ++
    sdlsrc.audio.dummy.c_files ++
    sdlsrc.camera.emscripten.c_files ++
    sdlsrc.filesystem.emscripten.c_files ++
    sdlsrc.haptic.dummy.c_files ++
    sdlsrc.joystick.emscripten.c_files ++
    sdlsrc.locale.emscripten.c_files ++
    sdlsrc.misc.emscripten.c_files ++
    sdlsrc.power.emscripten.c_files ++
    sdlsrc.video.emscripten.c_files ++
    sdlsrc.loadso.dlopen.c_files ++
    sdlsrc.audio.disk.c_files ++
    sdlsrc.render.opengl.c_files ++
    sdlsrc.render.opengles2.c_files ++
    sdlsrc.sensor.dummy.c_files ++
    sdlsrc.timer.unix.c_files ++
    sdlsrc.tray.dummy.c_files;
// const emscripten_src_files = [_][]const u8{
//     "src/audio/emscripten/SDL_emscriptenaudio.c",
//     "src/filesystem/emscripten/SDL_sysfilesystem.c",
//     "src/joystick/emscripten/SDL_sysjoystick.c",
//     "src/locale/emscripten/SDL_syslocale.c",
//     "src/misc/emscripten/SDL_sysurl.c",
//     "src/power/emscripten/SDL_syspower.c",
//     "src/video/emscripten/SDL_emscriptenevents.c",
//     "src/video/emscripten/SDL_emscriptenframebuffer.c",
//     "src/video/emscripten/SDL_emscriptenmouse.c",
//     "src/video/emscripten/SDL_emscriptenopengles.c",
//     "src/video/emscripten/SDL_emscriptenvideo.c",

//     "src/timer/unix/SDL_systimer.c",
//     "src/loadso/dlopen/SDL_sysloadso.c",
//     "src/audio/disk/SDL_diskaudio.c",
//     "src/render/opengles2/SDL_render_gles2.c",
//     "src/render/opengles2/SDL_shaders_gles2.c",
//     "src/sensor/dummy/SDL_dummysensor.c",
//     "src/thread/pthread/SDL_syscond.c",
//     "src/thread/pthread/SDL_sysmutex.c",
//     "src/thread/pthread/SDL_syssem.c",
//     "src/thread/pthread/SDL_systhread.c",
//     "src/thread/pthread/SDL_systls.c",
// };

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

/// NOTE(jae): 2024-10-24
/// This configuration was copy-pasted out of my SDL_build_config.h file after creating it
/// via the Linux build instructions. While this won't necessarily be accurate to all targets
/// I figure it's a good start.
// const linuxConfig: SDLConfig = .{
//     .HAVE_GCC_ATOMICS = true,
//     // LibC headers
//     .HAVE_LIBC = true,
//     .HAVE_ALLOCA_H = true,
//     .HAVE_FLOAT_H = true,
//     .HAVE_ICONV_H = true,
//     .HAVE_INTTYPES_H = true,
//     .HAVE_LIMITS_H = true,
//     .HAVE_MALLOC_H = true,
//     .HAVE_MATH_H = true,
//     .HAVE_MEMORY_H = true,
//     .HAVE_SIGNAL_H = true,
//     .HAVE_STDARG_H = true,
//     .HAVE_STDBOOL_H = true,
//     .HAVE_STDDEF_H = true,
//     .HAVE_STDINT_H = true,
//     .HAVE_STDIO_H = true,
//     .HAVE_STDLIB_H = true,
//     .HAVE_STRINGS_H = true,
//     .HAVE_STRING_H = true,
//     .HAVE_SYS_TYPES_H = true,
//     .HAVE_WCHAR_H = true,
//
//     // C library functions
//     .HAVE_DLOPEN = true,
//     .HAVE_MALLOC = true,
//     .HAVE_CALLOC = true,
//     .HAVE_REALLOC = true,
//     .HAVE_FREE = true,
//     .HAVE_GETENV = true,
//     .HAVE_SETENV = true,
//     .HAVE_PUTENV = true,
//     .HAVE_UNSETENV = true,
//     .HAVE_ABS = true,
//     .HAVE_BCOPY = true,
//     .HAVE_MEMSET = true,
//     .HAVE_MEMCPY = true,
//     .HAVE_MEMMOVE = true,
//     .HAVE_MEMCMP = true,
//     .HAVE_WCSLEN = true,
//     .HAVE_WCSNLEN = true,
//     .HAVE_WCSLCPY = true,
//     .HAVE_WCSLCAT = true,
//     .HAVE_WCSDUP = true,
//     .HAVE_WCSSTR = true,
//     .HAVE_WCSCMP = true,
//     .HAVE_WCSNCMP = true,
//     .HAVE_WCSTOL = true,
//     .HAVE_STRLEN = true,
//     .HAVE_STRNLEN = true,
//     .HAVE_STRLCPY = true,
//     .HAVE_STRLCAT = true,
//     .HAVE_STRPBRK = true,
//     .HAVE_INDEX = true,
//     .HAVE_RINDEX = true,
//     .HAVE_STRCHR = true,
//     .HAVE_STRRCHR = true,
//     .HAVE_STRSTR = true,
//     .HAVE_STRTOK_R = true,
//     .HAVE_STRTOL = true,
//     .HAVE_STRTOUL = true,
//     .HAVE_STRTOLL = true,
//     .HAVE_STRTOULL = true,
//     .HAVE_STRTOD = true,
//     .HAVE_ATOI = true,
//     .HAVE_ATOF = true,
//     .HAVE_STRCMP = true,
//     .HAVE_STRNCMP = true,
//     .HAVE_STRCASESTR = true,
//     .HAVE_SSCANF = true,
//     .HAVE_VSSCANF = true,
//     .HAVE_VSNPRINTF = true,
//     .HAVE_ACOS = true,
//     .HAVE_ACOSF = true,
//     .HAVE_ASIN = true,
//     .HAVE_ASINF = true,
//     .HAVE_ATAN = true,
//     .HAVE_ATANF = true,
//     .HAVE_ATAN2 = true,
//     .HAVE_ATAN2F = true,
//     .HAVE_CEIL = true,
//     .HAVE_CEILF = true,
//     .HAVE_COPYSIGN = true,
//     .HAVE_COPYSIGNF = true,
//     .HAVE_COS = true,
//     .HAVE_COSF = true,
//     .HAVE_EXP = true,
//     .HAVE_EXPF = true,
//     .HAVE_FABS = true,
//     .HAVE_FABSF = true,
//     .HAVE_FLOOR = true,
//     .HAVE_FLOORF = true,
//     .HAVE_FMOD = true,
//     .HAVE_FMODF = true,
//     .HAVE_ISINF = true,
//     .HAVE_ISINFF = true,
//     .HAVE_ISINF_FLOAT_MACRO = true,
//     .HAVE_ISNAN = true,
//     .HAVE_ISNANF = true,
//     .HAVE_ISNAN_FLOAT_MACRO = true,
//     .HAVE_LOG = true,
//     .HAVE_LOGF = true,
//     .HAVE_LOG10 = true,
//     .HAVE_LOG10F = true,
//     .HAVE_LROUND = true,
//     .HAVE_LROUNDF = true,
//     .HAVE_MODF = true,
//     .HAVE_MODFF = true,
//     .HAVE_POW = true,
//     .HAVE_POWF = true,
//     .HAVE_ROUND = true,
//     .HAVE_ROUNDF = true,
//     .HAVE_SCALBN = true,
//     .HAVE_SCALBNF = true,
//     .HAVE_SIN = true,
//     .HAVE_SINF = true,
//     .HAVE_SQRT = true,
//     .HAVE_SQRTF = true,
//     .HAVE_TAN = true,
//     .HAVE_TANF = true,
//     .HAVE_TRUNC = true,
//     .HAVE_TRUNCF = true,
//     .HAVE_FOPEN64 = true,
//     .HAVE_FSEEKO = true,
//     .HAVE_FSEEKO64 = true,
//     .HAVE_MEMFD_CREATE = true,
//     .HAVE_POSIX_FALLOCATE = true,
//     .HAVE_SIGACTION = true,
//     .HAVE_SA_SIGACTION = true,
//     .HAVE_ST_MTIM = true,
//     .HAVE_SETJMP = true,
//     .HAVE_NANOSLEEP = true,
//     .HAVE_GMTIME_R = true,
//     .HAVE_LOCALTIME_R = true,
//     .HAVE_NL_LANGINFO = true,
//     .HAVE_SYSCONF = true,
//     .HAVE_CLOCK_GETTIME = true,
//     .HAVE_GETPAGESIZE = true,
//     .HAVE_ICONV = true,
//     .HAVE_PTHREAD_SETNAME_NP = true,
//     .HAVE_SEM_TIMEDWAIT = true,
//     .HAVE_GETAUXVAL = true,
//     .HAVE_POLL = true,
//     .HAVE__EXIT = true,
//     // End of C library functions
//
//     .HAVE_DBUS_DBUS_H = true,
//     .HAVE_FCITX = true,
//     .HAVE_IBUS_IBUS_H = true,
//     .HAVE_SYS_INOTIFY_H = true,
//     .HAVE_INOTIFY_INIT = true,
//     .HAVE_INOTIFY_INIT1 = true,
//     .HAVE_INOTIFY = true,
//     .HAVE_O_CLOEXEC = true,
//
//     .HAVE_LINUX_INPUT_H = true,
//     .HAVE_LIBUDEV_H = true,
//
//     .HAVE_LIBDECOR_H = true,
//     .SDL_LIBDECOR_VERSION_MAJOR = 0,
//     .SDL_LIBDECOR_VERSION_MINOR = 2,
//     .SDL_LIBDECOR_VERSION_PATCH = 2,
//
//     // .SDL_AUDIO_DRIVER_ALSA = true,
//     // .SDL_AUDIO_DRIVER_ALSA_DYNAMIC = "libasound.so.2",
//     .SDL_AUDIO_DRIVER_DISK = true,
//     .SDL_AUDIO_DRIVER_DUMMY = true,
//     // .SDL_AUDIO_DRIVER_JACK = true,
//     // .SDL_AUDIO_DRIVER_JACK_DYNAMIC = "libjack.so.0",
//
//     // Enable various input drivers
//     .SDL_INPUT_LINUXEV = true,
//     .SDL_INPUT_LINUXKD = true,
//     .SDL_JOYSTICK_HIDAPI = true,
//     .SDL_JOYSTICK_LINUX = true,
//     .SDL_JOYSTICK_VIRTUAL = true,
//     .SDL_HAPTIC_LINUX = true,
//     .SDL_UDEV_DYNAMIC = cMacroString("libudev.so.1"),
//
//     // Enable various process implementations
//     .SDL_PROCESS_POSIX = true,
//
//     // Enable various sensor drivers
//     .SDL_SENSOR_DUMMY = true,
//
//     // Enable various shared object loading systems
//     .SDL_LOADSO_DLOPEN = true,
//
//     // Enable various threading systems
//     .SDL_THREAD_PTHREAD = true,
//     .SDL_THREAD_PTHREAD_RECURSIVE_MUTEX = true,
//
//     // Enable various RTC systems
//     .SDL_TIME_UNIX = true,
//
//     // Enable various timer systems
//     .SDL_TIMER_UNIX = true,
//
//     // Enable various video drivers
//     .SDL_VIDEO_DRIVER_DUMMY = true,
//     // .SDL_VIDEO_DRIVER_KMSDRM = true, // TODO: Fix KMSDrm
//     // .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC = cMacroString("libdrm.so.2"),
//     // .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC_GBM = cMacroString("libgbm.so.1"),
//     // .SDL_VIDEO_DRIVER_OFFSCREEN = true,
//     // .SDL_VIDEO_DRIVER_WAYLAND = true, // TODO: Fix Wayland
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC = cMacroString("libwayland-client.so.0"),
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_CURSOR = cMacroString("libwayland-cursor.so.0"),
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_EGL = cMacroString("libwayland-egl.so.1"),
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_LIBDECOR = cMacroString("libdecor-0.so.0"),
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_XKBCOMMON = cMacroString("libxkbcommon.so.0"),
//     .SDL_VIDEO_DRIVER_X11 = true,
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC = cMacroString("libX11.so.6"),
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XEXT = cMacroString("libXext.so.6"), // TODO: Fix X11 ext
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XSS = cMacroString("libXss.so.1"), // TODO: Fix X11 xss
//     // .SDL_VIDEO_DRIVER_X11_HAS_XKBLOOKUPKEYSYM = true,
//     .SDL_VIDEO_DRIVER_X11_SUPPORTS_GENERIC_EVENTS = true,
//     // .SDL_VIDEO_DRIVER_X11_XCURSOR = true, // TODO: Fix X11-cursor
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XCURSOR = cMacroString("libXcursor.so.1"),
//     // .SDL_VIDEO_DRIVER_X11_XDBE = true, // TODO: Fix X11-dbe
//     // .SDL_VIDEO_DRIVER_X11_XFIXES = true, // TODO: Fix X11-xfixes
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XFIXES = cMacroString("libXfixes.so.3"),
//     // .SDL_VIDEO_DRIVER_X11_XINPUT2 = true,
//     // .SDL_VIDEO_DRIVER_X11_XINPUT2_SUPPORTS_MULTITOUCH = true,
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XINPUT2 = cMacroString("libXi.so.6"),
//     // .SDL_VIDEO_DRIVER_X11_XRANDR = true,
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XRANDR = cMacroString("libXrandr.so.2"),
//     // .SDL_VIDEO_DRIVER_X11_XSCRNSAVER = true,
//     // .SDL_VIDEO_DRIVER_X11_XSHAPE = true,
//
//     .SDL_VIDEO_RENDER_GPU = true,
//     .SDL_VIDEO_RENDER_VULKAN = true,
//     .SDL_VIDEO_RENDER_OGL = true,
//     .SDL_VIDEO_RENDER_OGL_ES2 = true,
//
//     // Enable OpenGL support
//     .SDL_VIDEO_OPENGL = true,
//     .SDL_VIDEO_OPENGL_ES = true,
//     .SDL_VIDEO_OPENGL_ES2 = true,
//     // .SDL_VIDEO_OPENGL_GLX = true, // TODO: add missing header
//     // .SDL_VIDEO_OPENGL_EGL = true, // TODO: need EGL/egl.h - src/video/x11/SDL_x11window
//
//     // Enable Vulkan support
//     .SDL_VIDEO_VULKAN = true,
//
//     // Enable GPU support
//     .SDL_GPU_VULKAN = true,
//
//     // Enable system power support
//     .SDL_POWER_LINUX = true,
//
//     // Whether SDL_DYNAMIC_API needs dlopen
//     .DYNAPI_NEEDS_DLOPEN = true,
//
//     // Enable ime support
//     .SDL_USE_IME = true,
//
//     // Configure use of intrinsics
//     .SDL_DISABLE_LSX = true,
//     .SDL_DISABLE_LASX = true,
//     .SDL_DISABLE_NEON = true,
// };

/// Wraps the given value in quotes, this exists for SDL_*_DYNAMIC macros which
/// in SDL_build_config.h.cmake require wrapping the interpolated value in quotes.
fn cMacroString(comptime value: []const u8) []const u8 {
    return "\"" ++ value ++ "\"";
}
