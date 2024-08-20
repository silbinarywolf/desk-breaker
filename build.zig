const std = @import("std");
const builtin = @import("builtin");

const app_name = "Desk Breaker";
const recommended_zig_version = "0.13.0";

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

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // const os_tag = target.result.os.tag;

    // Build
    var exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        // TODO(jae): 2024-07-22
        // Use Rufus as an example for setting up Windows manifest
        // https://github.com/pbatard/rufus/blob/master/src/rufus.manifest
        // and https://github.com/pbatard/rufus/blob/master/src/rufus.rc (for .ico)
        // .win32_manifest =
        // NOTE(jae): 2024-07-06
        // Fails to compile on Zig 0.13.0 with single threaded true
        // when compiling C++
        // .single_threaded = true,
        // NOTE(jae): 2024-05-12
        // Testing with the Zig x86 compiler
        // .use_llvm = false,
        // .use_lld = true,
    });
    switch (target.result.os.tag) {
        .macos => exe.stack_size = 1024 * 1024,
        .windows => exe.stack_size = 2048 * 1024,
        else => {}, // use default for untested OS
    }
    if (target.result.os.tag == .windows and exe.subsystem == null) {
        exe.subsystem = .Windows;
    }

    // add sdl
    const sdl_module = blk: {
        const sdl_dep = b.dependency("sdl", .{
            .optimize = .ReleaseFast,
            .target = target,
        });
        const sdl_lib = sdl_dep.artifact("sdl");
        exe.linkLibrary(sdl_lib);

        // NOTE(jae): 2024-07-03
        // Hack for Linux to use the SDL2 version compiled using native Linux toolszig
        if (target.result.os.tag == .linux) {
            for (sdl_lib.root_module.lib_paths.items) |lib_path| {
                exe.addLibraryPath(lib_path);
            }
        }
        // NOTE(jae): 2024-07-02
        // Old logic that existed in: https://github.com/andrewrk/sdl-zig-demo
        // if (target.query.isNativeOs() and target.result.os.tag == .linux) {
        //     // The SDL package doesn't work for Linux yet, so we rely on system
        //     // packages for now.
        //     exe.linkSystemLibrary("SDL2");
        //     exe.linkLibC();
        // } else {
        //     exe.linkLibrary(sdl_lib);
        // }

        const sdl_module = sdl_dep.module("sdl");
        exe.root_module.addImport("sdl", sdl_module);

        // NOTE(jae): 2024-07-31
        // Experiment with MacOS cross-compilation
        // - zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
        // - zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos
        if (target.result.os.tag == .macos) {
            if (b.host.result.os.tag == .windows) {
                @panic("Windows cannot cross-compile to Mac due to symlink not working on all Windows setups: https://github.com/ziglang/zig/issues/17652");
            }
            const maybe_macos_sdk = b.lazyDependency("macos-sdk", .{});
            if (maybe_macos_sdk) |macos_sdk| {
                const macos_sdk_path = macos_sdk.path("root");

                // add macos sdk to sdl
                sdl_lib.root_module.addSystemFrameworkPath(macos_sdk_path.path(b, "System/Library/Frameworks"));
                sdl_lib.root_module.addSystemIncludePath(macos_sdk_path.path(b, "usr/include"));
                sdl_lib.root_module.addLibraryPath(macos_sdk_path.path(b, "usr/lib"));

                // add to exe
                exe.root_module.addSystemFrameworkPath(macos_sdk_path.path(b, "System/Library/Frameworks"));
                exe.root_module.addSystemIncludePath(macos_sdk_path.path(b, "usr/include"));
                exe.root_module.addLibraryPath(macos_sdk_path.path(b, "usr/lib"));
            }
        }

        break :blk sdl_module;
    };

    // add freetype
    const freetype_lib = blk: {
        var freetype_dep = b.dependency("freetype", .{
            .target = target,
            .optimize = .ReleaseFast,
        });
        const freetype_lib = freetype_dep.artifact("freetype");
        exe.root_module.linkLibrary(freetype_lib);
        exe.root_module.addImport("freetype", freetype_dep.module("freetype"));
        break :blk freetype_lib;
    };

    // add imgui
    {
        const imgui_enable_freetype = true;
        var imgui_dep = b.dependency("imgui", .{
            .target = target,
            .optimize = .ReleaseFast,
            .enable_freetype = imgui_enable_freetype,
        });
        const imgui_lib = imgui_dep.artifact("imgui");
        exe.root_module.linkLibrary(imgui_lib);
        exe.root_module.addImport("imgui", imgui_dep.module("imgui"));

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

    // add zigimg
    {
        const zigimg_dep = b.dependency("zigimg", .{
            .target = target,
            .optimize = .ReleaseFast,
        });
        exe.root_module.addImport("zigimg", zigimg_dep.module("zigimg"));
    }
    const installed_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&installed_exe.step);

    const run_step = b.step("run", "Run the application");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Rus the test suite");
    const test_cmd = b.addRunArtifact(b.addTest(.{
        .root_source_file = b.path("src/testsuite.zig"),
        .target = target,
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
