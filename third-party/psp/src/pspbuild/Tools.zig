const std = @import("std");
const builtin = @import("builtin");
const Gcc = @import("Gcc.zig");
const GccCompile = @import("GccCompile.zig");

const Build = std.Build;
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;
const GeneratedFile = std.Build.GeneratedFile;

const log = std.log.scoped(.psp);
const name = "Playstation Portable";
const this_module_name = "psp";

b: *Build,
dep: *std.Build.Dependency,
dep_path: LazyPath,
/// pspdev_path is the path to the pspdev sdk that contains /bin, /lib, /include, /psp/include, /psp/lib
pspdev_path: LazyPath,
// libc_path: LazyPath, // No longer used

pub const Options = struct {};

pub fn create(b: *Build, _: Options) ?*Tools {
    const dep = b.lazyDependency(this_module_name, .{}) orelse
        @panic(b.fmt("must call {s} module '{s}' in your root module", .{ name, this_module_name }));
    const pspdev_dep = dep.builder.lazyDependency("pspdev", .{}) orelse {
        b.getInstallStep().dependOn(&b.addFail("missing pspdev dependency").step);
        return null;
    };
    const pspdev_path = pspdev_dep.path("");
    const tools = b.allocator.create(Tools) catch @panic("OOM");
    tools.* = .{
        .b = b,
        .dep = dep,
        .dep_path = dep.path(""),
        .pspdev_path = pspdev_path,
        // .libc_path = createLibCFile(b, pspdev_path),
    };
    return tools;
}

