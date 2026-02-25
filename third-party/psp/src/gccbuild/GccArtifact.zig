//! GccArtifact is for returning the output *.elf (exe) or *.a (library)

const std = @import("std");
const Gcc = @import("Gcc.zig");
const MountRun = @import("MountRun.zig");
const Module = std.Build.Module;
const Compile = std.Build.Step.Compile;
const LazyPath = std.Build.LazyPath;
const log = std.log.scoped(.GccArtifact);

kind: Kind,
run: *MountRun,
artifact: *Compile,

/// (kind == .lib only) The name to use when linking, ie: '{name}_zig'
/// Does *not* have lib prefix or end in .a
link_name: []const u8,

emitted_bin: LazyPath,

pub fn getEmittedBin(compile: *GccArtifact) LazyPath {
    return compile.emitted_bin;
}

pub const Kind = enum {
    exe,
    lib,
};

pub fn createExe(g: *Gcc, artifact: *Compile) *GccArtifact {
    return compileExe(g, artifact);
}

// fn create(g: *Gcc, artifact: *Compile) *GccArtifact {
// switch (artifact.kind) {
//     .exe => {
//         return g.compileBinary(artifact);
//     },
//     .lib => {
//         const linkage = if (artifact.linkage) |l| l else @panic("must set linkage for library");
//         switch (linkage) {
//             .static => {
//                 return g.compileStaticLibrary(artifact, artifact);
//             },
//             .dynamic => @panic("dynamic library linking not implemented"),
//         }
//     },
//     else => std.debug.panic("unimplemented/unsupported artifact kind '{}' for {s}", .{ artifact.kind, artifact.name }),
// }
//}

/// Add compiler_rt to main EXE artifact
///
// NOTE(jae): 2026-01-18
// Enable to resolve undefined reference to '__multi3', '__udivti3', '__divti3', etc
// I've observed this being required for Debug+SDL3+ImGui and also ReleaseFast+SDL3+RmlUi
fn createAndLinkCompilerRt(g: *Gcc, artifact: *Compile) void {
    const b = g.b;
    const mod = artifact.root_module;
    const zig_exe_dir = std.fs.path.dirname(b.graph.zig_exe) orelse
        @panic("unable to get zig path to find zig.h");
    const zig_dir: LazyPath = .{
        .cwd_relative = zig_exe_dir,
    };
    const compiler_rt_mod = b.createModule(.{
        .root_source_file = zig_dir.path(b, "lib/compiler_rt.zig"),
        .target = mod.resolved_target,
        .optimize = mod.optimize,
    });
    var compiler_rt_lib = b.addLibrary(.{
        .name = "compiler_rt",
        .linkage = .static,
        .root_module = compiler_rt_mod,
    });
    // Disable LTO for compiler_rt (NOTE: has no effect unless LTO is enabled for root artifact/binary)
    // We do this to avoid undefined reference errors
    compiler_rt_lib.lto = .none;
    mod.linkLibrary(compiler_rt_lib);
}

fn addGccCommand(g: *Gcc, build_with_cpp: bool, context: []const u8) *MountRun {
    const b = g.b;
    const cmd = MountRun.createFromPath(
        b,
        if (!build_with_cpp) g.gcc() else g.@"g++"(),
        context,
    );
    // NOTE(jae): 2026-01-31
    // Experimenting with running psp-gcc via Docker on Windows
    //
    // const zig_exe_dir = std.fs.path.dirname(b.graph.zig_exe) orelse @panic("unable to get zig path to find zig.h");
    // const zig_dir: LazyPath = .{
    //     .cwd_relative = b.dupe(zig_exe_dir),
    // };
    // const cmd = MountRun.createFromDockerImage(
    //     b,
    //     if (!build_with_cpp) "psp-gcc" else "psp-g++",
    //     "pspdev/pspdev:latest",
    //     .{
    //         .mount_directories = &.{
    //             .{ .local_directory = zig_dir, .docker_directory = "/zig" },
    //             .{ .local_directory = .{ .cwd_relative = b.build_root.path.? }, .docker_directory = "/source" },
    //         },
    //     },
    // );
    return cmd;
}

