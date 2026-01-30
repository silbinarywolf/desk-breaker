test {
    @import("std").testing.refAllDecls(@This());
}

const std = @import("std");
const builtin = @import("builtin");
const user = @import("user.zig");
const root = @import("root");

// Custom setup runtime function instead of:
// https://github.com/pspdev/pspsdk/blob/ae4731159b272ec03157b14fe9ca4ad58687aa3e/src/startup/crt0_prx.c
// comptime {
//     _ = @import("crt0_prx.zig");
// }

pub const module_info = @import("prxexports.zig").module_info;

/// If there's an issue this is the internal exit (wait 10 seconds and exit).
pub inline fn exitErr() void {
    // Hang for 10 seconds for error reporting
    _ = user.sceKernelDelayThread(10 * 1000 * 1000);
    user.sceKernelExitGame();
}
