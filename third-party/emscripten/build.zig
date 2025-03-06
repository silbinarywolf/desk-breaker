const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;

/// NOTE: Required so this can be imported by other build.zig files
pub fn build(_: *std.Build) void {}

pub const Tools = @import("src/emscriptenbuild/Tools.zig");