fn compileExe(g: *Gcc, artifact: *Compile) *GccArtifact {
    if (artifact.root_module.resolved_target.?.result.ofmt != .c) {
        std.debug.panic("must compile '{s}' with target ofmt=.c", .{artifact.name});
    }

    const b = g.b;
    const mod = artifact.root_module;

    // Add compiler_rt to linked libraries
    if (artifact.bundle_compiler_rt) |bundle_compiler_rt| {
        if (bundle_compiler_rt) {
            createAndLinkCompilerRt(g, artifact);
        }
    }

    // Determine if we want to link binary with C++
    var should_link_cpp = false;
    if (mod.link_libcpp == null) {
        checkIfLinkingCppRecursively(&should_link_cpp, artifact.root_module);
        if (should_link_cpp) {
            mod.link_libcpp = true;
        }
    }

    const cmd = addGccCommand(g, should_link_cpp, artifact.name);

    // TODO: How do we know if the file extension should be .elf/etc?
    cmd.addArg("-o");
    const emitted_bin = cmd.addOutputFileArg(b.fmt("{s}.elf", .{artifact.name}));

    if (artifact.link_eh_frame_hdr) {
        cmd.addArg("-Wl,--eh-frame-hdr");
    }
    if (artifact.link_emit_relocs) {
        cmd.addArg("-Wl,--emit-relocs");
    }
    if (artifact.link_gc_sections) |x| {
        cmd.addArg(if (x) "-Wl,--gc-sections" else "-Wl,--no-gc-sections");
    }
    if (mod.strip == true) {
        cmd.addArg("-Wl,--strip-debug");
    }

    // NOTE(jae): 2026-01-30
    // We may need something like this if we want to use LTO but avoid certain
    // functions being stripped.
    //
    // const keep_functions_for_lto = [_][]const u8{
    //     "__fixsfdi",
    //     "__modti3",
    //     "__floatdisf",
    //     "__extendsfdf2",
    // };
    // cmd.addArg("-Wl,--undefined=__modti3");
    // cmd.addArg("-Wl,--undefined=__divdi3");
    // cmd.addArg("-Wl,--undefined=__divdi3");

    // To use the link-time optimizer, -flto and optimization options should be specified at compile time and during the final link.
    // It is recommended that you compile all the files participating in the same link with the same options and also specify those options at link time. For example:
    //   gcc -c -O2 -flto foo.c
    //   gcc -c -O2 -flto bar.c
    //   gcc -o myprog -flto -O2 foo.o bar.o  <- This is where we are here for Zig stuff, linking
    //
    // Source: https://gcc.gnu.org/onlinedocs/gcc-15.1.0/gcc/Optimize-Options.html
    if (artifact.lto) |x| {
        switch (x) {
            // Use -flto=auto to use GNU make's job server, if available, or
            // otherwise fall back to autodetection of the number of CPU threads present in your system.
            // Source: https://gcc.gnu.org/onlinedocs/gcc-15.1.0/gcc/Optimize-Options.html
            .full => cmd.addArg("-flto=auto"),
            .thin => @panic("lto=thin is unsupported by GCC"),
            // .thin => cmd.addArg("-fwhopr"),
            .none => {}, // NOTE(jae): 2026-17-01: Opted to do nothing, cmd.addArg("-fno-lto"),
        }
    }
    defer if (artifact.lto) |x| switch (x) {
        // NOTE(jae): 2026-01-17
        // Resolve Zig 0.15.2 error: "LTO requires using LLD"
        .full, .thin => artifact.lto = null,
        .none => {},
    };

    // Setup optimization level at linker level
    if (mod.optimize) |optimize| {
        switch (optimize) {
            .Debug => cmd.addArg("-O0"),
            .ReleaseSafe => cmd.addArg("-O1"),
            .ReleaseFast => cmd.addArg("-O2"),
            .ReleaseSmall => cmd.addArg("-Os"),
        }
    }

    // If custom linker script provided
    if (artifact.linker_script) |linker_script| {
        cmd.addPrefixedFileArg("-Wl,-q,-T", linker_script);
    }

    // Collect system libraries (WARNING: Must occur before linking as we remove linked libs from main artifact)
    var system_libraries: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer system_libraries.deinit(b.allocator);
    collectSystemLibrariesRecursive(g, &system_libraries, mod, cmd);

    // Handle linking
    {
        // Use start-group and end-group so that link order doesn't matter for GCC
        cmd.addArg("-Wl,--start-group");
        defer cmd.addArg("-Wl,--end-group");

        // Add libraries *and* this artifact (exe) to collected libraries
        //
        // As of Zig 0.15.2 the order looks like
        // - your_app_name
        // - SDL3
        // - freetype
        // - imgui
        // - compiler_rt
        // - rmlui_core
        const libraries = artifact.getCompileDependencies(false);

        // Iterate over collected libraries backwards so that the final linked library
        // is *your application*
        var i: usize = libraries.len;
        while (i > 0) {
            i -= 1;
            const sub_artifact = libraries[i];
            // log.info("library: {s}", .{sub_artifact.name});

            // Create gcc lib
            const lib = compileStaticLibrary(g, artifact, sub_artifact);
            const output_lib = lib.getEmittedBin();

            // Make our binary wait/rely on library
            output_lib.addStepDependencies(&cmd.step);

            // Add library to link
            cmd.addFileInput(output_lib);
            cmd.addArg(b.fmt("-l{s}", .{lib.link_name}));
            cmd.addPrefixedDirectoryArg("-L", output_lib.dirname());
        }
    }

    // Link system libraries
    //
    // NOTE(jae): 2026-01-16
    // We do this seperately / last otherwise PspSdk's psp-fixup-imports gets a warning
    // about not being able to fixup imports.
    {
        // Setup default library paths
        for (g.lib_paths.items) |lib_dir| {
            cmd.addPrefixedDirectoryArg("-L", lib_dir);
        }

        cmd.addArg("-Wl,--start-group");
        defer cmd.addArg("-Wl,--end-group");

        const system_library_names: []const []const u8 = system_libraries.entries.items(.key);
        for (system_library_names) |system_lib| {
            // log.info("system library: {s}", .{system_lib});
            cmd.addArg(b.fmt("-l{s}", .{system_lib}));
        }
    }

    const output_artifact = b.allocator.create(GccArtifact) catch @panic("OOM");
    output_artifact.* = .{
        .kind = .exe,
        .run = cmd,
        .artifact = artifact,
        .emitted_bin = emitted_bin,
        .link_name = &[0]u8{}, // unused for executables
    };
    return output_artifact;
}