pub fn buildWithNativeSdk(tools: *Tools, artifact: *Step.Compile) void {
    const b = tools.b;
    const pspdev_path = tools.pspdev_path;
    const psp_elf: std.Build.LazyPath = pspcompileblk: {
        // Update artifact with settings
        {
            // Update artifact with settings
            // artifact.setLibCFile(tools.libc_path);

            // NOTE(jae): 2026-01-17
            // Update translate-c modules 'target' to use x86_64 windows to avoid
            // compilation issues. (Use Zig provided headers instead of PSP SDK GCC headers)
            fixTranslateC(b, artifact);

            artifact.link_function_sections = true;
            artifact.link_data_sections = true;
            // artifact.link_gc_sections = true;

            // NOTE(jae): 2026-01-17
            // Tried this to avoid memrel issues with wuffs (PNG loader) but using lto
            // ended up causing crashes on my real PSP device but not the emulator
            // artifact.lto = .full;
        }

        // Add compiler_rt to main artifact
        //
        // NOTE(jae): 2026-01-18
        // Fix undefined reference to '__multi3', '__udivti3', '__divti3', etc
        {
            // artifact.bundle_compiler_rt = true;
            const zig_exe_dir = std.fs.path.dirname(b.graph.zig_exe) orelse @panic("unable to get zig path to find zig.h");
            const zig_lib_h_dir: LazyPath = .{
                .cwd_relative = zig_exe_dir,
            };
            const compiler_rt_mod = b.createModule(.{
                .root_source_file = zig_lib_h_dir.path(b, "lib/compiler_rt.zig"),
                .target = artifact.root_module.resolved_target,
                .optimize = artifact.root_module.optimize,
            });
            artifact.root_module.addImport("compiler_rt", compiler_rt_mod);
        }

        const gcc = Gcc.create(b, pspdev_path.path(b, "bin"), .{
            .prefix = "psp-", // ie. psp-gcc, psp-ar
        });

        // NOTE(jae): 2026-01-16
        // For PSP we override the default zig.h and wrap it with this hack
        gcc.SetZigInclude(tools.dep.path("src/zig-c/zig.h"));
        gcc.addZigIncludeDirectory(.{
            .cwd_relative = std.fs.path.dirname(b.graph.zig_exe) orelse @panic("unable to get zig path to find lib/zig.h"),
        });

        // gcc.addIncludeDirectory(.{
        //     .cwd_relative = std.fs.path.dirname(b.graph.zig_exe) orelse @panic("unable to get zig path to find lib/zig.h"),
        // });
        // gcc.addIncludeDirectory(pspdev_path.path(b, "include")); // alpm.h, alpm_list.h, gdb/jit-reader.h
        // gcc.addIncludeDirectory(pspdev_path.path(b, "psp/include")); // Standard C library and others libs: sys/time.h, GL/*.h, SDL3/*.h
        gcc.addIncludeDirectory(pspdev_path.path(b, "psp/sdk/include")); // pspkerneltypes.h
        gcc.addLibraryPath(pspdev_path.path(b, "psp/sdk/lib")); // libpspkernel, libpspmp3, etc
        gcc.addLibraryPath(pspdev_path.path(b, "psp/lib")); // libc, libz, libpthread
        const gcc_artifact = GccCompile.create(b, artifact, .{
            .gcc = gcc,
            .force_exe = true,
            .root_artifact = null,
        });
        const cmd = gcc_artifact.cmd;

        // NOTE(jae): 2026-01-17
        // Don't use pspsdk/src/startup/crt0_prx.c for module_start behaviour
        // Using this instead: https://github.com/zPSP-Dev/Zig-PSP/blob/master/src/psp/utils/module.zig
        cmd.addArg("-nostartfiles");

        // -specs=$(PSPSDK)/lib/prxspecs
        //
        // ie.
        // *startfile:
        // crt0_prx%O%s crti%O%s crtbegin%O%s
        cmd.addPrefixedFileArg("-specs=", pspdev_path.path(b, "psp/sdk/lib/prxspecs"));
        // -Wl,-q,-T$(PSPSDK)/lib/linkfile.prx -nostartfiles -Wl,-zmax-page-size=128
        cmd.addPrefixedFileArg("-Wl,-q,-T", pspdev_path.path(b, "psp/sdk/lib/linkfile.prx"));

        // NOTE(jae): 2026-01-16
        // We setup __syslib_exports and __library_exports with this instead:
        // - https://github.com/zPSP-Dev/Zig-PSP/blob/master/src/psp/utils/module.zig
        //
        // Original prxexports.c code is here:
        // - https://github.com/pspdev/pspsdk/blob/f8f252343c1fe37c753596d481b6872799e2f109/src/startup/prxexports.c
        // cmd.addFileArg(pspdev_path.path(b, "psp/sdk/lib/prxexports.o"));

        break :pspcompileblk gcc_artifact.getEmittedBin();
    };

    // Fixup Imports
    const psp_fixup_imports = pspdev_path.path(b, "bin/psp-fixup-imports").getPath(b);
    const fixup_imports_cmd = b.addSystemCommand(&.{psp_fixup_imports});
    fixup_imports_cmd.addFileArg(psp_elf);
    fixup_imports_cmd.addArg("-o");
    const psp_outfile = fixup_imports_cmd.addOutputFileArg("psp-fixed.elf");
    // const psp_outfile = psp_elf;

    // PRX from ELF
    const psp_prxgen_path = pspdev_path.path(b, "bin/psp-prxgen").getPath(b);
    const mk_prx = b.addSystemCommand(&.{psp_prxgen_path});
    mk_prx.addFileArg(psp_outfile);
    const prx_file = mk_prx.addOutputFileArg("app.prx");

    // SFO file for PBP
    const mk_sfo = b.addSystemCommand(&.{pspdev_path.path(b, "bin/mksfo").getPath(b)});
    mk_sfo.addArg(artifact.name);
    const sfo_file = mk_sfo.addOutputFileArg("PARAM.SFO");

    // Pack PBP
    const pack_pbp_path = pspdev_path.path(b, "bin/pack-pbp").getPath(b);
    const pack_pbp = b.addSystemCommand(&.{pack_pbp_path});
    const eboot_file = pack_pbp.addOutputFileArg(b.fmt("{s}.pbp", .{artifact.name}));
    pack_pbp.addFileArg(sfo_file);
    pack_pbp.addArg("NULL"); // icon0
    pack_pbp.addArg("NULL"); // icon1
    pack_pbp.addArg("NULL"); // pic0
    pack_pbp.addArg("NULL"); // pic1
    pack_pbp.addArg("NULL"); // snd0
    pack_pbp.addFileArg(prx_file);
    pack_pbp.addArg("NULL"); // data.psar

    // psp_elf.addStepDependencies(b.getInstallStep());
    b.getInstallStep().dependOn(&b.addInstallArtifact(artifact, .{}).step); // Install app.c file
    b.getInstallStep().dependOn(&b.addInstallBinFile(eboot_file, "EBOOT.pbp").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(prx_file, "psp.prx").step);
}

