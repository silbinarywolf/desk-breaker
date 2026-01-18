const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const Run = Step.Run;
const LazyPath = Build.LazyPath;

const Gcc = @import("Gcc.zig");

owner: *Build,
gcc: *Gcc,
cmd: *Run,
root_artifact: *Step.Compile,
artifact: *Step.Compile,
force_exe: bool,
emitted_bin: ?LazyPath,

pub const Options = struct {
    gcc: *Gcc,
    force_exe: bool,
    /// if null defaults to given artifact in create
    root_artifact: ?*Step.Compile,
};

pub fn create(b: *std.Build, artifact: *Step.Compile, options: Options) *GccCompile {
    const mod = artifact.root_module;
    // const gcc = options.gcc;

    if (!options.force_exe) {
        if (artifact.linkage) |linkage| {
            switch (linkage) {
                .static => {
                    const cmd = Step.Run.create(b, b.fmt("run ar {s}", .{artifact.name}));
                    cmd.addFileArg(options.gcc.ar());

                    const gcc_artifact = b.allocator.create(GccCompile) catch @panic("OOM");
                    gcc_artifact.* = .{
                        .owner = b,
                        .gcc = options.gcc,
                        .cmd = cmd,
                        .root_artifact = if (options.root_artifact) |root_artifact| root_artifact else artifact,
                        .artifact = artifact,
                        .force_exe = options.force_exe,
                        .emitted_bin = null,
                    };
                    _ = gcc_artifact.getEmittedBin();

                    for (mod.link_objects.items) |link_obj| {
                        switch (link_obj) {
                            .c_source_file => |source_file| {
                                const o_file = gcc_artifact.compileCFile(.{
                                    .file = source_file.file,
                                    .flags = source_file.flags,
                                });
                                cmd.addFileArg(o_file);
                            },
                            .c_source_files => |c_source_file_list| {
                                for (c_source_file_list.files) |c_source_file| {
                                    const o_file = gcc_artifact.compileCFile(.{
                                        .file = c_source_file_list.root.path(b, c_source_file),
                                        .flags = c_source_file_list.flags,
                                    });
                                    cmd.addFileArg(o_file);
                                }
                            },
                            .system_lib, .other_step => {}, // not applicable to link when creating archive ("*.a")
                            .win32_resource_file => @panic("win32 resource file (.rc) not supported"),
                            else => {
                                std.debug.panic("{s} not supported", .{@tagName(link_obj)});
                            },
                        }
                    }

                    return gcc_artifact;
                },
                .dynamic => @panic("dynamic library linking not implemented"),
            }
        }
    }

    var is_cpp = false;
    setIfLinkingCppRecursively(&is_cpp, artifact.root_module);

    const cmd = Step.Run.create(b, b.fmt("run {s} {s}", .{
        if (!is_cpp) "gcc" else "g++",
        artifact.name,
    }));
    const gcc_artifact = b.allocator.create(GccCompile) catch @panic("OOM");
    gcc_artifact.* = .{
        .owner = b,
        .gcc = options.gcc,
        .cmd = cmd,
        .root_artifact = if (options.root_artifact) |root_artifact| root_artifact else artifact,
        .artifact = artifact,
        .force_exe = options.force_exe,
        .emitted_bin = null,
    };

    if (!is_cpp) {
        cmd.addFileArg(options.gcc.gcc());
    } else {
        cmd.addFileArg(options.gcc.@"g++"());
    }
    _ = gcc_artifact.getEmittedBin();

    if (mod.root_source_file != null) {
        const target = mod.resolved_target orelse @panic("missing target on artifact.root_module");
        switch (target.result.ofmt) {
            .c => {
                const o_file = gcc_artifact.compileCFile(.zig_c_file);
                cmd.addFileArg(o_file);
            },
            // NOTE(jae): 2026-01-17
            // At least for the PSP SDK linking in an .elf/.o file doesn't work correctly with Zig
            // as it builds with -mdouble-float and not -msingle-float
            // .elf => {
            //     cmd.addFileArg(gcc_artifact.artifact.getEmittedBin());
            // },
            else => {
                const triple = target.result.zigTriple(b.allocator) catch @panic("OOM");
                std.debug.panic("target ({s}) must be using ofmt=c to pass into gcc, but got '.{s}' for {s}", .{ artifact.name, @tagName(target.result.ofmt), triple });
            },
        }
    } else {
        cmd.step.dependOn(&b.addFail("missing root source file").step);
    }

    // cmd.addArg("-fPIC"); // psp/bin/ld: error: lto-wrapper failed
    // cmd.addArg("-fPIE"); // psp/bin/ld: error: lto-wrapper failed
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
        // TODO: Test this setting
        cmd.addArg("-Wl,--strip-debug");
    }

    // To use the link-time optimizer, -flto and optimization options should be specified at compile time and during the final link.
    // It is recommended that you compile all the files participating in the same link with the same options and also specify those options at link time. For example:
    //   gcc -c -O2 -flto foo.c
    //   gcc -c -O2 -flto bar.c
    //   gcc -o myprog -flto -O2 foo.o bar.o  <- This is where we are here for Zig stuff, linking
    //
    // Source: https://gcc.gnu.org/onlinedocs/gcc-15.1.0/gcc/Optimize-Options.html
    const lto = gcc_artifact.root_artifact.lto;
    if (lto) |x| {
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
    defer if (artifact == gcc_artifact.root_artifact) {
        // NOTE(jae): 2026-01-17
        // Resolve Zig 0.15.2 error: "LTO requires using LLD"
        if (lto) |x| {
            switch (x) {
                .full, .thin => artifact.lto = null,
                .none => {},
            }
        }
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

    for (mod.link_objects.items) |link_obj| {
        switch (link_obj) {
            .system_lib => continue, // Handled by linkSystemLibRecursive
            .other_step => |other_compile| {
                switch (other_compile.kind) {
                    .lib => {
                        // Create gcc lib
                        const lib = create(b, other_compile, .{
                            .gcc = options.gcc,
                            .force_exe = false,
                            .root_artifact = gcc_artifact.root_artifact,
                        });
                        const name = other_compile.name;

                        const output_lib = lib.getEmittedBin();
                        output_lib.addStepDependencies(&artifact.step);

                        // Add argument of the l
                        cmd.addArg(b.fmt("-l{s}_zig", .{name}));
                        cmd.addFileInput(output_lib);

                        cmd.addPrefixedDirectoryArg("-L", output_lib.dirname());
                    },
                    .obj, .exe, .@"test", .test_obj => {
                        std.debug.panic("{s} not implemented", .{@tagName(link_obj)});
                    },
                }
            },
            .c_source_file, .c_source_files => @panic(b.fmt("c source file not supported outside of static library, affected artifact '{s}'", .{artifact.name})),
            .win32_resource_file => @panic("win32 resource file (.rc) not supported"),
            else => std.debug.panic("{s} not supported", .{@tagName(link_obj)}),
        }
    }

    // Link system libraries recursively
    //
    // NOTE(jae): 2026-01-16
    // Link system libraries last otherwise PspSdk's psp-fixup-imports gets a warning
    // about not being able to fixup imports.
    {
        // Setup default library paths
        for (gcc_artifact.gcc.lib_paths.items) |lib_dir| {
            cmd.addPrefixedDirectoryArg("-L", lib_dir);
        }
        gcc_artifact.linkSystemLibRecursive(mod);
    }

    // Remove link objects referencing Zig built libraries to avoid compilation errors
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
    // Remove include directories referencing Zig built libraries to avoid compilation errors
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

    return gcc_artifact;
}

/// Recursively check if any libraries require C++
fn setIfLinkingCppRecursively(linking_cpp: *bool, mod: *Build.Module) void {
    for (mod.link_objects.items) |link_object| {
        switch (link_object) {
            .other_step => |other_compile| switch (other_compile.kind) {
                .lib => {
                    const other_mod = other_compile.root_module;
                    linking_cpp.* = (other_mod.link_libcpp == true);

                    // exit if true
                    if (linking_cpp.*) return;

                    setIfLinkingCppRecursively(linking_cpp, other_mod);
                },
                else => continue,
            },
            else => continue,
        }
    }
}

/// Collects all the system libraries recursively and add thems to the args
fn linkSystemLibRecursive(gcc_compile: *GccCompile, mod: *Build.Module) void {
    const b = gcc_compile.owner;
    var cwd = gcc_compile.cmd;

    // Walk dependencies backwards
    var i = mod.link_objects.items.len;
    while (i > 0) {
        i -= 1;
        switch (mod.link_objects.items[i]) {
            .other_step => |other_compile| {
                switch (other_compile.kind) {
                    .lib => {
                        gcc_compile.linkSystemLibRecursive(other_compile.root_module);
                    },
                    else => continue,
                }
            },
            else => continue,
        }
    }

    for (mod.link_objects.items) |link_object| {
        switch (link_object) {
            .system_lib => |system_lib| {
                // TODO: Does GCC support "-weak-l" and "-needed-l" ?
                // std.debug.print("debug lib name: {s}\n", .{system_lib.name});
                cwd.addArg(b.fmt("-l{s}", .{system_lib.name}));
            },
            else => continue,
        }
    }
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

fn compileCFile(gcc_artifact: *GccCompile, options: CompileCFileOptions) LazyPath {
    const b = gcc_artifact.owner;
    const gcc = gcc_artifact.gcc;
    const artifact = gcc_artifact.artifact;
    const mod = artifact.root_module;
    const is_cpp = mod.link_libcpp == true;

    const cmd = Step.Run.create(b, b.fmt("run {s} {s}", .{
        if (is_cpp) "g++" else "gcc",
        artifact.name,
    }));

    cmd.addFileArg(if (is_cpp) gcc.@"g++"() else gcc.gcc());
    cmd.addArg("-c");

    // To use the link-time optimizer, -flto and optimization options should be specified at compile time and during the final link.
    // It is recommended that you compile all the files participating in the same link with the same options and also specify those options at link time. For example:
    //   gcc -c -O2 -flto foo.c
    //   gcc -c -O2 -flto bar.c                <- This is where we are here for Zig stuff, compiling a C file
    //   gcc -o myprog -flto -O2 foo.o bar.o
    //
    // Source: https://gcc.gnu.org/onlinedocs/gcc-15.1.0/gcc/Optimize-Options.html

    // TODO(jae): 2026-01-17
    // To make LTO work correctly (globally), I need to make the linker step know which order
    // to link each dependency, so... for now LTO is only done at the top-level
    const lto = gcc_artifact.artifact.lto;
    // const lto = gcc_artifact.root_artifact.lto;
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

    if (is_cpp) {
        // NOTE(jae): 2026-01-16
        // Workaround to avoid undefined reference to `__dso_handle'
        cmd.addArg("-fno-use-cxa-atexit");
        cmd.addArg("-fno-threadsafe-statics"); // force disable __cxa_guard_acquire
    }

    const root_artifact = gcc_artifact.root_artifact;
    if (root_artifact.link_data_sections) cmd.addArg("-fdata-sections");
    if (root_artifact.link_function_sections) cmd.addArg("-ffunction-sections");
    // psp-gcc: error: unrecognized command-line option '--gc-sections'
    //   cmd.addArg("--gc-sections");
    // psp-gcc: error: unrecognized command-line option '--eh-frame-hdr'
    //   cmd.addArg("--eh-frame-hdr");

    if (artifact.root_module.root_source_file != null) {
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
        for (gcc.zig_include_directories.items) |zig_include_dir| {
            cmd.addPrefixedDirectoryArg("-I", zig_include_dir);
        }

        const zig_h_path: LazyPath = if (gcc.zig_h_path) |override_zig_h_path| override_zig_h_path else blk: {
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
    if (mod.optimize) |optimize| {
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
    for (gcc.include_directories.items) |include_dir| {
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

pub fn getEmittedBin(gcc_artifact: *GccCompile) LazyPath {
    if (gcc_artifact.emitted_bin) |emitted_bin| return emitted_bin;

    const b = gcc_artifact.owner;
    const artifact = gcc_artifact.artifact;
    const name = artifact.name;
    var cmd = gcc_artifact.cmd;

    if (!gcc_artifact.force_exe) {
        if (artifact.linkage) |linkage| {
            switch (linkage) {
                .static => {
                    cmd.addArg("-rcs");
                    // NOTE(jae): 2026-01-15
                    // Avoid clashing with native SDKs like PSP by appending *_zig
                    const emitted_bin = cmd.addOutputFileArg(b.fmt("lib{s}_zig.a", .{name}));
                    gcc_artifact.emitted_bin = emitted_bin;
                    return emitted_bin;
                },
                .dynamic => @panic("dynamic not handled"),
            }
        }
    }

    cmd.addArg("-o");
    const emitted_bin = cmd.addOutputFileArg(b.fmt("{s}.elf", .{name}));
    gcc_artifact.emitted_bin = emitted_bin;
    return emitted_bin;
}

const GccCompile = @This();