const CompileCFileOptions = struct {
    /// file is the C file to compile, if this is null, use artifacts getEmittedBin()
    file: ?LazyPath,
    flags: []const []const u8,

    const zig_c_file: CompileCFileOptions = .{
        .file = null,
        .flags = &.{},
    };
};

fn compileCFile(g: *Gcc, root_artifact: *Compile, artifact: *Compile, options: CompileCFileOptions) LazyPath {
    const b = g.b;
    const mod = artifact.root_module;

    const should_compile_with_gpp = mod.link_libcpp == true and
        options.file != null;

    const cmd = addGccCommand(g, should_compile_with_gpp, artifact.name);
    cmd.addArg("-c");

    // To use the link-time optimizer, -flto and optimization options should be specified at compile time and during the final link.
    // It is recommended that you compile all the files participating in the same link with the same options and also specify those options at link time. For example:
    //   gcc -c -O2 -flto foo.c
    //   gcc -c -O2 -flto bar.c                <- This is where we are here for Zig stuff, compiling a C file
    //   gcc -o myprog -flto -O2 foo.o bar.o
    //
    // Source: https://gcc.gnu.org/onlinedocs/gcc-15.1.0/gcc/Optimize-Options.html
    const lto: ?std.zig.LtoMode = if (artifact.lto) |this_lto|
        // If library has a specific LTO rule, use that instead.
        //
        // NOTE(jae): 2026-01-30
        // This logic was added so that for "compiler_rt", I could add "lto = .none" to the artifact
        // and disable LTO, otherwise runtime functions used by ImGui would could removed.
        this_lto
    else if (root_artifact.lto) |root_lto|
        // Use the root libraries LTO settings, likely the EXE/binary
        root_lto
    else
        null;
    if (lto) |x| {
        switch (x) {
            // Use -flto=auto to use GNU make's job server, if available, or
            // otherwise fall back to autodetection of the number of CPU threads present in your system.
            // Source: https://gcc.gnu.org/onlinedocs/gcc-15.1.0/gcc/Optimize-Options.html
            .full => cmd.addArg("-flto=auto"),
            .thin => @panic("lto=thin is unsupported by GCC"),
            // .thin => cmd.addArg("-fwhopr"), // psp-gcc: error: unrecognized command-line option '-fwhopr'
            .none => {}, // NOTE(jae): 2026-17-01: Opted to do nothing, cmd.addArg("-fno-lto"),
        }
    }
    defer if (artifact.lto) |this_lto| {
        // NOTE(jae): 2026-01-30
        // Resolve Zig 0.15.2 error: "LTO requires using LLD"
        switch (this_lto) {
            .full, .thin => artifact.lto = null,
            .none => {},
        }
    };

    if (root_artifact.link_data_sections) cmd.addArg("-fdata-sections");
    if (root_artifact.link_function_sections) cmd.addArg("-ffunction-sections");
    // psp-gcc: error: unrecognized command-line option '--gc-sections'
    //   cmd.addArg("--gc-sections");
    // psp-gcc: error: unrecognized command-line option '--eh-frame-hdr'
    //   cmd.addArg("--eh-frame-hdr");

    if (artifact.root_module.root_source_file != null) {
        if (artifact.root_module.resolved_target.?.result.ofmt != .c) {
            std.debug.panic("Zig artifact '{s}' has invalid target, must use ofmt=.c", .{artifact.name});
        }

        // NOTE(jae): 2026-01-17
        // Relocation truncated to fit: R_MIPS_GPREL16 against `XX'
        //
        // Enabling the following can disable relative addressing but potentially be much slower
        // I needed this for "wuffs" (PNG loading) to work *or* enabling LTO resolved my issues as well
        // cmd.addArg("-G0");

        // Allow additional include directories specifically for the Zig compiled C file
        //
        // NOTE(jae): 2026-01-16
        // Implemented so we can wrap the default zig.h and include another via this file.
        for (g.zig_include_directories.items) |zig_include_dir| {
            cmd.addPrefixedDirectoryArg("-I", zig_include_dir);
        }

        const zig_h_path: LazyPath = if (g.zig_h_path) |override_zig_h_path| override_zig_h_path else blk: {
            // Add ZIG_BIN_PATH/lib/zig.h
            const zig_exe_dir = std.fs.path.dirname(b.graph.zig_exe) orelse @panic("unable to get zig path to find zig.h");
            const zig_lib_h_dir: LazyPath = .{
                .cwd_relative = zig_exe_dir,
            };
            break :blk zig_lib_h_dir.path(b, "lib/zig.h");
        };

        // Add zig.h directory as an include path and dependency
        cmd.addPrefixedDirectoryArg("-I", zig_h_path.dirname());
        cmd.addFileInput(zig_h_path);
    }

    // Setup optimization level
    const optimize_setting = if (mod.optimize) |lib_optimize|
        // Use library specific optimization level
        lib_optimize
    else if (root_artifact.root_module.optimize) |root_optimize|
        // Fallback to global optimization level
        root_optimize
    else
        null;
    if (optimize_setting) |optimize| {
        switch (optimize) {
            .Debug => cmd.addArg("-O0"),
            .ReleaseSafe => cmd.addArg("-O1"),
            .ReleaseFast => cmd.addArg("-O2"),
            .ReleaseSmall => cmd.addArg("-Os"),
        }
    }

    if (mod.strip == true) {
        cmd.addArg("-s");
    }

    // Setup #define macros
    for (mod.c_macros.items) |c_macro| {
        if (c_macro[0] != '-') std.debug.panic("invalid formatted macro: {s}", .{c_macro});
        cmd.addArg(c_macro);
    }

    // Setup include paths
    // - gcc: Default system include paths
    // - Setup module include paths
    for (g.include_directories.items) |include_dir| {
        cmd.addPrefixedDirectoryArg("-I", include_dir);
    }
    for (mod.include_dirs.items) |include_dir| {
        switch (include_dir) {
            .path => |p| cmd.addPrefixedDirectoryArg("-I", p),
            .path_system => |p| cmd.addPrefixedDirectoryArg("-I", p),
            .other_step => |other_step| {
                // NOTE(jae): 2026-01-14
                // Skip doing anything with these
                _ = other_step;
            },
            .config_header_step => |config_header| {
                cmd.addFileInput(config_header.getOutputFile());
                cmd.addPrefixedDirectoryArg("-I", config_header.getOutputDir());
            },
            .path_after, .framework_path, .framework_path_system, .embed_path => std.debug.panic("{s} not implemented", .{@tagName(include_dir)}),
        }
    }

    for (options.flags) |flag| {
        if (std.mem.eql(u8, flag, "-pthread")) {
            // Ignore LDFLAGS for "it just works" SDL3 compilation compatibility
            continue;
        }
        cmd.addArg(flag);
    }

    const c_file = if (options.file) |c_file|
        // Regular c file
        c_file
    else if (artifact.root_module.root_source_file != null)
        // Zig code compiled into a ".c" file
        artifact.getEmittedBin()
    else
        @panic("missing C file and artifact has no root source file");
    cmd.addFileArg(c_file);

    const output_basename_no_extension: []const u8 = if (options.file) |lp| blk: {
        const path: []const u8 = switch (lp) {
            .src_path => |path| path.sub_path,
            .dependency => |path| path.sub_path,
            .generated => "generated.c",
            else => "unknown.c",
        };
        break :blk std.fs.path.stem(path);
    } else
        // For compiling Zig as as a C-file with .ofmt=c
        artifact.name;

    cmd.addArg("-o");
    return cmd.addOutputFileArg(b.fmt("{s}.o", .{output_basename_no_extension}));
}

