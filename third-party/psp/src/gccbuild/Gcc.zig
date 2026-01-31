//! Gcc is for setting up the various Gcc build settings

const std = @import("std");
const GccArtifact = @import("GccArtifact.zig");
const MountRun = @import("MountRun.zig");

const assert = std.debug.assert;

const Build = std.Build;
const Step = Build.Step;
const Run = Step.Run;
const LazyPath = Build.LazyPath;
const ArrayList = std.ArrayListUnmanaged;
const Compile = Step.Compile;

b: *Build,
/// (optional) prefix for the gcc binary, for example 'psp-' for the PSPSDK which has 'psp-gcc', 'psp-ar'
prefix: []const u8,
gcc_bin_path: LazyPath,
zig_h_path: ?LazyPath,
include_directories: ArrayList(LazyPath),
zig_include_directories: ArrayList(LazyPath),
lib_paths: ArrayList(LazyPath),

pub const Options = struct {
    /// prefix for the gcc binary, for example 'psp-' for the PSPSDK which has 'psp-gcc', 'psp-ar'
    prefix: ?[]const u8 = null,
};

pub fn create(b: *Build, gcc_bin_path: LazyPath, options: Options) *Gcc {
    const g = b.allocator.create(Gcc) catch @panic("OOM");
    g.* = .{
        .b = b,
        .gcc_bin_path = gcc_bin_path,
        .prefix = if (options.prefix) |prefix| prefix else &[0]u8{},
        .zig_h_path = null,
        .include_directories = .empty,
        .zig_include_directories = .empty,
        .lib_paths = .empty,
    };
    return g;
}

/// Override the default zig.h file to be used when compiling with GCC
///
/// If set to null, then it'll use the default path
pub fn setZigInclude(g: *Gcc, zig_h_path: ?LazyPath) void {
    g.zig_h_path = zig_h_path;
}

/// Add an additional include directory to specifically be used when compiling a Zig outputted *.c file.
///
/// NOTE(jae): 2026-01-30
/// This was added so we can wrap the default zig.h file and include another via this file.
///
/// Example:
///   gcc.setZigInclude(tools.dep.path("src/zig-c/zig.h"));
///   gcc.addZigIncludeDirectory(.{
///     .cwd_relative = std.fs.path.dirname(b.graph.zig_exe) orelse @panic("unable to get zig path to find lib/zig.h"),
///   });
pub fn addZigIncludeDirectory(g: *Gcc, directory_path: LazyPath) void {
    const b = g.b;
    g.zig_include_directories.append(b.allocator, directory_path) catch @panic("OOM");
}

pub fn addIncludeDirectory(g: *Gcc, directory_path: LazyPath) void {
    const b = g.b;
    g.include_directories.append(b.allocator, directory_path) catch @panic("OOM");
}

/// Add default system library paths
///
/// For example, to use the PSP-SDK, we add these:
///   gcc.addLibraryPath(pspsdk.path(b, "psp/sdk/lib")); // libpspkernel, libpspmp3, etc
///   gcc.addLibraryPath(pspsdk.path(b, "psp/lib"));     // libc, libz, libpthread
pub fn addLibraryPath(g: *Gcc, directory_path: LazyPath) void {
    const b = g.b;
    g.lib_paths.append(b.allocator, directory_path) catch @panic("OOM");
}

pub fn gcc(g: *const Gcc) LazyPath {
    const b = g.b;
    return g.gcc_bin_path.path(b, b.fmt("{s}gcc", .{g.prefix}));
}

pub fn @"g++"(g: *const Gcc) LazyPath {
    const b = g.b;
    return g.gcc_bin_path.path(b, b.fmt("{s}g++", .{g.prefix}));
}

pub fn ar(g: *const Gcc) LazyPath {
    const b = g.b;
    return g.gcc_bin_path.path(b, b.fmt("{s}gcc-ar", .{g.prefix}));
}

/// This function takes your Zig artifact and creates a binary built with GCC that can be retrieved
/// via result.getEmittedBin()
pub fn convertArtifactExe(g: *Gcc, artifact: *Compile) *GccArtifact {
    return GccArtifact.createExe(g, artifact);
}

const Gcc = @This();
