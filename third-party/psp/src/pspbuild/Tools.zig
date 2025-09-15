const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;
const GeneratedFile = std.Build.GeneratedFile;
const DockerRun = @import("DockerRun.zig");

const log = std.log.scoped(.psp);
const name = "Playstation Portable";
const this_module_name = "psp";

b: *Build,

pub const Options = struct {};

pub fn create(b: *Build, _: Options) ?*Tools {
    const tools = b.allocator.create(Tools) catch @panic("OOM");
    tools.* = .{
        .b = b,
    };
    return tools;
}

const InternalConfig = struct {
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libc_path: LazyPath,
    dep: *Build.Dependency,
};

pub fn buildWithDocker(tools: *Tools, artifact: *Step.Compile) void {
    const b = tools.b;
    const target = artifact.root_module.resolved_target.?;
    const optimize = artifact.root_module.optimize.?;
    const dep = tools.b.lazyDependency(this_module_name, .{
        .target = target,
        .optimize = optimize,
    }) orelse @panic(tools.b.fmt("must call {s} module '{s}' in your root module", .{ name, this_module_name }));

    const pspdev_path: LazyPath = dep.path("upstream/pspdev");
    const libc_path = tools.createLibCFile(pspdev_path);
    const config: InternalConfig = .{
        .b = tools.b,
        .target = target,
        .optimize = optimize,
        .libc_path = libc_path,
        .dep = dep,
    };

    artifact.root_module.link_libc = true;

    // Iterate over dependencies
    updateCompileAll(config, artifact);
    updateTranslateC(b, pspdev_path, artifact);

    // const cwd_realpath = std.fs.cwd().realpathAlloc(b.allocator, "") catch @panic("OOM");

    const docker_cmd = DockerRun.create(b);
    docker_cmd.addArtifactArg(artifact);
    // psp-gcc -g ./zig-out/lib/libdesk-breaker.a -L/usr/local/pspdev/psp/sdk/lib -lGL -lpspvram -lpspaudio -lpspvfpu -lpspdisplay -lpspgu -lpspge -lpsphprm
    //          -lpspctrl -lpsppower -lSDL3 -o ./zig-out/psp.executable

    b.getInstallStep().dependOn(&docker_cmd.cmd.step);
}

pub fn addStandardLibrary(tools: *Tools, artifact: *Step.Compile) void {
    const b = tools.b;
    const target = artifact.root_module.resolved_target.?;
    const optimize = artifact.root_module.optimize.?;
    const dep = tools.b.lazyDependency(this_module_name, .{
        .target = target,
        .optimize = optimize,
    }) orelse @panic(tools.b.fmt("must call {s} module '{s}' in your root module", .{ name, this_module_name }));
    const pspdev_path: LazyPath = dep.path("upstream/pspdev");
    const libc_path = tools.createLibCFile(pspdev_path);
    const config: InternalConfig = .{
        .b = tools.b,
        .target = target,
        .optimize = optimize,
        .libc_path = libc_path,
        .dep = dep,
    };

    // const pspdev_raw_path = pspdev_path.path(b, "psp").getPath3(b, null).toString(b.allocator) catch @panic("OOM");
    // if (b.sysroot == null) {
    //     // if (true) @panic(pspdev_raw_path);
    //     b.sysroot = pspdev_raw_path;
    // }

    // Add dependencies from this
    if (false) {
        // var feature_set: std.Target.Cpu.Feature.Set = std.Target.Cpu.Feature.Set.empty;
        // feature_set.addFeature(@intFromEnum(std.Target.mips.Feature.single_float));
        // const query: std.Target.Query = .{
        //     .cpu_arch = .mipsel,
        //     .os_tag = .freestanding,
        //     .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips2 },
        //     .cpu_features_add = feature_set,
        // };
        // const core_target = b.resolveTargetQuery(query);

        // Setup PSP runtime functions like 'scePower', etc
        const libzpsp_dep = config.dep.builder.lazyDependency("libzpsp", .{
            .target = target,
            .optimize = .ReleaseFast,
        }) orelse return;

        const libzpsp_options = b.addOptions();
        libzpsp_options.addOption(bool, "everything", true);
        const libzpsp_lib = libzpsp_dep.artifact("libzpsp");
        libzpsp_lib.root_module.addImport("libzpsp_option", libzpsp_options.createModule());

        artifact.root_module.linkLibrary(libzpsp_lib);
    }

    // Get sysroot includes for C/C++ libraries
    // const sysroot_include_paths = [_]LazyPath{
    //     tools.gcc_path.path(b, "libstdc++-v3/include/std"),
    //     tools.gcc_path.path(b, "libstdc++-v3/include/c_std"),
    //     tools.gcc_path.path(b, "libstdc++-v3/include/c_compatibility"),
    // };

    if (false) {
        const psp_dep = config.dep;
        artifact.linkLibrary(psp_dep.artifact("pspgu"));
        artifact.linkLibrary(psp_dep.artifact("pspvram"));
        artifact.linkLibrary(psp_dep.artifact("GL"));
    }

    {
        artifact.root_module.link_libc = true;

        // Iterate over dependencies
        updateCompileAll(config, artifact);

        updateTranslateC(b, pspdev_path, artifact);
    }
}

