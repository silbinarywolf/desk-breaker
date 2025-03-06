const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;

b: *Build,

/// version is the Emscripten version passed to "emsdk install" and "emsdk activate"
/// ie. "latest", "3.1.54"
version: []const u8,

emsdk_path: LazyPath,

pub const Options = struct {
    /// version is the Emscripten version
    /// ie. "latest", "3.1.54"
    version: []const u8,
};

pub fn create(b: *Build, options: Options) ?*Tools {
    const emsdk_path = emSdkPath(b) orelse return null;
    const tools = b.allocator.create(Tools) catch @panic("OOM");
    tools.* = .{
        .b = b,
        .version = options.version,
        .emsdk_path = emsdk_path,
    };
    return tools;
}

const Emcc = struct {
    run: *Step.Run,
    output_html_file: LazyPath,
    output_directory: LazyPath,
};

pub fn addEmccCommand(tools: *Tools, artifact: *Step.Compile) *Emcc {
    const b = tools.b;
    const emsdk_path = tools.emsdk_path;

    const emcc_path = b.pathJoin(&.{ emsdk_path.getPath(b), "upstream", "emscripten", "emcc" }); // emcc

    const emcc = b.addSystemCommand(&[_][]const u8{emcc_path});
    emcc.setName("emcc");
    const emsdk_setup_cmd = tools.emSdkSetupStep(emsdk_path);
    // Must setup emscripten SDK before we can run "emcc" as "upstream/**/*" folders won't exist
    emcc.step.dependOn(&emsdk_setup_cmd.step);
    if (b.verbose) {
        emcc.addArg("-v");
    }
    if (artifact.root_module.optimize) |optimize| {
        if (artifact.root_module.optimize == .Debug) {
            emcc.addArgs(&[_][]const u8{
                "-Og",
                "-sASSERTIONS=1",
                // NOTE(jae): 2024-03-03
                // Can't find docs but SAFE_HEAP=2 is for Wasm only, SAFE_HEAP=1 is for asm.js/wasm.
                // I made this change because I got an alignment error with wasm3.
                // - https://github.com/emscripten-core/emscripten/issues/16685#issuecomment-1129524178
                "-sSAFE_HEAP=2",
                "-sSTACK_OVERFLOW_CHECK=1",
                // note(jae): debug sourcemaps in browser, so you can see the stack of crashes
                "-gsource-map",
            });
        } else {
            emcc.addArg("-sASSERTIONS=0");
            if (optimize == .ReleaseSmall) {
                emcc.addArg("-Oz");
            } else {
                emcc.addArg("-O3");
            }
        }
    }
    if (artifact.want_lto) |want_lto| {
        if (want_lto) {
            emcc.addArg("-flto");
        }
    }

    // if (options.use_webgpu) {
    //     emcc.addArg("-sUSE_WEBGPU=1");
    // }
    // if (options.use_webgl2) {
    //     emcc.addArg("-sUSE_WEBGL2=1");
    // }
    // if (!options.use_filesystem) {
    //     emcc.addArg("-sNO_FILESYSTEM=1");
    // }
    // if (options.use_emmalloc) {
    //     emcc.addArg("-sMALLOC='emmalloc'");
    // }
    // if (options.shell_file_path) |shell_file_path| {
    //     emcc.addArg(b.fmt("--shell-file={s}", .{shell_file_path}));
    // }

    // NOTE(jae): 0224-02-22
    // Need to fix this linker issue
    // linker: Undefined symbol: eglGetProcAddress(). Please pass -sGL_ENABLE_GET_PROC_ADDRESS at link time to link in eglGetProcAddress().
    emcc.addArg("-sGL_ENABLE_GET_PROC_ADDRESS=1");
    if (artifact.initial_memory) |initial_memory| {
        _ = initial_memory; // autofix
        // TODO: setup initial memory, not sure what format Zig is in VS Emscripten

        // Default initial memory
        // Default: 16mb (16777216 bytes)
        emcc.addArg("-sINITIAL_MEMORY=128Mb");

        // TODO: setup initial memory, not sure what format Zig is in VS Emscripten
        // emcc.addArg("-sINITIAL_MEMORY=64Mb");

        // Emscripten documentation: default value here is 2GB
        // if (exe_lib.max_memory) |max_memory| {
        //     emcc.addArg("-sALLOW_MEMORY_GROWTH=1");
        //
        //     // default limit (64mb) crashes wasmtime
        //     emcc.addArg("-sMAXIMUM_MEMORY=256Mb");
        // }
    } else {
        // Default initial memory
        // Default: 16mb (16777216 bytes)
        emcc.addArg("-sINITIAL_MEMORY=128Mb");
    }

    // Default stack size: 64kb
    // https://emscripten.org/docs/tools_reference/settings_reference.html#stack-size
    emcc.addArg("-sSTACK_SIZE=16Mb");

    // Enable threading
    const is_single_threaded: bool = if (artifact.root_module.single_threaded) |st| st else false;
    if (!is_single_threaded) {
        emcc.addArg("-pthread");
        // emcc.addArg("-sPROXY_TO_PTHREAD");
        // Workaround:
        // https://github.com/emscripten-core/emscripten/issues/16836#issuecomment-1925903719
        // emcc.addArg("-Wl,-u,_emscripten_run_callback_on_thread");
    }

    // NOTE(jae): 2025-02-02
    // Trying to enable correct things so we can just build our own version of freetype
    // emcc.append("-fwasm-exceptions");
    // emcc.append("-sSUPPORT_LONGJMP=wasm");
    // emcc.append("-sSUPPORT_LONGJMP='wasm'");
    emcc.addArg("-sUSE_FREETYPE=1");

    // NOTE(jae): 2024-02-24
    // Needed or Zig 0.13.0 crashes with "Aborted(Cannot use convertFrameToPC (needed by __builtin_return_address) without -sUSE_OFFSET_CONVERTER)"
    // for os_tag == .emscripten.
    emcc.addArg("-sUSE_OFFSET_CONVERTER=1");
    // emcc.addArg("-sASYNCIFY");

    // emcc.addArg("--embed-file");
    // emcc.addArg("plugins/rm2k/src/testdata/TheRestful@/wasm_data");

    // create output directory
    const output_html_file = emcc.addPrefixedOutputFileArg("-o", b.fmt("emscripten/{s}.html", .{artifact.name}));

    // for (options.extra_args) |arg| {
    //     emcc.addArg(arg);
    // }

    // Get sysroot includes for C/C++ libraries
    const sysroot_include_path = emsdk_path.path(b, "upstream/emscripten/cache/sysroot/include");

    // If library is built using C or C++ then add system includes
    {
        const link_libc = artifact.root_module.link_libc orelse false;
        const link_libcpp = artifact.root_module.link_libcpp orelse false;
        if (link_libc or link_libcpp) {
            artifact.root_module.addSystemIncludePath(sysroot_include_path);
        }
    }

    // add the main lib, and then scan for library dependencies and add those too
    emcc.addArtifactArg(artifact);

    // iterate over dependencies
    for (artifact.root_module.link_objects.items) |item| {
        switch (item) {
            .other_step => |other_step| {
                const linked_module = other_step.root_module;
                // DEBUG: Module prints
                // std.debug.print("module name: {s}\n", .{item.name});
                // for (item.module.include_dirs.items) |include_dir| {
                //     switch (include_dir) {
                //         .path => {
                //             std.debug.print("- include dir: {s}\n", .{include_dir.path.path});
                //         },
                //         .path_system => {
                //             if (b.sysroot) |sysroot| {
                //                 const include_path = b.pathJoin(&.{ sysroot, "include" });
                //                 module.addSystemIncludePath(b.path(include_path));
                //             }
                //             std.debug.print("- system include dir: {s}\n", .{include_dir.path_system.path});
                //         },
                //         else => {},
                //     }
                // }
                for (linked_module.link_objects.items) |link_object| {
                    switch (link_object) {
                        .other_step => |sub_artifact| {
                            switch (sub_artifact.kind) {
                                .lib => {
                                    // If library is built using C or C++ then add system includes
                                    const link_libc = sub_artifact.root_module.link_libc orelse false;
                                    const link_libcpp = sub_artifact.root_module.link_libcpp orelse false;
                                    if (link_libc or link_libcpp) {
                                        sub_artifact.root_module.addSystemIncludePath(sysroot_include_path);
                                    }

                                    // Add artifact to linker
                                    emcc.addArtifactArg(sub_artifact);
                                },
                                else => continue,
                            }
                        },
                        else => continue,
                    }
                }
            },
            else => continue,
        }
    }

    const emcc_res = b.allocator.create(Emcc) catch @panic("OOM");
    emcc_res.* = .{
        .run = emcc,
        .output_html_file = output_html_file,
        .output_directory = output_html_file.dirname(),
    };
    return emcc_res;
}

