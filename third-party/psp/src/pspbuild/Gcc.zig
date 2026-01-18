const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const Run = Step.Run;
const LazyPath = Build.LazyPath;
const ArrayList = std.ArrayListUnmanaged;

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

/// Set the zig.h include path to be used when compiling against gcc
/// If set to null, then it'll use the default path
pub fn SetZigInclude(g: *Gcc, zig_h_path: ?LazyPath) void {
    g.zig_h_path = zig_h_path;
}

pub fn addZigIncludeDirectory(g: *Gcc, directory_path: LazyPath) void {
    const b = g.b;
    g.zig_include_directories.append(b.allocator, directory_path) catch @panic("OOM");
}

pub fn addIncludeDirectory(g: *Gcc, directory_path: LazyPath) void {
    const b = g.b;
    g.include_directories.append(b.allocator, directory_path) catch @panic("OOM");
}

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

const Gcc = @This();