fn updateTranslateC(b: *Build, pspdev_path: LazyPath, artifact: *Build.Step.Compile) void {
    const pspdev_include_paths = [_]LazyPath{
        pspdev_path.path(b, "include"), // alpm.h, alpm_list.h, gdb/jit-reader.h
        pspdev_path.path(b, "psp/include"), // Standard C library and others libs: sys/time.h, GL/*.h, SDL3/*.h
    };

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
                for (pspdev_include_paths) |include_path| {
                    translate_c.addSystemIncludePath(include_path);
                }
            },
            else => continue,
        }
    }
}

fn updateCompileAll(config: InternalConfig, root_artifact: *Step.Compile) void {
    updateCompile(config, root_artifact);

    for (root_artifact.root_module.link_objects.items) |link_object| {
        switch (link_object) {
            .other_step => |artifact| {
                switch (artifact.kind) {
                    .lib => {
                        updateCompileAll(config, artifact);
                    },
                    else => continue,
                }
            },
            else => continue,
        }
    }
}

fn updateCompile(config: InternalConfig, artifact: *Step.Compile) void {
    const b = config.b;
    const psp_dep = config.dep;
    const target = config.target;

    // setup defaults
    artifact.setLibCFile(config.libc_path);
    const linkfile_path = psp_dep.path("src/linkfile.ld");
    artifact.setLinkerScript(linkfile_path);
    // artifact.setVersionScript(psp_dep.path("src/versionscript.map"));
    artifact.root_module.strip = false; // Cannot disable if "link_emit_relocs = true"
    artifact.link_eh_frame_hdr = true;
    artifact.link_emit_relocs = true;
    // artifact.link_function_sections = true; // GC unused functions, prevent link issues with C++ functions missing
    // artifact.link_gc_sections = true;
    // artifact.want_lto = true;

    if (artifact.root_module.link_libc == true) {
        // artifact.root_module.link_libc = null;
        // artifact.root_module.linkSystemLibrary("c_hack", .{
        //     .weak = true,
        //     .needed = true,
        //     .search_strategy = .mode_first,
        //     .preferred_link_mode = .static,
        // });
    }

    // artifact.root_module.addCMacro("_LIBCPP_HAS_THREAD_API_PTHREAD", "1");
    // artifact.root_module.addCMacro("_LIBCPP_ABI_VERSION", "1");
    // artifact.root_module.addCMacro("_LIBCPP_ABI_NAMESPACE", "__1");
    // artifact.root_module.addCMacro("_LIBCPP_HARDENING_MODE", "_LIBCPP_HARDENING_MODE_NONE");

    const pspdev_path: LazyPath = psp_dep.path("upstream/pspdev");
    if (target.result.os.tag == .freestanding) {
        // If no C ABI / freestanding, avoiding linking C++ runtime
        if (artifact.root_module.link_libcpp == true) {
            if (artifact.root_module.link_libc == null) {
                artifact.root_module.link_libc = true;
            }
            artifact.root_module.link_libcpp = null;

            // artifact.linker_allow_undefined_version = false;
            // artifact.root_module.addCMacro("_LIBCPP_ABI_VERSION", "1");
            // artifact.root_module.addCMacro("_LIBCPP_ABI_NAMESPACE", "__1");
            // artifact.root_module.linkSystemLibrary("stdc++_hack", .{
            //     .needed = true,
            //     .weak = true,
            // });
        }
    }

    // Get include paths for PSPSDK libraries like "pspaudio", "pspthreadman", etc
    const pspdev_include_paths = [_]LazyPath{
        pspdev_path.path(b, "include"), // alpm.h, alpm_list.h, gdb/jit-reader.h
        pspdev_path.path(b, "psp/include"), // Standard C library and others libs: sys/time.h, GL/*.h, SDL3/*.h
        pspdev_path.path(b, "psp/sdk/include"), // PSP SDK: pspaudio.h, sys/socket.h

        // PSPGL
        // tools.pspgl_path, // GLES/*, GL/* folders

        // libpspvram
        // config.pspvram_path,
    };
    for (pspdev_include_paths) |include_path| {
        artifact.root_module.addSystemIncludePath(include_path);
    }

    // Add prebuilt system libraries
    const library_paths = [_]LazyPath{
        pspdev_path.path(b, "psp/sdk/lib"),
        pspdev_path.path(b, "psp/lib"),
    };
    for (library_paths) |library_path| {
        artifact.root_module.addLibraryPath(library_path);
    }
    // artifact.linkSystemLibrary("c");
    // artifact.linkSystemLibrary("cglue");

    // const link_libc = artifact.root_module.link_libc orelse false;
    // const link_libcpp = artifact.root_module.link_libcpp orelse false;
    // if (artifact.root_module.link_libc == true or artifact.root_module.link_libcpp == true) {
    //     // Add standard PSP SDK libraries
    //     artifact.linkLibrary(psp_dep.artifact("pspgu"));
    //     artifact.linkLibrary(psp_dep.artifact("pspvram"));
    //     artifact.linkLibrary(psp_dep.artifact("GL"));
    // }
}