pub fn addInstallArtifact(tools: *Tools, artifact: *Step.Compile) *Step.InstallDir {
    const b = tools.b;
    const emcc = tools.addEmccCommand(artifact);
    return b.addInstallDirectory(.{
        .install_dir = .{
            .custom = "web",
        },
        .install_subdir = "",
        .source_dir = emcc.output_directory,
    });
}

/// Add run artifact
pub fn addRunArtifact(tools: *Tools, artifact: *Step.Compile) *std.Build.Step.Run {
    const b = tools.b;
    const emsdk_path = tools.emsdk_path;
    const emcc = tools.addEmccCommand(artifact);

    // This flag injects code into the generated Module object to enable capture of
    // stdout, stderr and exit().
    emcc.run.addArg("--emrun");

    // const install_dir = b.addInstallDirectory(.{
    //     .install_dir = .{
    //         .custom = "web-run",
    //     },
    //     .install_subdir = "",
    //     .source_dir = emcc.output_directory,
    // });

    const emrun = blk: {
        if (b.graph.host.result.os.tag == .windows) {
            // NOTE(jae): 2025-02-03
            // Use Python directly on Windows to avoid "Terminate batch job y/n" dialog which is the worst
            //
            // Mimic behaviour of emrun.bat where it tries to use EMSDK_PYTHON and then just falls back to global "python"
            const python = std.process.getEnvVarOwned(b.allocator, "EMSDK_PYTHON") catch "python";
            const emrun_path = b.pathJoin(&.{ emsdk_path.getPath(b), "upstream", "emscripten", "emrun.py" });
            break :blk b.addSystemCommand(&.{ python, "-E", emrun_path });
        } else {
            const emrun_path = b.pathJoin(&.{ emsdk_path.getPath(b), "upstream", "emscripten", "emrun" });
            break :blk b.addSystemCommand(&.{emrun_path});
        }
    };
    emrun.step.dependOn(&emcc.run.step);

    // TODO: add options
    emrun.addArg("--serve_after_exit");
    emrun.addArg("--serve_after_close");
    emrun.addArg("--browser=chrome");
    emrun.addFileArg(emcc.output_html_file);
    //  emrun.addArg(b.fmt("{s}.html", .{b.pathJoin(&.{ ".", "zig-out", "web-run", artifact.name })}));

    return emrun;
}