/// Combine multiple compiled C/C++ files into a "gcc-ar" library
/// ie. "libimgui_zig.a", "libmain_zig.a"
///
/// We pass the root artifact (output EXE) context so that additional compile features
/// can be enabled such as LTO
fn compileStaticLibrary(g: *Gcc, root_artifact: *Compile, artifact: *Compile) *GccArtifact {
    const b = g.b;
    const mod = artifact.root_module;

    const cmd = MountRun.createFromPath(b, g.ar(), artifact.name);

    // NOTE(jae): 2026-01-15
    // Avoid clashing with SDK provided libraries by appending *_zig. For example, the PSP SDK provides
    // an SDL library and an ImGui library, so if we didn't make our artifact name unique, there would be
    // problems.
    cmd.addArg("-rcs");
    const link_name = b.fmt("{s}_zig_gcc", .{artifact.name});
    const emitted_bin = cmd.addOutputFileArg(b.fmt("lib{s}.a", .{link_name}));

    if (mod.root_source_file != null) {
        const zig_o_file = compileCFile(g, root_artifact, artifact, .zig_c_file);
        cmd.addFileArg(zig_o_file);
    }

    for (mod.link_objects.items) |link_obj| {
        switch (link_obj) {
            .c_source_file => |source_file| {
                const o_file = compileCFile(g, root_artifact, artifact, .{
                    .file = source_file.file,
                    .flags = source_file.flags,
                });
                cmd.addFileArg(o_file);
            },
            .c_source_files => |c_source_file_list| {
                for (c_source_file_list.files) |c_source_file| {
                    const o_file = compileCFile(g, root_artifact, artifact, .{
                        .file = c_source_file_list.root.path(b, c_source_file),
                        .flags = c_source_file_list.flags,
                    });
                    cmd.addFileArg(o_file);
                }
            },
            .system_lib, .other_step => {
                // Ignore as the compileExe() step collects and handles these
            },
            .win32_resource_file => @panic("win32 resource file (.rc) not supported"),
            else => {
                std.debug.panic("{s} not supported", .{@tagName(link_obj)});
            },
        }
    }

    // Update TranslateC modules so that they can compile on alternate platforms
    updateTranslateC(g, artifact);

    // Remove any linked libraries from module recursively
    removeLinkedLibraryRecursively(mod);

    const gcc_lib = b.allocator.create(GccArtifact) catch @panic("OOM");
    gcc_lib.* = .{
        .kind = .lib,
        .run = cmd,
        .link_name = link_name,
        .artifact = artifact,
        .emitted_bin = emitted_bin,
    };
    return gcc_lib;
}

