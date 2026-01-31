//! MountRun wraps various 'Run' commands so they can 'just work' in Docker

const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = Build.Step;
const Run = Build.Step.Run;
const Compile = Build.Step.Compile;
const LazyPath = Build.LazyPath;
const ArrayList = std.ArrayList;
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;

cmd: *Run,
step: Step,
mode: Mode,
docker: Docker,

pub const DockerMountDirectory = struct {
    local_directory: LazyPath,
    docker_directory: []const u8,
};

pub const DockerOptions = struct {
    mount_directories: []const DockerMountDirectory,
};

pub fn createFromPath(b: *Build, command_lp: LazyPath, context: []const u8) *MountRun {
    const command_name: []const u8 = std.fs.path.basename(switch (command_lp) {
        .cwd_relative => |relative_path| relative_path,
        .src_path => |path| path.sub_path,
        .dependency => |path| path.sub_path,
        else => command_lp.getDisplayName(),
    });

    const run = create(b, b.fmt("{s} {s}", .{ command_name, context }));
    const cmd = run.cmd;
    cmd.step.dependOn(&run.step);

    cmd.addFileArg(command_lp);
    return run;
}

pub fn createFromDockerImage(b: *Build, command: []const u8, docker_image: []const u8, options: DockerOptions) *MountRun {
    if (true) @compileError("Not currently implemented. Issues with generated files");

    var run = create(b, b.fmt("docker {s}", .{command}));
    run.mode = .docker;
    run.docker = .{
        .image = docker_image,
        .prefix_setup = false,
        .postfix_setup = false,
        .rewrite_argv = .empty,
        .mounted_directories = blk: {
            const mounted_directories = b.allocator.dupe(DockerMountDirectory, options.mount_directories) catch @panic("OOM");
            for (mounted_directories) |*mounted_directory| {
                mounted_directory.* = .{
                    .local_directory = mounted_directory.local_directory.dupe(b),
                    .docker_directory = b.dupe(mounted_directory.docker_directory),
                };
            }
            break :blk mounted_directories;
        },
    };

    const cmd = run.cmd;

    // Setup Docker
    cmd.addArgs(&.{ "docker", "run" });
    cmd.addArg("-t");
    // cmd.addArg("--rm"); // Automatically remove the container when it exits
    cmd.addArg("-a");
    cmd.addArg("STDOUT");
    // cmd.addArg("--name");
    // cmd.addArg("mount-run-docker"); // TODO: Use run.docker.image without : or /

    // Mount Volumes
    {
        for (options.mount_directories) |mount_directory| {
            // Add directory to mount
            // ie. "/home/USER/zig/my-project:/source"
            cmd.addArg("-v"); // Volume mounting
            cmd.addDecoratedDirectoryArg(
                "",
                mount_directory.local_directory.dupe(b),
                b.fmt(":{s}", .{mount_directory.docker_directory}),
            );
        }
    }

    // Set Docker image (ie pspdev/pspdev:latest)
    cmd.addArg(docker_image);

    // Run command (gcc, psp-gcc, etc)
    cmd.addArg(command);

    return run;
}

fn create(b: *std.Build, cmd_step_name: []const u8) *MountRun {
    const run = b.allocator.create(MountRun) catch @panic("OOM");
    run.* = .{
        .cmd = Step.Run.create(b, b.fmt("run {s}", .{cmd_step_name})),
        .step = .init(.{
            .id = .custom,
            .name = b.fmt("mount-run {s}", .{cmd_step_name}),
            .owner = b,
            .makeFn = make,
        }),
        .mode = .default,
        .docker = .{
            .image = &[0]u8{},
            .prefix_setup = false,
            .postfix_setup = false,
            .rewrite_argv = .empty,
            .mounted_directories = &[0]DockerMountDirectory{},
        },
    };
    run.cmd.step.dependOn(&run.step); // Make Step.Run rely on MountRuns step
    return run;
}

pub fn addArg(run: *MountRun, arg: []const u8) void {
    const cmd = run.cmd;
    switch (run.mode) {
        .default => cmd.addArg(arg),
        .docker => {
            cmd.addArg(arg);
        },
    }
}

