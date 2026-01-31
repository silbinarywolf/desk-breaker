//! NOTE(jae): 2026-01-30
//! Not used anymore but kept for historical purposes
//!
//! Custom Zig implementation of: pspsdk/src/startup/crt0_prx.c
//! https://github.com/pspdev/pspsdk/blob/ae4731159b272ec03157b14fe9ca4ad58687aa3e/src/startup/crt0_prx.c

const root = @import("root");
const mem = @import("std").mem;
const builtin = @import("builtin");
const user = @import("user.zig");

/// default_main_thread_name is set to "user_main" for the PSP SDK
///
/// Source: https://github.com/pspdev/pspsdk/blob/c665eedbf2cce2ae62fe200551bcf98f8bdb425f/src/startup/crt0.c#L29
const default_main_thread_name = "zig_user_main";

const default_stack_size_in_bytes = 256 * 1024;

comptime {
    @export(&module_start, .{ .name = "module_start" });
    @export(&_exit, .{ .name = "_exit" });
    if (builtin.link_libcpp) {
        // NOTE(jae): 2026-01-16
        // __dso_handle comes from C++, even if we stub this psp-fixup-imports gets "size of text section and nid section do not match"
        @export(&__dso_handle, .{ .name = "__dso_handle" });
    }
}

extern fn __libcglue_init(argc: c_int, argv: [*c][*c]u8) callconv(.c) void;
extern fn __libcglue_deinit() callconv(.c) void;
extern fn _init() callconv(.c) void;
extern fn _fini() callconv(.c) void;

// stub __dso_handle for C++ code
var __dso_handle: ?*anyopaque = null;

/// Entry point - launches main through the thread above.
/// See C example here: https://github.com/pspdev/pspsdk/blob/ae4731159b272ec03157b14fe9ca4ad58687aa3e/src/startup/crt0.c#L119
fn module_start(argc: c_uint, argv: ?*anyopaque) callconv(.c) c_int {
    const thread_id = user.sceKernelCreateThread(
        default_main_thread_name,
        &_module_main_thread,
        32,
        default_stack_size_in_bytes,
        .{ .user = true, .vfpu = true },
        null,
    );
    return user.sceKernelStartThread(thread_id, argc, argv);
}

fn _exit(status: c_int) callconv(.c) noreturn {
    _ = status;

    // if (builtin.link_libcpp) {
    //     // call global c++ destructors
    //     _fini();
    // }

    if (builtin.link_libc) {
        // uninitialize libcglue
        __libcglue_deinit();
    }

    user.sceKernelExitGame();
    // if (&sce_newlib_nocreate_thread_in_start != NULL) {
    //     // user.sceKernelSelfStopUnloadModule(1, 0, NULL);
    // } else {
    //     user.sceKernelExitGame();
    // }

    while (true) {} // Avoid warning
}

/// This calls your main function as a thread.
///
/// args - Size (in bytes) of the argp parameter.
/// argp = Pointer to program arguments.  Each argument is a NUL-terminated string.
///
/// Based off of: https://github.com/pspdev/pspsdk/blob/master/src/startup/crt0_prx.c#L59
pub fn _module_main_thread(arg_count_in_bytes: c_uint, argp: [*c]u8) callconv(.c) c_int {
    // Get C arguments
    const ARG_MAX = 19;
    var argv: [ARG_MAX + 1][*c]u8 = undefined;
    var argc: u32 = 0;
    var argp_offset: u32 = 0;
    while (argp_offset < arg_count_in_bytes and argc < ARG_MAX) : (argc += 1) {
        const arg = argp[argp_offset..];
        argp_offset += mem.len(arg) + 1;
        argv[argc] = arg;
    }
    // _ = argc;

    // if (has_std_os) {
    // pspos.system.__pspOsInit(argv);
    // }

    if (builtin.link_libc) {
        // Call libc initialization hook
        __libcglue_init(@intCast(argc), argv[0..argc].ptr);
    }

    // if (builtin.link_libcpp) {
    //     // Init can contain C++ constructors that require working threading
    //     _init();
    // }

    switch (@typeInfo(@typeInfo(@TypeOf(root.main)).@"fn".return_type.?)) {
        .noreturn => {
            root.main();
        },
        .void => {
            root.main();
            return 0;
        },
        .int => |info| {
            if (info.bits != 8 or info.is_signed) {
                @compileError("invalid main implementation");
            }
            return root.main();
        },
        .error_union => {
            const result = root.main() catch {
                // TODO: handle error
                // debug.print("ERROR CAUGHT: ");
                // debug.print(@errorName(err));
                // debug.print("\nExiting in 10 seconds...");

                exitErr();
                return 1;
            };
            switch (@typeInfo(@TypeOf(result))) {
                .void => return 0,
                .int => |info| {
                    if (info.bits != 8) {
                        @compileError("invalid main implementation");
                    }
                    return result;
                },
                else => @compileError("invalid main implementation"),
            }
        },
        else => @compileError("invalid main implementation"),
    }

    // if (debug.exitOnEnd) {
    // user.sceKernelExitGame();
    // }
    return 0;
}

/// If there's an issue this is the internal exit (wait 10 seconds and exit).
pub inline fn exitErr() void {
    // Hang for 10 seconds for error reporting
    _ = user.sceKernelDelayThread(10 * 1000 * 1000);
    user.sceKernelExitGame();
}