fn fixTranslateC(b: *Build, artifact: *Build.Step.Compile) void {
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
                const target = translate_c.target;
                if (target.result.os.tag == .freestanding) {
                    // NOTE(jae): 2026-01-16
                    // Playstation Portable stdint.h is incorrect here and buggy when used with Zig, so just fallback to Windows
                    // as the target but use the correct bit width and hope the ABI is similar enough to not crash things.
                    translate_c.target = b.resolveTargetQuery(.{
                        .os_tag = .windows,
                        .cpu_arch = if (target.result.ptrBitWidth() == 64) .x86_64 else .x86,
                    });
                }
                // NOTE(jae): 2026-01-17
                // Previous attempt was to just update include paths of translate-c to use PSP SDK files
                //
                // const pspdev_include_paths = [_]LazyPath{
                //     pspdev_path.path(b, "include"), // alpm.h, alpm_list.h, gdb/jit-reader.h
                //     pspdev_path.path(b, "psp/include"), // Standard C library and others libs: sys/time.h, GL/*.h, SDL3/*.h
                // };
                // for (pspdev_include_paths) |include_path| {
                //     translate_c.addSystemIncludePath(include_path);
                // }
            },
            else => continue,
        }
    }
}

pub fn deprecated_buildWithDockerSdk(tools: *Tools, artifact: *Step.Compile) void {
    const b = tools.b;
    const pspdev_path = tools.pspdev_path;
    artifact.root_module.link_libc = true;

    // Iterate over dependencies
    deprecatedUnused_updateCompileAll(tools, artifact);
    fixTranslateC(b, pspdev_path, artifact);

    // const cwd_realpath = std.fs.cwd().realpathAlloc(b.allocator, "") catch @panic("OOM");

    const docker_cmd = @import("Deprecated_DockerRun.zig").create(b);
    docker_cmd.addArtifactArg(artifact);
    // psp-gcc -g ./zig-out/lib/libdesk-breaker.a -L/usr/local/pspdev/psp/sdk/lib -lGL -lpspvram -lpspaudio -lpspvfpu -lpspdisplay -lpspgu -lpspge -lpsphprm
    //          -lpspctrl -lpsppower -lSDL3 -o ./zig-out/psp.executable

    b.getInstallStep().dependOn(&docker_cmd.cmd.step);
}

fn deprecatedUnused_updateCompileAll(tools: *Tools, root_artifact: *Step.Compile) void {
    tools.deprecatedUnused_updateCompile(root_artifact);

    for (root_artifact.root_module.link_objects.items) |link_object| {
        switch (link_object) {
            .other_step => |artifact| {
                switch (artifact.kind) {
                    .lib => {
                        tools.deprecatedUnused_updateCompileAll(artifact);
                    },
                    else => continue,
                }
            },
            else => continue,
        }
    }
}

fn deprecatedUnused_updateCompile(tools: *Tools, artifact: *Step.Compile) void {
    const b = tools.b;

    // setup defaults
    artifact.setLibCFile(tools.libc_path);
    const linkfile_path = tools.dep_path.path(b, "src/linkfile.ld");
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

    const pspdev_path = tools.pspdev_path;
    const target = artifact.root_module.resolved_target.?;
    if (target.result.os.tag == .freestanding) {
        // If no C ABI / freestanding, avoiding linking C++ runtime
        // if (artifact.root_module.link_libcpp == true) {
        //     if (artifact.root_module.link_libc == null) {
        //         artifact.root_module.link_libc = true;
        //     }
        //     artifact.root_module.link_libcpp = null;

        //     // artifact.linker_allow_undefined_version = false;
        //     // artifact.root_module.addCMacro("_LIBCPP_ABI_VERSION", "1");
        //     // artifact.root_module.addCMacro("_LIBCPP_ABI_NAMESPACE", "__1");
        //     // artifact.root_module.linkSystemLibrary("stdc++_hack", .{
        //     //     .needed = true,
        //     //     .weak = true,
        //     // });
        // }
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

pub fn createLibCFile(b: *std.Build, pspdev_path: LazyPath) LazyPath {
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
