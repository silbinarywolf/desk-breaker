const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;

/// NOTE: Required so this can be imported by other build.zig files
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("psp", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/psp/root.zig"),
    });
}

pub const Tools = @import("src/pspbuild/Tools.zig");
