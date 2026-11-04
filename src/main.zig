const builtin = @import("builtin");
const de = @import("de");
const App = @import("App.zig");
const std = @import("std");
const log = @import("std").log;
const debug = @import("std").debug;
const process = @import("std").process;
const android = if (builtin.abi.isAndroid()) @import("android") else void;
const psp = if (builtin.os.tag == .psp) @import("psp") else void;

comptime {
    // Force "comptime" blocks to run such as "SDL_main" export for Android
    _ = de;
}

pub const de_options: de.Options = .{
    .application_type = App,
    .application_name = "Desk Breaker",
    .application_version = "0.5.X-dev",
    .application_identifier = "com.silbinarywolf.deskbreaker",
    .platform_type = .sdl_zig,
    .window_constraint = .multiple_window,
    .imgui = .{
        .default_font_size = 29,
    },
};

pub const main = de.main;

pub const std_options: std.Options = .{
    .logFn = if (builtin.abi.isAndroid())
        android.logFn
    else
        de.logFn,
};

pub const panic = if (builtin.abi.isAndroid())
    android.panic
else switch (builtin.os.tag) {
    .psp => psp.panic,
    else => std.debug.FullPanic(std.debug.defaultPanic),
};

pub const os = switch (builtin.os.tag) {
    .psp => struct {
        pub const PATH_MAX = 255; // FAT32
    },
    else => struct {},
};

/// For PSP support in Zig 0.17.1
pub const std_options_debug_io = switch (builtin.os.tag) {
    .psp => std.Io.failing,
    else => std.Options.debug_threaded_io.?.io(),
};

/// For PSP support in Zig 0.17.1
pub const std_options_cwd = switch (builtin.os.tag) {
    .psp => cwdPspOrConsolePlatforms,
    else => null,
};

fn cwdPspOrConsolePlatforms() std.Io.Dir {
    // Copied from 'wasi' implementation
    return .{ .handle = 3 }; // Expect the first preopen to be current working directory.
}

// NOTE(jae): 2026-11-04
// Rely on SDL3 to setup 'module_info' instead now.
//
// comptime {
//     if (builtin.os.tag == .psp) {
//         // TODO(jae): 2026-06-30
//         // Test this with the PSP building tools in the future.
//         asm (psp.module_info(de_options.application_name, 0, 1, 0));
//     }
// }
