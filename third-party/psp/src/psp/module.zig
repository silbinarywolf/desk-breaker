test {
    @import("std").testing.refAllDecls(@This());
}

const std = @import("std");
const builtin = @import("builtin");
const user = @import("user.zig");
// const psp = @import("psp");
// const psptypes = @import("psp");
// const debug = @import("debug.zig");

const root = @import("root");

/// If there's an issue this is the internal exit (wait 10 seconds and exit).
pub inline fn exitErr() void {
    // Hang for 10 seconds for error reporting
    _ = user.sceKernelDelayThread(10 * 1000 * 1000);
    user.sceKernelExitGame();
}

extern fn __libcglue_init(argc: c_int, argv: [*c][*c]u8) callconv(.c) void;
extern fn __libcglue_deinit() callconv(.c) void;
extern fn _init() callconv(.c) void;
extern fn _fini() callconv(.c) void;

// const has_std_os = if (@hasDecl(root, "os")) true else false;
const bad_main_ret = @compileError("Where is this from?!");

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
        argp_offset += std.mem.len(arg) + 1;
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

    if (builtin.link_libcpp) {
        // Init can contain C++ constructors that require working threading
        _init();
    }

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
                @compileError(bad_main_ret);
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
                        @compileError(bad_main_ret);
                    }
                    return result;
                },
                else => @compileError(bad_main_ret),
            }
        },
        else => @compileError(bad_main_ret),
    }

    // if (debug.exitOnEnd) {
    // user.sceKernelExitGame();
    // }
    return 0;
}

//Stub!
//
//Modified BSD License
//====================
//
//_Copyright � `2020`, `Hayden Kowalchuk`_
//_All rights reserved._
//
//Redistribution and use in source and binary forms, with or without
//modification, are permitted provided that the following conditions are met:
//
//1. Redistributions of source code must retain the above copyright
//   notice, this list of conditions and the following disclaimer.
//2. Redistributions in binary form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the
//   documentation and/or other materials provided with the distribution.
//3. Neither the name of the `<organization>` nor the
//   names of its contributors may be used to endorse or promote products
//   derived from this software without specific prior written permission.
//
//THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS �AS IS� AND
//ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//DISCLAIMED. IN NO EVENT SHALL `Hayden Kowalchuk` BE LIABLE FOR ANY
//DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
//ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//    Thanks to mrneo240 (Hayden Kowalchuk) for the help
//
comptime {
    asm (
        \\.data
        \\.globl module_info
        \\.globl __syslib_exports
        \\.globl __library_exports
        \\
        \\.set push
        \\
        \\.section .lib.ent.top, "a", @progbits
        \\    .align 2
        \\    .word 0
        \\__lib_ent_top:
        \\
        \\.section .lib.ent.btm, "a", @progbits
        \\    .align 2
        \\__lib_ent_bottom:
        \\    .word 0
        \\
        \\.section .lib.stub.top, "a", @progbits
        \\    .align 2
        \\    .word 0
        \\__lib_stub_top:
        \\
        \\.section .lib.stub.btm, "a", @progbits
        \\    .align 2
        \\__lib_stub_bottom:
        \\    .word 0
        \\
        \\.set pop
        \\
        \\.section .rodata.sceResident, "a", @progbits
        \\__syslib_exports:
        \\    .word 0xD632ACDB
        \\    .word 0xF01D73A7
        \\    .word module_start
        \\    .word module_info
        \\
        \\.section .lib.ent, "a", @progbits
        \\__library_exports:
        \\    .word 0
        \\    .hword 0
        \\    .hword 0x8000
        \\    .byte 4
        \\    .byte 1
        \\    .hword 1
        \\    .word __syslib_exports
    );
}

// export const __syslib_exports: [4]usize linksection(".rodata.sceResident") = [_]usize{
//     0xD632ACDB,
//     0xF01D73A7,
//     @intFromPtr(&module_start),
//     @intFromPtr(&module_info),
// };

fn intToString(int: u32, buf: []u8) ![]const u8 {
    return try @import("std").fmt.bufPrint(buf, "{}", .{int});
}

pub fn module_info(comptime name: []const u8, comptime attrib: u16, comptime major: u8, comptime minor: u8) []const u8 {
    @setEvalBranchQuota(10000);
    var buf: [3]u8 = undefined;

    const maj = intToString(major, &buf) catch unreachable;
    buf = undefined;
    const min = intToString(minor, &buf) catch unreachable;
    buf = undefined;
    const attr = intToString(attrib, &buf) catch unreachable;
    buf = undefined;
    const count = intToString(27 - name.len, &buf) catch unreachable;

    // NOTE: .glob exports the module_info symbol
    return (
        \\.globl module_info
        \\
        \\.section .rodata.sceModuleInfo, "a", @progbits
        \\module_info:
        \\.align 5
        \\.hword
    ++ " " ++ attr ++ "\n" ++
        \\.byte
    ++ " " ++ maj ++ "\n" ++
        \\.byte
    ++ " " ++ min ++ "\n" ++
        \\.ascii "
    ++ name ++ "\"\n" ++
        \\.space
    ++ " " ++ count ++ "\n" ++
        \\.byte 0
        \\.word _gp
        \\.word __lib_ent_top
        \\.word __lib_ent_bottom
        \\.word __lib_stub_top
        \\.word __lib_stub_bottom
    );
}

/// default_main_thread_name is set to "user_main" for the PSP SDK
///
/// Source: https://github.com/pspdev/pspsdk/blob/c665eedbf2cce2ae62fe200551bcf98f8bdb425f/src/startup/crt0.c#L29
const default_main_thread_name = "zig_user_main";

const default_stack_size_in_bytes = 256 * 1024;

comptime {
    @export(&module_start, .{ .name = "module_start" });
    @export(&_exit, .{ .name = "_exit" });
    // if (builtin.link_libcpp) {
    //     // NOTE(jae): 2026-01-16
    //     // __dso_handle comes from C++, even if we stub this psp-fixup-imports gets "size of text section and nid section do not match"
    //     @export(&__dso_handle, .{ .name = "__dso_handle" });
    // }
}

// stub __dso_handle for C++ code
//fn __dso_handle() callconv(.c) void {}

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

    if (builtin.link_libcpp) {
        // call global c++ destructors
        _fini();
    }

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

// https://github.com/pspdev/pspsdk/blob/1e93cff63655988a29bc0ec1e3fffc5ba578bcc0/src/user/pspmoduleinfo.h
// const SceModuleInfo = extern struct {
//     attribute: u16,
//     version: [2]u8,
//     name: [27]u8,
//     terminal: u8,
//     gp_value: ?*anyopaque,
//     ent_top: ?*anyopaque,
//     ent_end: ?*anyopaque,
//     stub_top: ?*anyopaque,
//     stub_end: ?*anyopaque,
// };