/// Recursively check if any libraries require C++
fn checkIfLinkingCppRecursively(linking_cpp: *bool, mod: *Module) void {
    for (mod.link_objects.items) |link_object| {
        switch (link_object) {
            .other_step => |other_compile| switch (other_compile.kind) {
                .lib => {
                    const other_mod = other_compile.root_module;
                    linking_cpp.* = (other_mod.link_libcpp == true);

                    // exit if true
                    if (linking_cpp.*) return;

                    checkIfLinkingCppRecursively(linking_cpp, other_mod);
                },
                else => continue,
            },
            else => continue,
        }
    }
}

/// Collects all the system libraries recursively and add thems to the args
fn collectSystemLibrariesRecursive(g: *Gcc, system_libraries: *std.StringArrayHashMapUnmanaged(void), mod: *Module, cmd: *MountRun) void {
    const b = g.b;
    const allocator = b.allocator;

    // NOTE(jae): 2026-01-30 - Zig 0.15.2
    // This is imperfect and not as thorough as Zigs dependency graph traversal
    // but it will do for now.
    //
    // We likely want something like the following loop logic to collect everything
    // lib/std/Build/Step/Compile.zig
    //
    //   for (compile.getCompileDependencies(false)) |dep_compile| {
    //     for (dep_compile.root_module.getGraph().modules) |mod| {

    // 1. Walk modules dependencies
    for (mod.import_table.entries.items(.value)) |sub_mod| {
        for (sub_mod.link_objects.items) |link_object| {
            switch (link_object) {
                .other_step => |other_compile| {
                    switch (other_compile.kind) {
                        .lib => {
                            collectSystemLibrariesRecursive(g, system_libraries, other_compile.root_module, cmd);
                        },
                        else => continue,
                    }
                },
                else => continue,
            }
        }
    }

    // 2. Walk linked library dependencies
    for (mod.link_objects.items) |link_object| {
        switch (link_object) {
            .other_step => |other_compile| {
                switch (other_compile.kind) {
                    .lib => {
                        collectSystemLibrariesRecursive(g, system_libraries, other_compile.root_module, cmd);
                    },
                    else => continue,
                }
            },
            else => continue,
        }
    }

    // 3. Finally get top-level modules linked libraries last
    for (mod.link_objects.items) |link_object| {
        switch (link_object) {
            .system_lib => |system_lib| {
                // NOTE(jae): 2026-01-30
                // I don't think GCC supports -weak-l or -needed-l for linker flags
                // so just ignore that for now.
                system_libraries.put(allocator, system_lib.name, {}) catch @panic("OOM");
            },
            else => continue,
        }
    }
}