/// One-time setup of the Emscripten SDK (runs 'emsdk install + activate'). If the
/// SDK had to be setup, a run step will be returned which should be added
/// as dependency to the sokol library (since this needs the emsdk in place),
/// if the emsdk was already setup, null will be returned.
fn emSdkSetupStep(tools: *Tools, emsdk_lazy_path: LazyPath) *Step.Run {
    const b = tools.b;
    const emsdk_path = emsdk_lazy_path.getPath(b);
    const exe_suffix = if (b.graph.host.result.os.tag == .windows) ".bat" else "";
    const emsdk = b.pathResolve(&[_][]const u8{
        emsdk_path, b.fmt("emsdk{s}", .{exe_suffix}),
    });
    const emsdk_setup_path = b.pathJoin(&.{ emsdk_path, ".emscripten" });
    const has_existing_emscripten_setup = blk: {
        std.fs.accessAbsolute(emsdk_setup_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => {
                @panic(b.fmt("unexpected error detecting .emscripten file: {s}", .{@errorName(err)}));
            },
        };
        break :blk true;
    };
    // NOTE(jae): 2025-02-02
    // As of 2025-02-02,  latest = 3.1.54
    const emsdk_version = tools.version;
    const emsdk_install = b.addSystemCommand(&[_][]const u8{ emsdk, "install", emsdk_version });
    emsdk_install.setName("emsdk install");
    if (has_existing_emscripten_setup) {
        // Bust the cache if this version changes outside of Zig
        emsdk_install.addFileInput(emsdk_lazy_path.path(b, "upstream/.emsdk_version"));
        emsdk_install.addFileInput(emsdk_lazy_path.path(b, "upstream/emscripten/emscripten-version.txt"));
    }
    _ = emsdk_install.captureStdOut(); // Do captureStdOut to cache the run
    const emsdk_activate = b.addSystemCommand(&[_][]const u8{ emsdk, "activate", emsdk_version });
    emsdk_activate.setName("emsdk activate");
    if (has_existing_emscripten_setup) {
        // Bust the cache if this version changes outside of Zig
        emsdk_install.addFileInput(emsdk_lazy_path.path(b, "upstream/.emsdk_version"));
        emsdk_activate.addFileInput(emsdk_lazy_path.path(b, "upstream/emscripten/emscripten-version.txt"));
    }
    _ = emsdk_activate.captureStdOut(); // Do captureStdOut to cache the run
    emsdk_activate.step.dependOn(&emsdk_install.step);
    return emsdk_activate;
}

fn emSdkPath(b: *Build) ?LazyPath {
    // NOTE(jae): 2025-02-03
    // Consider discovery method that just uses "emsdk" in PATH
    const this_dep: *Build.Dependency = b.lazyDependency("zig-emscripten-sdk", .{}) orelse @panic("must call emscripten module 'zig-emscripten-sdk' in your root module");
    const emsdk_dep = this_dep.builder.lazyDependency("emsdk", .{}) orelse return null;
    const emsdk_path = emsdk_dep.path("");
    return emsdk_path;
}

const Tools = @This();