pub fn addArgs(run: *MountRun, args: []const []const u8) void {
    const cmd = run.cmd;
    switch (run.mode) {
        .default => cmd.addArgs(args),
        .docker => {
            cmd.addArgs(args);
        },
    }
}

pub fn addFileInput(run: *MountRun, lp: LazyPath) void {
    const cmd = run.cmd;
    switch (run.mode) {
        .default => return cmd.addFileInput(lp),
        .docker => {
            cmd.addFileInput(lp);
        },
    }
}

pub fn addPrefixedDirectoryArg(run: *MountRun, prefix: []const u8, lp: LazyPath) void {
    switch (run.mode) {
        .default => run.cmd.addPrefixedDirectoryArg(prefix, lp),
        .docker => run.addRewriteDirectoryArg(prefix, lp),
    }
}

pub fn addOutputFileArg(run: *MountRun, basename: []const u8) LazyPath {
    switch (run.mode) {
        .default => return run.cmd.addOutputFileArg(basename),
        .docker => return run.addRewriteOutputFileArg(basename),
    }
}

pub fn addFileArg(run: *MountRun, lp: LazyPath) void {
    const cmd = run.cmd;
    switch (run.mode) {
        .default => cmd.addFileArg(lp),
        .docker => {
            run.addRewriteFileArg("", lp);
        },
    }
}

pub fn addPrefixedFileArg(run: *MountRun, prefix: []const u8, lp: LazyPath) void {
    const cmd = run.cmd;
    switch (run.mode) {
        .default => cmd.addPrefixedFileArg(prefix, lp),
        .docker => {
            run.addRewriteFileArg(prefix, lp);
        },
    }
}

fn addRewriteOutputFileArg(run: *MountRun, basename: []const u8) LazyPath {
    const b = run.step.owner;
    const docker = &run.docker;

    const generated_file = b.allocator.create(std.Build.GeneratedFile) catch @panic("OOM");
    generated_file.* = .{ .step = &run.cmd.step };
    const output_path: LazyPath = .{ .generated = .{ .file = generated_file } };

    // Add argument to track
    docker.rewrite_argv.append(b.allocator, .{
        .kind = .output_file,
        .argv_index = run.cmd.argv.items.len,
        .prefix = "",
        .path = output_path.dupe(b),
        // Generated File
        .generated_file = generated_file,
        .output_basename = b.dupe(basename),
    }) catch @panic("OOM");

    const cmd = run.cmd;
    cmd.addArg("__MountRun_OutputFile");

    return output_path;
}

fn addRewriteFileArg(run: *MountRun, prefix: []const u8, path: LazyPath) void {
    const b = run.step.owner;
    const docker = &run.docker;

    // Add argument to track
    docker.rewrite_argv.append(run.step.owner.allocator, .{
        .kind = .file,
        .argv_index = run.cmd.argv.items.len,
        .prefix = prefix,
        .path = path.dupe(b),
    }) catch @panic("OOM");
    path.addStepDependencies(&run.step);

    // Add argument to system command
    const cmd = run.cmd;
    cmd.addArg("__MountRun_ReplaceFileArg");
    cmd.addFileInput(path);
}

fn addRewriteDirectoryArg(run: *MountRun, prefix: []const u8, path: LazyPath) void {
    const b = run.step.owner;
    const docker = &run.docker;

    // Add argument to track
    docker.rewrite_argv.append(b.allocator, .{
        .kind = .dir,
        .argv_index = run.cmd.argv.items.len,
        .prefix = b.dupe(prefix),
        .path = path.dupe(b),
    }) catch @panic("OOM");
    path.addStepDependencies(&run.step);

    // Add argument to system command
    const cmd = run.cmd;
    cmd.addArg("__MountRun_ReplaceDirectoryArg");
    path.addStepDependencies(&cmd.step); // addFileInput-like behaviour for directories
}

/// Used in make step
const ResolvedMountDirectory = struct {
    local: []const u8,
    remote: []const u8,
};