/// Update TranslateC dependencies that are using "freestanding" to resolve to a specific OS with the same bit width as
/// the CPU arch.
///
/// NOTE(jae): 2026-01-31
/// With the PSP-SDK, I initially just tried adding its GCC headers in but they had missing #defines that caused
/// SDL3 to fall over, so just rewrite the os_tag and cpu_arch to something Zig has the necessary headers for.
fn updateTranslateC(g: *Gcc, artifact: *Compile) void {
    const b = g.b;
    const imported_modules: []*Module = artifact.root_module.import_table.entries.items(.value);
    for (imported_modules) |module| {
        // Find a module that was created from TranslateC
        const root_source_file = module.root_source_file orelse continue;
        switch (root_source_file) {
            .generated => |gen| {
                const step = gen.file.step;
                if (step.id != .translate_c) continue;

                const translate_c: *std.Build.Step.TranslateC = @fieldParentPtr("step", step);
                const target = translate_c.target;
                if (target.result.os.tag == .freestanding) {
                    // NOTE(jae): 2026-01-16
                    // Playstation Portable stdint.h is incorrect here and buggy when used with Zig 0.15.2,
                    // so just fallback to Linux as the target but use the correct bit width and
                    // hope the ABI is similar enough to not crash things.
                    translate_c.target = b.resolveTargetQuery(.{
                        .os_tag = .linux, // .windows
                        .cpu_arch = target.result.cpu.arch, // if (target.result.ptrBitWidth() == 64) .x86_64 else .x86,
                        .abi = null, // target.result.abi, // <- stdint.h not found if we pass ABI
                    });
                }
            },
            else => continue,
        }
    }
}

