//! user package is based off of the PSPSDK module "user"
//! Source: https://github.com/pspdev/pspsdk/tree/c665eedbf2cce2ae62fe200551bcf98f8bdb425f/src/user

const builtin = @import("builtin");

/// Delay the current thread by a specified number of microseconds
///
/// Example:
/// sceKernelDelayThread(1000000); // Delay for a second
pub extern fn sceKernelDelayThread(delay: c_uint) callconv(.c) c_int;

/// Exit game and go back to the PSP browser.
///
/// @note You need to be in a thread in order for this function to work
pub extern fn sceKernelExitGame() callconv(.c) void;

/// Create a thread
///
/// Example:
/// SceUID thid = sceKernelCreateThread("my_thread", threadFunc, 0x18, 0x10000, 0, NULL);
///
/// Return: UID of the created thread, or an error code.
pub extern fn sceKernelCreateThread(
    name: [*c]const u8,
    entry: ?SceKernelThreadEntry,
    init_priority: i32,
    stack_size: i32,
    attr: PspThreadAttributesMask,
    option: ?*SceKernelThreadOptParam,
) callconv(.c) i32;

/// Start a created thread
pub extern fn sceKernelStartThread(thread_id: c_int, args_len: c_uint, args: ?*anyopaque) callconv(.c) c_int;

/// Additional options used when creating threads
pub const SceKernelThreadOptParam = extern struct {
    /// Size of the ::SceKernelThreadOptParam structure.
    size: c_uint,
    /// UID of the memory block (?) allocated for the thread's stack.
    stack_mpid: c_int,
};

pub const SceKernelThreadEntry = *const fn (args_len: c_uint, args: [*c]u8) callconv(.c) c_int;

/// PspThreadAttributesMask for setting up PSP thread
pub const PspThreadAttributesMask = packed struct(u32) {
    unused_b0_13: u14 = 0,

    vfpu: bool = false, // bit 14 (0x00004000)
    scratch_sram: bool = false, // bit 15 (0x00008000)

    unused_b16_19: u4 = 0,

    no_fillstack: bool = false, // bit 20 (0x00100000)
    clear_stack: bool = false, // bit 21 (0x00200000)

    unused_b22_28: u7 = 0,

    usbwlan: bool = false, // NOTE: Set the user bit as well when using this
    vsh: bool = false, // NOTE: Set the user bit as well when using this
    user: bool = false, // bit 31 (0x80000000)
};

/// Attributes for PSP thread
pub const PspThreadAttributes = enum(u32) {
    /// Enable VFPU access for the thread.
    vfpu = 0x00004000,
    /// Start the thread in user mode (done automatically if the thread creating it is in user mode).
    user = 0x80000000,
    /// Thread is part of the USB/WLAN API.
    usbwlan = 0xa0000000,
    /// Thread is part of the VSH API.
    vsh = 0xc0000000,
    /// Allow using scratchpad memory for a thread, NOT USABLE ON V1.0,
    scratch_sram = 0x00008000,
    /// Disables filling the stack with 0xFF on creation
    no_fillstack = 0x00100000,
    /// Clear the stack when the thread is deleted
    clear_stack = 0x00200000,
};
