const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;
const GeneratedFile = std.Build.GeneratedFile;

const log = std.log.scoped(.emscripten);

b: *Build,

/// version is the Emscripten version passed to "emsdk install" and "emsdk activate"
/// ie. "latest", "3.1.54"
version: []const u8,

emsdk_path: LazyPath,
python_path: []const u8,

pub const Options = struct {
    /// version is the Emscripten version
    /// ie. "latest", "3.1.54"
    version: []const u8,
};

pub fn create(b: *Build, options: Options) ?*Tools {
    const emsdk_path = emSdkPath(b) orelse return null;
    const python_path = std.process.getEnvVarOwned(b.allocator, "EMSDK_PYTHON") catch "python";
    const tools = b.allocator.create(Tools) catch @panic("OOM");
    tools.* = .{
        .b = b,
        .version = options.version,
        .emsdk_path = emsdk_path,
        .python_path = python_path,
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
    const emsdk_upstream_path = tools.emSdkUpstreamPath(emsdk_path);
    // Must setup emscripten SDK before we can run "emcc" as "upstream/**/*" folders won't exist
    emsdk_upstream_path.addStepDependencies(&emcc.step);
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

    // If target has no threading model set
    if (artifact.root_module.resolved_target) |target| {
        if (artifact.root_module.single_threaded == null) {
            // If single threaded isn't specifically configured but Emscripten has no atomics
            // then we do not support single threaded, so disable it.
            if (hasFeaturesRequiringThreading(target)) {
                artifact.root_module.single_threaded = true;
            }
        }
    }

    if (artifact.root_module.single_threaded == true) {
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
    const sysroot_include_path = emsdk_upstream_path.path(b, "emscripten/cache/sysroot/include");

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
            .other_step => |sub_artifact| {
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
    }

    // Find TranslateC dependencies and add system path
    var iter = artifact.root_module.import_table.iterator();
    while (iter.next()) |it| {
        const module = it.value_ptr.*;
        const root_source_file = module.root_source_file orelse continue;
        switch (root_source_file) {
            .generated => |gen| {
                const step = gen.file.step;
                if (step.id != .translate_c) {
                    continue;
                }
                const translate_c: *std.Build.Step.TranslateC = @fieldParentPtr("step", step);
                // NOTE: This calls "sysroot_include_path.addStepDependencies()" within as expected
                translate_c.addSystemIncludePath(sysroot_include_path);
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

/// Browser is the browser to run Emscripten in.
/// https://emscripten.org/docs/compiling/Running-html-files-with-emrun.html#choosing-the-browser-to-run
const Browser = enum {
    default,
    none,
    firefox,
    firefox_beta,
    firefox_aurora,
    firefox_nightly,
    chrome,
    chrome_canary,
    iexplore,
    opera,

    fn string(tag: Browser) []const u8 {
        return switch (tag) {
            .default => "",
            .none => "--no_browser",
            .firefox => "firefox",
            .firefox_beta => "firefox_beta",
            .firefox_aurora => "firefox_aurora",
            .firefox_nightly => "firefox_nightly",
            .chrome => "chrome",
            .chrome_canary => "chrome_canary",
            .iexplore => "iexplore",
            .opera => "opera",
        };
    }
};

const EmRunRunOptions = struct {
    browser: Browser = .default,
    /// Specify the web server TCP hostname.
    /// hostname defaults to "localhost"
    hostname: []const u8 = "",
};

/// Add run artifact
pub fn addRunArtifact(tools: *Tools, artifact: *Step.Compile, options: EmRunRunOptions) *std.Build.Step.Run {
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
            const emrun_path = b.pathJoin(&.{ emsdk_path.getPath(b), "upstream", "emscripten", "emrun.py" });
            break :blk b.addSystemCommand(&.{ tools.python_path, "-E", emrun_path });
        } else {
            const emrun_path = b.pathJoin(&.{ emsdk_path.getPath(b), "upstream", "emscripten", "emrun" });
            break :blk b.addSystemCommand(&.{emrun_path});
        }
    };
    emrun.step.dependOn(&emcc.run.step);

    // TODO: add options
    emrun.addArg("--serve_after_exit");
    emrun.addArg("--serve_after_close");

    const browser: []const u8 = options.browser.string();
    if (browser.len > 0) {
        if (browser[0] == '-') {
            // Handle browser options that map to a flag like `"none" = "--no_browser"`
            emrun.addArg(browser);
        } else {
            emrun.addArg(b.fmt("--browser={s}", .{browser}));
        }
    }

    if (options.hostname.len > 0) {
        emrun.addArg(b.fmt("--hostname={s}", .{options.hostname}));
    }
    emrun.addFileArg(emcc.output_html_file);
    //  emrun.addArg(b.fmt("{s}.html", .{b.pathJoin(&.{ ".", "zig-out", "web-run", artifact.name })}));

    return emrun;
}

/// emSdkUpstreamPath will setup the "emsdk install + emsdk activate" and return the generated
/// upstream path
fn emSdkUpstreamPath(tools: *Tools, emsdk_lazy_path: LazyPath) LazyPath {
    const b = tools.b;
    const emsdk_path = emsdk_lazy_path.getPath(b);
    const has_existing_emscripten_setup = blk: {
        std.fs.accessAbsolute(
            b.pathJoin(&.{ emsdk_path, "upstream", ".emsdk_version" }),
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => {
                @panic(b.fmt("unexpected error detecting .emscripten file: {s}", .{@errorName(err)}));
            },
        };
        break :blk true;
    };

    const emsdk_bin = b.pathJoin(&.{ emsdk_path, "emsdk.py" });

    // NOTE(jae): 2025-04-05
    // We run emsdk.py directly as it will actually return error codes on Windows whereas "emsdk.bat" will not,
    // at least under Zig 0.14.0.
    const emsdk_version = tools.version;
    const emsdk_install = b.addSystemCommand(&.{ tools.python_path, "-E", emsdk_bin, "install", emsdk_version });
    emsdk_install.setName("emsdk install");
    if (has_existing_emscripten_setup) {
        // Bust the cache if this version changes outside of Zig
        emsdk_install.addFileInput(emsdk_lazy_path.path(b, "upstream/.emsdk_version"));
        emsdk_install.addFileInput(emsdk_lazy_path.path(b, "upstream/emscripten/emscripten-version.txt"));
        // HACK: Force to cache run
        _ = emsdk_install.captureStdOut();
    }
    // HACK: Mix has_side_effects to cache
    // emsdk_install.has_side_effects = !has_existing_emscripten_setup;

    // Activate version
    const emsdk_activate = b.addSystemCommand(&.{ tools.python_path, "-E", emsdk_bin, "activate", emsdk_version });
    emsdk_activate.setName("emsdk activate");
    emsdk_activate.step.dependOn(&emsdk_install.step);
    if (has_existing_emscripten_setup) {
        // Bust the cache if this version changes outside of Zig
        emsdk_activate.addFileInput(emsdk_lazy_path.path(b, "upstream/.emsdk_version"));
        emsdk_activate.addFileInput(emsdk_lazy_path.path(b, "upstream/emscripten/emscripten-version.txt"));
        // HACK: Force to cache run
        _ = emsdk_activate.captureStdOut();
    }
    // HACK: Mix has_side_effects to cache
    // emsdk_activate.has_side_effects = !has_existing_emscripten_setup;

    // After "emsdk activate" is complete then the downloaded Emscripten version will have an "upstream" folder
    // with the relevant Emscripten version
    const gen = b.allocator.create(GeneratedFile) catch @panic("OOM");
    gen.* = .{
        .path = b.pathJoin(&.{ emsdk_path, "upstream" }),
        .step = &emsdk_activate.step,
    };
    const path: LazyPath = .{
        .generated = .{ .file = gen },
    };
    return path;
}

fn emSdkPath(b: *Build) ?LazyPath {
    // NOTE(jae): 2025-02-03
    // Consider discovery method that just uses "emsdk" in PATH
    const name = "Emscripten";
    const this_module_name = "emscripten";
    const this_dep: *Build.Dependency = b.lazyDependency(this_module_name, .{}) orelse @panic(b.fmt("must call {s} module '{s}' in your root module", .{ name, this_module_name }));
    const emsdk_dep = this_dep.builder.lazyDependency("emsdk", .{}) orelse return null;
    const emsdk_path = emsdk_dep.path("");
    return emsdk_path;
}

fn hasFeaturesRequiringThreading(target: std.Build.ResolvedTarget) bool {
    // NOTE(jae): 2025-04-06
    // I think threading also requires the .bulk_memory feature as well?
    return std.Target.wasm.featureSetHas(target.result.cpu.features, .atomics);
}

const Tools = @This();