pub fn createLibCFile(tools: *Tools, pspdev_path: LazyPath) LazyPath {
    const b = tools.b;

    const libc_file_format =
        \\# Generated by psp. DO NOT EDIT.
        \\
        \\# The directory that contains `stdlib.h`.
        \\# On POSIX-like systems, include directories be found with: `cc -E -Wp,-v -xc /dev/null`
        \\include_dir={[include_dir]s}
        \\
        \\# The system-specific include directory. May be the same as `include_dir`.
        \\# On Windows it's the directory that includes `vcruntime.h`.
        \\# On POSIX it's the directory that includes `sys/errno.h`.
        \\sys_include_dir={[sys_include_dir]s}
        \\
        \\# The directory that contains `crt1.o`.
        \\# On POSIX, can be found with `cc -print-file-name=crt1.o`.
        \\# Not needed when targeting MacOS.
        \\crt_dir={[crt_dir]s}
        \\
        \\# The directory that contains `vcruntime.lib`.
        \\# Only needed when targeting MSVC on Windows.
        \\msvc_lib_dir=
        \\
        \\# The directory that contains `kernel32.lib`.
        \\# Only needed when targeting MSVC on Windows.
        \\kernel32_lib_dir=
        \\
        \\gcc_dir=
    ;

    const psp_path = pspdev_path.path(b, "psp").getPath(b);

    const include_dir = b.fmt("{s}/include", .{psp_path}); // ie. pspdev/psp/include
    const sys_include_dir = b.fmt("{s}/sdk/include", .{psp_path}); // ie. pspdev/psp/sdk/include
    const crt_dir = b.fmt("{s}/lib", .{psp_path}); // ie. pspdev/lib

    const libc_file_contents = b.fmt(libc_file_format, .{
        .include_dir = include_dir,
        .sys_include_dir = sys_include_dir,
        .crt_dir = crt_dir,
    });

    const filename = b.fmt("psp-libc.conf", .{});

    const write_file = b.addWriteFiles();
    const libc_path = write_file.add(filename, libc_file_contents);
    return libc_path;
}

/// List of PSP SDK folders, used to include all modules for C
/// Source: https://github.com/pspdev/pspsdk
pub const pspsdk_include_paths = [_][]const u8{
    "atrac3", // pspatrac3.h
    "audio", // pspaudio.h
    "base", // psptypes.h
    "ctrl", // pspctrl.h
    "debug", // pspdebug.h
    "display", // pspdisplay.h
    "dmac", // pspdmac.h
    "fpu", // pspfpu.h
    "ge", // pspge.h
    "gu", // pspgu.h
    "gum", // pspgum.h
    "hprm", // psphprm.h
    "kernel", // pspkernel.h
    // ...
    "power", // psppower.h
    // ...
    "user", // pspkerneltypes.h
    "utility", // psputility.h
    "vaudio", // pspvaudio.h
    "vfpu", // pspvfpu.h
    "video", // pspvideo.h
    "vsh", // pspchnnlsv.h
    "wlan", // pspwlan.h
};

const Tools = @This();