/// This iterates over a Zig modules:
/// - Imported Modules
/// - Linked Libraries / Objects
/// - Include Headers
///
/// And removes them from the artifact. If we do not do this, then when compiling with ofmt=.c, it will
/// attempt to build that dependency with Zig rather than GCC.
fn removeLinkedLibraryRecursively(mod: *Module) void {
    // Remove direct link objects referencing Zig built libraries to avoid compilation on
    // the root artifact that has .ofmt=.c
    {
        var i: usize = 0;
        var link_objects = &mod.link_objects;
        while (i < link_objects.items.len) {
            switch (link_objects.items[i]) {
                .other_step => |other_compile| switch (other_compile.kind) {
                    .exe, .lib, .obj => {
                        _ = link_objects.orderedRemove(i);
                        continue; // don't increment "i"
                    },
                    else => {}, // fallthrough
                },
                else => {}, // fallthrough
            }
            i += 1;
        }
    }

    // Remove include directories referencing Zig built libraries to avoid compilation on
    // the root artifact that has .ofmt=.c
    {
        var i: usize = 0;
        var include_dirs = &mod.include_dirs;
        while (i < include_dirs.items.len) {
            switch (include_dirs.items[i]) {
                .other_step => |other_compile| switch (other_compile.kind) {
                    .exe, .lib, .obj => {
                        _ = include_dirs.orderedRemove(i);
                        continue; // don't increment "i"
                    },
                    else => {}, // fallthrough
                },
                else => {}, // fallthrough
            }
            i += 1;
        }
    }

    // Remove libraries from imported modules
    {
        const modules: []*Module = mod.import_table.entries.items(.value);
        for (modules) |sub_mod| {
            removeLinkedLibraryRecursively(sub_mod);
        }
    }
}

const GccArtifact = @This();