fn make(step: *Step, _: Build.Step.MakeOptions) !void {
    const b = step.owner;
    const arena = b.graph.arena;
    const run: *MountRun = @fieldParentPtr("step", step);

    switch (run.mode) {
        .default => {},
        .docker => {
            const docker = &run.docker;

            // If no paths to rewrite then do nothing
            if (docker.rewrite_argv.items.len == 0) {
                return;
            }

            const mounted_directories = try arena.alloc(ResolvedMountDirectory, docker.mounted_directories.len);
            for (docker.mounted_directories, 0..) |mounted_dir, i| {
                const local = try mounted_dir.local_directory.getPath3(b, step).toString(arena);
                std.mem.replaceScalar(u8, local, '\\', '/');
                mounted_directories[i] = .{
                    .local = local,
                    .remote = mounted_dir.docker_directory,
                };
            }

            // Collect manifest for output files
            var man = b.graph.cache.obtain();
            defer man.deinit();
            for (run.cmd.file_inputs.items) |lazy_path| {
                _ = try man.addFile(lazy_path.getPath2(b, step), null);
            }
            const digest = man.hash.final();

            for (docker.rewrite_argv.items) |rewrite_arg| {
                const arg = &run.cmd.argv.items[rewrite_arg.argv_index];
                // if (arg.bytes.len > 0) allocator.free(arg.bytes);

                // Setup path
                const path = pathblk: {
                    var path = subpathblk: switch (rewrite_arg.kind) {
                        .file, .dir => try rewrite_arg.path.getPath3(b, step).toString(arena),
                        .output_file => {
                            const generated_path = try b.cache_root.join(arena, &.{
                                "o", &digest, rewrite_arg.output_basename,
                            });
                            rewrite_arg.generated_file.?.path = generated_path;
                            break :subpathblk generated_path;
                        },
                    };
                    std.mem.replaceScalar(u8, path, '\\', '/');

                    if (path[0] == '.' and std.mem.startsWith(u8, path, ".zig-cache")) {
                        // TODO: Fix local Zig directory logic for mounting
                        path = b.fmt("/source/{s}", .{path});
                        break :pathblk path;
                    }
                    for (mounted_directories) |mounted_directory| {
                        // TODO: Find shortest match? Avoid nested mounting when setting up?
                        const local = mounted_directory.local;
                        if (std.mem.startsWith(u8, path, local)) {
                            path = b.fmt("{s}{s}", .{ mounted_directory.remote, path[local.len..] });
                            break :pathblk path;
                        }
                    }
                    try step.addError("unable to rewrite path to mounted directory: {s} {s}", .{ @tagName(rewrite_arg.kind), path });
                    continue;
                };

                switch (rewrite_arg.kind) {
                    .file => {
                        arg.bytes = try mem.concat(b.allocator, u8, &.{ rewrite_arg.prefix, path });
                    },
                    .dir => {
                        arg.bytes = try mem.concat(b.allocator, u8, &.{ rewrite_arg.prefix, path });
                    },
                    .output_file => {
                        // ie. /source/.zig-cache/o/437627f8b7b804df4a86b99ddef87b68/SDL_keyboard.o
                        arg.bytes = try mem.concat(b.allocator, u8, &.{ rewrite_arg.prefix, path });
                    },
                }
                // arg.bytes = b.fmt("{s}{s}", .{ rewrite_arg.prefix, rewrite_arg.path.getPath3(b, step) });
            }
        },
    }
}

const Docker = struct {
    image: []const u8,
    prefix_setup: bool,
    postfix_setup: bool,
    rewrite_argv: ArrayList(RewritePath),
    mounted_directories: []const DockerMountDirectory,
};

const RewritePath = struct {
    kind: Kind,
    argv_index: usize,
    prefix: []const u8,
    path: LazyPath,

    // kind == output_*
    output_basename: []const u8 = &[0]u8{},
    generated_file: ?*std.Build.GeneratedFile = null,

    const Kind = enum {
        file,
        dir,
        output_file,
    };
};

const Mode = enum {
    default,
    docker,
};

const MountRun = @This();
