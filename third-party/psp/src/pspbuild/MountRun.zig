//! MountRun wraps various 'Run' commands so they can 'just work' in Docker

const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = Build.Step;
const Run = Build.Step.Run;
const Compile = Build.Step.Compile;
const LazyPath = Build.LazyPath;
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;

const Gcc = @import("Gcc.zig");

gcc: *Gcc,
cmd: *Run,
mode: Mode,
docker: Docker,

pub fn create(gcc: *Gcc) *MountRun {
    const b = gcc.b;

    const cmd = Step.Run.create(b, b.fmt("run gcc", .{}));
    // const cmd = Step.Run.create(b, b.fmt("run gcc {s}", .{
    //     if (is_cpp) "g++" else "gcc",
    //     artifact.name,
    // }));
    const gcc_run = b.allocator.create(MountRun) catch @panic("OOM");
    gcc_run.* = .{
        .gcc = gcc,
        .cmd = cmd,
        .mode = .normal,
        .docker = .{
            .image = &[0]u8{},
            .prefix_setup = false,
            .postfix_setup = false,
        },
    };
}

/// For example: "pspdev/pspdev:latest"
pub fn setDockerImage(run: *MountRun, name: []const u8) void {
    if (run.cmd.argv.items.len != 0) @panic("must call setDockerImage before you call other functions");
    run.docker.image = name;
}

/// mountCwd will mount the current working directory at given path for Docker
pub fn mountCwd(run: *MountRun, path: []const u8) void {
    if (path.len == 0) @panic("path must not be empty");
    if (path[0] != '/') @panic("path must begin with /");

    const cmd = run.cmd;
    const b = cmd.step.owner;

    // Get current working directory for Docker
    const cwd = std.fs.cwd().realpathAlloc(b.allocator, "") catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.FileNotFound => return error.FileNotFound,
        else => std.debug.panic("realpathAlloc failed: {}", .{err}),
    };
    std.mem.replaceScalar(u8, cwd, '\\', '/');

    // Setup docker arguments
    run.docketSetupBeforeAny();

    // Add directory to mount
    // ie. "/home/USER/zig/my-project:/source"
    cmd.addArg(b.fmt("{s}:{s}", .{ run.cwd, path }));
}

fn addFileArg(run: *MountRun, path: LazyPath) void {
    const cmd = run.cmd;
    switch (run.mode) {
        .default => cmd.addFileArg(path),
        .docker => {
            run.dockerSetupPostMount();
            cmd.addArg(run.rewritePath(path));
            cmd.addFileInput(path);
        },
    }
}

fn docketSetupBeforeAny(run: *MountRun) void {
    if (run.docker.prefix_setup) return;

    const cmd = run.cmd;
    if (cmd.argv.items.len != 0) @panic("must call mount* functions before you call other functions");

    cmd.addArg("-t");
    cmd.addArg("--rm"); // Automatically remove the container when it exits
    cmd.addArg("-a");
    cmd.addArg("STDOUT");
    cmd.addArg("--name");
    cmd.addArg("docker-gcc"); // TODO: Make docker name configurable
    cmd.addArg("-v");

    run.docker.prefix_setup = true;
    run.mode = .docker;
}

fn dockerSetupPostMount(run: *MountRun) void {
    if (run.docker.postfix_setup) return;
    if (run.docker.image.len == 0) @panic("must call setDockerImage");

    run.cmd.addArg(run.docker.image);
    run.docker.postfix_setup = true;
}

fn rewritePath(run: *MountRun, path: LazyPath) []const u8 {
    _ = run;
    switch (path) {
        // TODO: Support cwd_relative somewhat by mapping host Zig folder
        // this resolves zig.h access issues
        .cwd_relative => @panic("TODO: cwd relative"),
        // TODO: Map users .zig folder to get external dependencies
        .dependency => @panic("TODO: dependency"),
        // TODO: Map current Zig project directory to Docker
        .src_path => @panic("TODO: src path"),
        // TODO: Map current Zig project directory to Docker
        .generated => @panic("TODO: generated"),
    }
}

const Docker = struct {
    image: []const u8,
    prefix_setup: bool,
    postfix_setup: bool,
};

const Mode = enum {
    default,
    docker,
};

const MountRun = @This();
