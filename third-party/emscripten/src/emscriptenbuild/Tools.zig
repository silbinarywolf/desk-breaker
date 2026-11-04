const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;

const log = std.log.scoped(.emscripten);

b: *Build,

/// version is the Emscripten version passed to "emsdk install" and "emsdk activate"
/// ie. "latest", "3.1.54"
version: []const u8,
sysroot_include_path: LazyPath,
no_activation_step_emsdk_path: LazyPath,
python_path: []const u8,

pub const Options = struct {
    /// version is the Emscripten version
    /// ie. "latest", "3.1.54"
    version: []const u8,
};

pub fn create(b: *Build, options: Options) ?*Tools {
    const emsdk_path = emSdkPath(b) orelse return null;
    const python_path = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        b.graph.env_map.get("EMSDK_PYTHON") orelse "python"
    else
        b.graph.environ_map.get("EMSDK_PYTHON") orelse "python";
    const emsdk_version = options.version;
    const emsysroot_path = blk: {
        const emsdk_bin = emsdk_path.path(b, "emsdk.py");

        // NOTE(jae): 2025-04-05
        // We run emsdk.py directly as it will actually return error codes on Windows whereas "emsdk.bat" will not,
        // at least under Zig 0.14.0.
        const emsdk_install = b.addSystemCommand(&.{ python_path, "-E" });
        emsdk_install.addFileArg(emsdk_bin);
        emsdk_install.addArgs(&.{ "install", emsdk_version });
        emsdk_install.setName("emsdk install");

        // Activate version
        const emsdk_activate = b.addSystemCommand(&.{ python_path, "-E" });
        emsdk_activate.setName("emsdk activate");
        emsdk_activate.addFileArg(emsdk_bin);
        emsdk_activate.addArgs(&.{ "activate", emsdk_version });
        emsdk_activate.step.dependOn(&emsdk_install.step);

        // Copy sysroot 'include' files
        const emsysroot = b.addNamedWriteFiles("emscriptenbuild_upstream");
        _ = emsysroot.addCopyFile(emsdk_path.path(b, ".emscripten"), ".emscripten");
        _ = emsysroot.addCopyDirectory(emsdk_path.path(b, "upstream/emscripten/cache/sysroot"), "upstream/emscripten/cache/sysroot", .{});
        emsysroot.step.dependOn(&emsdk_activate.step);
        const emsysroot_path = emsysroot.getDirectory();
        break :blk emsysroot_path;
    };
    const tools = b.allocator.create(Tools) catch @panic("OOM");
    tools.* = .{
        .b = b,
        .version = emsdk_version,
        .no_activation_step_emsdk_path = emsdk_path.path(b, "upstream"),
        // NOTE(jae): 2026-10-27
        // Copied so it has to wait for the installer / has steps attached.
        // A hack instead of just making an external Zig app that runs 'emsdk install' / etc for us and outputs it
        // to a folder we expect.
        .sysroot_include_path = emsysroot_path.path(b, "upstream/emscripten/cache/sysroot/include"),
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

    const emcc = b.addRunFile(tools.no_activation_step_emsdk_path.path(b, "emscripten/emcc"));
    // Must setup emscripten SDK before we can run "emcc" as "upstream/**/*" folders won't exist
    tools.addStepDependencies(&emcc.step);

    if (b.graph.verbose) {
        emcc.addArg("-v");
    }
    if (artifact.root_module.optimize) |optimize| {
        switch (optimize) {
            .Debug => {
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
            },
            .ReleaseSmall => {
                emcc.addArg("-sASSERTIONS=0");
                emcc.addArg("-Oz");
            },
            else => {
                emcc.addArg("-sASSERTIONS=0");
                emcc.addArg("-O3");
            },
        }
    }

    if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15) {
        if (artifact.want_lto) |want_lto| {
            if (want_lto) {
                emcc.addArg("-flto");
            }
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

    if (artifact.root_module.resolved_target) |target| {
        // If target has no threading model set
        if (artifact.root_module.single_threaded == null) {
            // If single threaded isn't specifically configured but Emscripten has no atomics
            // then we do not support single threaded, so disable it.
            if (hasFeaturesRequiringThreading(target)) {
                artifact.root_module.single_threaded = true;
            }
        }
        if (std.Target.wasm.featureSetHas(target.result.cpu.features, .bulk_memory_opt)) {
            const fail_step = b.addFail("prefer 'zig build -Dtarget=wasm32-emscripten -Dcpu=mvp', invalid feature for Emscripten 'bulk_memory_opt' was used");
            emcc.step.dependOn(&fail_step.step);
        }
    }

    if (artifact.root_module.single_threaded == true) {
        emcc.addArg("-pthread");
        // emcc.addArg("-sPROXY_TO_PTHREAD");
        // Workaround:
        // https://github.com/emscripten-core/emscripten/issues/16836#issuecomment-1925903719
        // emcc.addArg("-Wl,-u,_emscripten_run_callback_on_thread");
    }

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

    // Setup sysroot includes for C/C++ libraries
    var has_freetype = false;
    const compile_dep_list = getCompileDependencies(b, artifact, true);
    for (compile_dep_list) |compile_dep| {
        const graph = getGraph(b, compile_dep.root_module);
        for (graph.modules) |module| {
            const link_libc = module.link_libc orelse false;
            const link_libcpp = module.link_libcpp orelse false;
            if (link_libc or link_libcpp) {
                // log.info("{s}", .{module.root_source_file.?.getDisplayName()});
                module.addSystemIncludePath(tools.sysroot_include_path);
            }
        }
        // Update translate-c module
        for (graph.modules) |module| {
            const root_source_file = module.root_source_file orelse continue;
            switch (root_source_file) {
                .generated => |gen| {
                    const step: *std.Build.Step = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 16)
                        // Deprecated: Zig 0.16.X, used to get Step directly
                        gen.file.step
                    else
                        b.graph.generated_files.items[@backingInt(gen.index)];
                    const tag = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 16)
                        // Deprecated: Zig 0.16.X, renamed to tag in later versions
                        step.id
                    else
                        step.tag;
                    switch (tag) {
                        .translate_c => {
                            // Detect if using Translate-C vendored version
                            //
                            // NOTE(jae): 2026-04-29
                            // Longterm this will deprecated from Zig

                            const translate_c: *std.Build.Step.TranslateC = @fieldParentPtr("step", step);
                            translate_c.addSystemIncludePath(tools.sysroot_include_path);
                        },
                        .run => {
                            // Detect if using Translate-C external dependency and make assumptions about the flags
                            // we can pass into it such as "isystem" and "-I"
                            //
                            // Name: https://codeberg.org/ziglang/translate-c/src/commit/71642ad0084d433f14b091a7b2b109f0be915dbb/build/Translator.zig#L89
                            // Imports: https://codeberg.org/ziglang/translate-c/src/commit/71642ad0084d433f14b091a7b2b109f0be915dbb/build/Translator.zig#L103-L104
                            if (std.mem.startsWith(u8, step.name, "translate-c ") and
                                (module.import_table.contains("c_builtins") and module.import_table.contains("helpers")))
                            {
                                const run: *std.Build.Step.Run = @fieldParentPtr("step", step);

                                // Exposes the system include path `path` to both translate-c and to `t.mod`.
                                // https://codeberg.org/ziglang/translate-c/src/commit/71642ad0084d433f14b091a7b2b109f0be915dbb/build/Translator.zig#L207-L211
                                module.addSystemIncludePath(tools.sysroot_include_path);
                                run.addPrefixedDirectoryArg("-isystem", tools.sysroot_include_path);
                            }
                        },
                        else => continue,
                    }
                },
                else => continue,
            }
        }
        if (std.mem.eql(u8, compile_dep.name, "freetype")) {
            // NOTE(jae): 2026-10-27
            // Exclude freetype from linker
            has_freetype = true;
        } else {
            emcc.addArtifactArg2(compile_dep, .{});
        }
    }

    if (has_freetype) {
        // NOTE(jae): 2025-02-02
        // Trying to enable correct things so we can just build our own version of freetype
        // emcc.append("-fwasm-exceptions");
        // emcc.append("-sSUPPORT_LONGJMP=wasm");
        // emcc.append("-sSUPPORT_LONGJMP='wasm'");
        emcc.addArg("-sUSE_FREETYPE=1");
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
            const cmd = b.addSystemCommand(&.{ tools.python_path, "-E" });
            cmd.addFileArg(tools.no_activation_step_emsdk_path.path(b, "emscripten/emrun.py"));
            break :blk cmd;
        } else {
            break :blk b.addRunFile(tools.no_activation_step_emsdk_path.path(b, "emscripten/emrun"));
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

/// Ensure emsdk is installed and activated for before given step
fn addStepDependencies(tools: *const Tools, step: *Step) void {
    return tools.sysroot_include_path.addStepDependencies(step);
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

/// Copy-paste of "lib/std/Build/Module.zig" but it doesn't cache via GetGraph and won't potentially break the
/// Zig build system.
///
/// Return the full set of `Step.Compile` which `start` depends on, recursively. `start` itself is
/// always returned as the first element. If `chase_dynamic` is `false`, then dynamic libraries are
/// not included, and their dependencies are not considered; if `chase_dynamic` is `true`, dynamic
/// libraries are treated the same as other linked `Compile`s.
fn getCompileDependencies(b: *Build, start: *Step.Compile, chase_dynamic: bool) []const *Step.Compile {
    const arena = start.step.owner.graph.arena;

    var compiles: std.AutoArrayHashMapUnmanaged(*Step.Compile, void) = .empty;
    var next_idx: usize = 0;

    compiles.putNoClobber(arena, start, {}) catch @panic("OOM");

    while (next_idx < compiles.count()) {
        const compile = compiles.keys()[next_idx];
        next_idx += 1;

        for (getGraph(b, compile.root_module).modules) |mod| {
            for (mod.link_objects.items) |lo| {
                switch (lo) {
                    .other_step => |other_compile| {
                        if (!chase_dynamic and other_compile.isDynamicLibrary()) continue;
                        compiles.put(arena, other_compile, {}) catch @panic("OOM");
                    },
                    else => {},
                }
            }
        }
    }

    return compiles.keys();
}

const Graph = struct {
    modules: []const *std.Build.Module,
    names: []const []const u8,
};

/// Copy-paste of "lib/std/Build/Module.zig" but it doesn't cache and won't potentially break the
/// Zig build system.
///
/// Given that `root` is the root `Module` of a compilation, return all `Module`s
/// in the module graph, including `root` itself. `root` is guaranteed to be the
/// first module in the returned slice.
fn getGraph(b: *Build, root: *std.Build.Module) Graph {
    const arena = b.graph.arena;

    var modules: std.AutoArrayHashMapUnmanaged(*std.Build.Module, []const u8) = .empty;
    var next_idx: usize = 0;

    modules.putNoClobber(arena, root, "root") catch @panic("OOM");

    while (next_idx < modules.count()) {
        const mod = modules.keys()[next_idx];
        next_idx += 1;
        modules.ensureUnusedCapacity(arena, mod.import_table.count()) catch @panic("OOM");
        for (mod.import_table.keys(), mod.import_table.values()) |import_name, other_mod| {
            modules.putAssumeCapacity(other_mod, import_name);
        }
    }

    const result: Graph = .{
        .modules = modules.keys(),
        .names = modules.values(),
    };
    return result;
}

const Tools = @This();
