//! DEPRECATED. I'm just using this as a reference in the future for when I look at
//! making it work with the GCC tools.
//!
//!  DockerRun will run PSPSDK commands through Docker
//! - docker run -ti -v $PWD:/source pspdev/pspdev:latest

const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = Build.Step;
const Options = Build.Step.Options;
const LazyPath = Build.LazyPath;
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;

pub const base_id: Step.Id = .custom;

step: Step,

cmd: *Build.Step.Run,
main_artifact: ?*std.Build.Step.Compile,

pub fn create(owner: *std.Build) *DockerRun {
    const cmd = owner.addSystemCommand(&.{ "docker", "run" });
    cmd.addArg("-t");
    cmd.addArg("--rm"); // Automatically remove the container when it exits
    cmd.addArg("-a");
    cmd.addArg("STDOUT");
    cmd.addArg("--name");
    cmd.addArg("zig-psp");

    const docker_cmd = owner.allocator.create(DockerRun) catch @panic("OOM");
    docker_cmd.* = .{
        .step = Step.init(.{
            .id = base_id,
            .name = "docker run",
            .owner = owner,
            .makeFn = make,
        }),
        .cmd = cmd,
        .main_artifact = null,
    };
    // Run step relies on this finishing
    cmd.step.dependOn(&docker_cmd.step);
    return docker_cmd;
}

fn make(step: *Step, _: Build.Step.MakeOptions) !void {
    const b = step.owner;
    const docker_cmd: *DockerRun = @fieldParentPtr("step", step);
    const cmd = docker_cmd.cmd;

    const cwd_realpath = std.fs.cwd().realpathAlloc(b.allocator, "") catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.FileNotFound => return error.FileNotFound,
        else => std.debug.panic("realpathAlloc failed: {}", .{err}),
    };
    std.mem.replaceScalar(u8, cwd_realpath, '\\', '/');

    // Mount Zig project within Docker container at /source
    cmd.addArg("-v");
    cmd.addArg(b.fmt("{s}:/source", .{cwd_realpath}));

    cmd.addArg("pspdev/pspdev:latest");

    cmd.addArg("psp-gcc");
    if (docker_cmd.main_artifact) |artifact| {
        try docker_cmd.linkArtifactAll(artifact);
    }
    cmd.addArg("-L/usr/local/pspdev/psp/sdk/lib");

    // pspdev/psp/lib/pkgconfig/freetype2.pc
    cmd.addArg("-lfreetype"); // TODO: auto detect
    cmd.addArg("-lpng"); // Part of freetype
    cmd.addArg("-lz"); // Part of freetype
    cmd.addArg("-lbz2"); // Part of freetype

    // -lSDL2main -lSDL2  -lm -lGL -lpspvram -lpspaudio -lpspvfpu -lpspdisplay -lpspgu -lpspge -lpsphprm -lpspctrl -lpsppower"
    // cmd.addArg("-lSDL3main");
    cmd.addArg("-lSDL3");
    cmd.addArg("-lm");
    cmd.addArg("-lGL");
    cmd.addArg("-lpspvram");
    cmd.addArg("-lpspaudio");
    cmd.addArg("-lpspvfpu");
    cmd.addArg("-lpspdisplay");
    cmd.addArg("-lpspgu");
    cmd.addArg("-lpspge");
    cmd.addArg("-lpsphprm");
    cmd.addArg("-lpspctrl");
    cmd.addArg("-lpsppower");

    cmd.addArg("-lpspdebug");

    cmd.addArg("-lc"); // TODO: detect
    cmd.addArg("-lcglue"); // TODO: detect (for _exit)
    cmd.addArg("-lstdc++"); // TODO: auto detect

    // -Wl,-q,-T$(PSPSDK)/lib/linkfile.prx -nostartfiles -Wl,-zmax-page-size=128
    const pspsdk = "/usr/local/pspdev/psp/sdk";
    cmd.addArg(b.fmt("-Wl,-q,-T{s}/lib/linkfile.prx", .{pspsdk}));
    cmd.addArg("-nostartfiles");
    cmd.addArg("-Wl,-zmax-page-size=128");

    // TODO: Use this instead: https://github.com/zPSP-Dev/Zig-PSP/blob/master/src/psp/utils/module.zig
    // cmd.addArg(b.fmt("{s}/lib/prxexports.o", .{pspsdk}));

    cmd.addArg("-o");
    cmd.addArg("/source/zig-out/bin/psp.o");
}

pub fn addArtifactArg(run: *DockerRun, artifact: *std.Build.Step.Compile) void {
    run.main_artifact = artifact;
    const bin_file = artifact.getEmittedBin();
    bin_file.addStepDependencies(&run.step);
}

fn linkArtifact(run: *DockerRun, artifact: *Step.Compile) !void {
    const b = run.step.owner;

    // Change current path to Unix format for Docker
    const cwd_realpath = std.fs.cwd().realpathAlloc(b.allocator, "") catch @panic("OOM");
    std.mem.replaceScalar(u8, cwd_realpath, '\\', '/');

    // Transform path to work in Docker
    //
    // From: {zigroot}/.zig-cache/o/21270a84c6ce0ca1c0cd29668bad0d60/libdesk-breaker.a
    // To:   /source/.zig-cache/o/21270a84c6ce0ca1c0cd29668bad0d60/libdesk-breaker.a
    const artifact_lazy_path = artifact.getEmittedBin();
    const artifact_path = artifact_lazy_path.generated.file.getPath();
    const relative_docker_path = try std.fs.path.relative(b.allocator, cwd_realpath, artifact_path);
    const path_os = b.pathJoin(&.{ "/", "source", relative_docker_path }); // std.mem.join(b.allocator, "/", &.{ "source", relative_docker_path }) catch @panic("OOM");
    std.mem.replaceScalar(u8, path_os, '\\', '/');

    const lib_dirname = std.fs.path.dirnamePosix(path_os) orelse @panic("invalid path");
    const lib_basename = std.fs.path.basename(path_os)[0..];

    run.cmd.addArg(b.fmt("-L{s}", .{lib_dirname}));
    run.cmd.addArg(b.fmt("-l:{s}", .{lib_basename}));
}

fn linkArtifactAll(run: *DockerRun, root_artifact: *Step.Compile) !void {
    try run.linkArtifact(root_artifact);

    for (root_artifact.root_module.link_objects.items) |link_object| {
        switch (link_object) {
            .other_step => |artifact| {
                switch (artifact.kind) {
                    .lib => {
                        try run.linkArtifactAll(artifact);
                    },
                    else => continue,
                }
            },
            else => continue,
        }
    }
}

const DockerRun = @This();
