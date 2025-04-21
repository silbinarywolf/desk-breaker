const std = @import("std");
const builtin = @import("builtin");
const android = if (enable_android_build) @import("android") else void;
const emscripten = @import("emscripten");

// NOTE(jae): 2025-04-13
// Can set this to true to make this build pull down Android dependencies and test
// Desk Breaker on Android devices.
const enable_android_build = false;

const app_name = "Desk Breaker";
const recommended_zig_version = "0.14.0";

pub fn build(b: *std.Build) !void {
    switch (comptime builtin.zig_version.order(std.SemanticVersion.parse(recommended_zig_version) catch unreachable)) {
        .eq => {},
        .lt => {
            @compileError("The minimum version of Zig required to compile " ++ app_name ++ " is " ++ recommended_zig_version ++ ", found " ++ @import("builtin").zig_version_string ++ ".");
        },
        .gt => {
            const colors = std.io.getStdErr().supportsAnsiEscapeCodes();
            std.debug.print(
                "{s}WARNING:\n" ++ app_name ++ " recommends Zig version '{s}', but found '{s}', build may fail...{s}\n\n\n",
                .{
                    if (colors) "\x1b[1;33m" else "",
                    recommended_zig_version,
                    builtin.zig_version_string,
                    if (colors) "\x1b[0m" else "",
                },
            );
        },
    }

    var exe_name: []const u8 = "desk-breaker";
    const maybe_exe_postfix = b.option([]const u8, "binSuffix", "update the binary built suffix, used by CI for '{app}-windows.exe'");
    if (maybe_exe_postfix) |exe_postfix| {
        exe_name = b.fmt("{s}-{s}", .{ exe_name, exe_postfix });
    }

    const root_target = blk: {
        const root_target_query = b.standardTargetOptionsQueryOnly(.{});
        if (root_target_query.os_tag != null and root_target_query.os_tag.? == .emscripten) {
            var query = root_target_query;
            query.cpu_features_add.addFeatureSet(std.Target.wasm.featureSet(&[_]std.Target.wasm.Feature{
                // NOTE(jae): 2025-04-06
                // Not enabling threading (atomics+bulk_memory) because testing on my phone on the same network via "emrun"
                // sucks without something that can serve HTTPS
                // .atomics,
                // .bulk_memory,
                .exception_handling,
                // .reference_types,
            }));
            break :blk b.resolveTargetQuery(query);
        }
        break :blk b.resolveTargetQuery(root_target_query);
    };
    const optimize = b.standardOptimizeOption(.{});

    const targets: []std.Build.ResolvedTarget = blk: {
        var root_target_single = [_]std.Build.ResolvedTarget{root_target};
        if (!enable_android_build) {
            break :blk root_target_single[0..];
        }
        const android_targets = android.standardTargets(b, root_target);
        if (android_targets.len == 0) break :blk root_target_single[0..];
        break :blk android_targets;
    };

    // If building with Android, initialize the tools / build
    const android_apk = blk: {
        if (!root_target.result.abi.isAndroid()) {
            break :blk null;
        }
        if (!enable_android_build) {
            @panic("must set 'enable_android_build' to true");
        }
        const android_tools = android.Tools.create(b, .{
            .api_level = .android15,
            .build_tools_version = "35.0.0",
            .ndk_version = "29.0.13113456",
        });
        const apk = android.APK.create(b, android_tools);

        const key_store_file = android_tools.createKeyStore(android.CreateKey.example());
        apk.setKeyStore(key_store_file);
        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        apk.addResourceDirectory(b.path("android/res"));

        // Add Java files
        apk.addJavaSourceFile(.{ .file = b.path("android/src/DeskBreakerSDLActivity.java") });

        // Add SDL3's Java files like SDL.java, SDLActivity.java, HIDDevice.java, etc
        const sdl_dep = b.dependency("sdl", .{
            .optimize = optimize,
            .target = root_target,
        });
        const sdl_java_files = sdl_dep.namedWriteFiles("sdljava");
        for (sdl_java_files.files.items) |file| {
            apk.addJavaSourceFile(.{ .file = file.contents.copy });
        }
        break :blk apk;
    };

    for (targets) |target| {
        const app = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const library_optimize = if (!target.result.abi.isAndroid() and target.result.os.tag != .emscripten)
            // Debug builds of libraries make Debug binaries about +33mb
            optimize
        else
            // In Zig 0.14.0, for Android/Emscripten builds, make sure we build libraries with ReleaseSafe
            // otherwise we get errors relating to libubsan_rt.a either missing symbols or getting RELOCATION errors
            // https://github.com/silbinarywolf/zig-android-sdk/issues/18
            if (optimize == .Debug) .ReleaseSafe else optimize;

        // add sdl
        const sdl_module = blk: {
            const sdl_dep = b.dependency("sdl", .{
                .optimize = library_optimize,
                .target = target,
            });
            const sdl_lib = sdl_dep.artifact("SDL3");
            app.linkLibrary(sdl_lib);

            // NOTE(jae): 2024-07-03
            // Hack for Linux to use the SDL3 version compiled using native Linux toolszig
            if (target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
                for (sdl_lib.root_module.lib_paths.items) |lib_path| {
                    app.addLibraryPath(lib_path);
                }
            }

            const sdl_module = sdl_dep.module("sdl");
            app.addImport("sdl", sdl_module);

            // NOTE(jae): 2024-07-31
            // Linux can do Mac cross-compilation if we download the macos-sdk lazy dependency
            //
            // - zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
            // - zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos
            if (target.result.os.tag == .macos and b.graph.host.result.os.tag != .macos) {
                if (b.graph.host.result.os.tag == .windows) {
                    @panic("Windows cannot cross-compile to Mac due to symlink not working on all Windows setups: https://github.com/ziglang/zig/issues/17652");
                }
                const maybe_macos_sdk = b.lazyDependency("macos_sdk", .{});
                if (maybe_macos_sdk) |macos_sdk| {
                    const macos_sdk_path = macos_sdk.path("");

                    // add macos sdk to sdl
                    sdl_lib.root_module.addSystemFrameworkPath(macos_sdk_path.path(b, "System/Library/Frameworks"));
                    sdl_lib.root_module.addSystemIncludePath(macos_sdk_path.path(b, "usr/include"));
                    sdl_lib.root_module.addLibraryPath(macos_sdk_path.path(b, "usr/lib"));

                    // add to exe
                    app.addSystemFrameworkPath(macos_sdk_path.path(b, "System/Library/Frameworks"));
                    app.addSystemIncludePath(macos_sdk_path.path(b, "usr/include"));
                    app.addLibraryPath(macos_sdk_path.path(b, "usr/lib"));
                }
            }

            break :blk sdl_module;
        };

        // add freetype
        const freetype_lib = blk: {
            var freetype_dep = b.dependency("freetype", .{
                .target = target,
                .optimize = library_optimize,
            });
            const freetype_lib = freetype_dep.artifact("freetype");
            if (target.result.os.tag != .emscripten) {
                // NOTE(jae): 2025-02-02
                // Link with Emscripten toolchains version instead due to setjmp/etc symbols not being found.
                app.linkLibrary(freetype_lib);
            }
            app.addImport("freetype", freetype_dep.module("freetype"));
            break :blk freetype_lib;
        };

        // add imgui
        {
            const imgui_enable_freetype = true;
            var imgui_dep = b.dependency("imgui", .{
                .target = target,
                // NOTE(jae): 2025-01-27
                // We want assertions in ImGui to tell is if we messed up so we
                // don't just want ReleaseFast here.
                .optimize = library_optimize,
                .enable_freetype = imgui_enable_freetype,
            });
            const imgui_lib = imgui_dep.artifact("imgui");
            app.linkLibrary(imgui_lib);
            app.addImport("imgui", imgui_dep.module("imgui"));

            // Add <ft2build.h> to ImGui so it can compile with Freetype support
            if (imgui_enable_freetype) {
                for (freetype_lib.root_module.include_dirs.items) |freetype_include_dir| {
                    switch (freetype_include_dir) {
                        .path => |p| imgui_lib.addIncludePath(p),
                        else => std.debug.panic("unhandled path from Freetype: {s}", .{@tagName(freetype_include_dir)}),
                    }
                }
            }
            // Add <SDL.h> to ImGui so it can compile with Freetype support
            for (sdl_module.include_dirs.items) |sdl_include_dir| {
                switch (sdl_include_dir) {
                    .path => |p| imgui_lib.addIncludePath(p),
                    .config_header_step => |ch| imgui_lib.addConfigHeader(ch),
                    // NOTE(jae): 2024-07-31: added to ignore Mac system includes used by SDL2 build
                    .path_system, .framework_path_system => continue,
                    else => std.debug.panic("unhandled path from SDL: {s}", .{@tagName(sdl_include_dir)}),
                }
            }
        }

        // add wuffs
        {
            const wuffs_dep = b.dependency("wuffs", .{
                .target = target,
                .optimize = library_optimize,
            });
            app.linkLibrary(wuffs_dep.artifact("wuffs"));
            app.addImport("wuffs", wuffs_dep.module("wuffs"));
        }

        const maybe_linkage: ?std.builtin.LinkMode = if (target.result.abi.isAndroid())
            .dynamic
        else if (target.result.os.tag == .emscripten)
            .static
        else
            null;

        var exe: *std.Build.Step.Compile = if (maybe_linkage) |linkage|
            // Android:    zig build -Dtarget=x86_64-linux-android && adb install ./zig-out/bin/desk-breaker.apk
            // Emscripten: zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast
            b.addLibrary(.{
                .name = exe_name,
                .root_module = app,
                .linkage = linkage,
            })
        else
            // Desktop: zig build
            b.addExecutable(.{
                .name = exe_name,
                .root_module = app,
                // NOTE(jae): 2024-07-06
                // Fails to compile on Zig 0.13.0 with single threaded true
                // when compiling C++
                // .single_threaded = true,
                // NOTE(jae): 2024-05-12
                // Testing with the Zig x86 compiler
                // .use_llvm = false,
            });

        switch (target.result.os.tag) {
            .macos => exe.stack_size = 1024 * 1024,
            .windows => exe.stack_size = 2048 * 1024,
            else => {}, // use default for untested OS
        }

        if (target.result.os.tag == .windows) {
            if (optimize != .Debug and exe.subsystem == null) {
                exe.subsystem = .Windows;
            }
            exe.addWin32ResourceFile(.{
                // NOTE(jae): 2025-01-27
                // RC file references "icon.ico" for the EXE icon
                .file = b.path("src/resources/win.rc"),
                // Anything that rc.exe accepts will work here
                // https://learn.microsoft.com/en-us/windows/win32/menurc/using-rc-the-rc-command-line-
                // This sets the default code page to UTF-8
                .flags = &.{"/c65001"},
            });
        }

        if (target.result.abi.isAndroid()) {
            if (!enable_android_build) {
                @panic("must set 'enable_android_build' to true");
            }
            const apk: *android.APK = android_apk orelse @panic("Android APK should be initialized");
            const android_dep = b.dependency("android", .{
                .target = target,
                .optimize = library_optimize,
            });
            app.addImport("android", android_dep.module("android"));

            apk.addArtifact(exe);
        } else if (target.result.os.tag == .emscripten) {
            const em = emscripten.Tools.create(b, .{
                .version = "3.1.53",
            }) orelse return;

            const run_step = b.step("run", "Run the application in browser");
            const emcc_cmd = em.addRunArtifact(exe, .{
                .browser = .none,
                .hostname = "192.168.0.165",
            });
            run_step.dependOn(&emcc_cmd.step);

            const installed_web_html = em.addInstallArtifact(exe);
            b.getInstallStep().dependOn(&installed_web_html.step);
        } else {
            const run_step = b.step("run", "Run the application");
            const run_cmd = b.addRunArtifact(exe);
            run_step.dependOn(&run_cmd.step);

            const installed_exe = b.addInstallArtifact(exe, .{});
            b.getInstallStep().dependOn(&installed_exe.step);
        }
    }
    if (enable_android_build) {
        if (android_apk) |apk| {
            apk.installApk();
        }
    }

    const test_step = b.step("test", "Run the test suite");
    const test_cmd = b.addRunArtifact(b.addTest(.{
        .root_source_file = b.path("src/testsuite.zig"),
        .target = root_target,
        .optimize = optimize,
    }));
    test_step.dependOn(&test_cmd.step);

    const DeployTarget = struct {
        target_name: []const u8,
        suffix: []const u8,
    };
    const deploy_targets = [_]DeployTarget{
        .{ .target_name = "x86_64-macos", .suffix = "mac-x86" },
        .{ .target_name = "aarch64-macos", .suffix = "mac-arm" },
        .{ .target_name = "x86_64-windows", .suffix = "windows" },
        .{ .target_name = "", .suffix = "linux" },
    };
    const all_targets_step = b.step("all-targets", "Build for all targets (must be run on Linux)");
    for (deploy_targets) |deploy_target| {
        const build_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
        if (deploy_target.target_name.len > 0) {
            build_cmd.addArg(b.fmt("-Dtarget={s}", .{deploy_target.target_name}));
        }
        if (optimize != .Debug) {
            build_cmd.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
        }
        if (deploy_target.suffix.len > 0) {
            build_cmd.addArg(b.fmt("-DbinSuffix={s}", .{deploy_target.suffix}));
        }
        if (b.verbose) {
            build_cmd.addArg("--verbose");
        }
        all_targets_step.dependOn(&build_cmd.step);
    }
}
