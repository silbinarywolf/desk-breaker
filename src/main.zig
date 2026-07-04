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

comptime {
    if (builtin.os.tag == .psp) {
        // TODO(jae): 2026-06-30
        // Test this with the PSP building tools in the future.
        asm (psp.module_info(de_options.application_name, 0, 1, 0));
    }
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

pub const std_options: std.Options = .{
    .logFn = if (builtin.abi.isAndroid())
        android.logFn
    else
        de.logFn,
};

pub const main = de.main;

pub const panic = if (builtin.abi.isAndroid())
    android.panic
else if (builtin.os.tag == .psp)
    psp.panic
else
    std.debug.FullPanic(std.debug.defaultPanic);
