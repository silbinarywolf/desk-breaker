const builtin = @import("builtin");
const sdl = @import("sdl");
const mem = @import("std").mem;
const Allocator = @import("std").mem.Allocator;
const Io = @import("std").Io;
const CLibraryAllocator = @import("../CLibraryAllocator.zig");
const ArrayList = @import("std").ArrayList;
const dumpErrorReturnTrace = @import("std").debug.dumpErrorReturnTrace;
const assert = @import("std").debug.assert;
const de_options = @import("../RootOptions.zig").current;

const log = @import("std").log.scoped(.sdl);

is_initialized: bool,
/// If set to 0, just call SDL_PollEvent, otherwise if non-0 value then use SDL_WaitEventTimeout.
wait_timeout: u16,

pub const Options = struct {};

pub const Error = error{SdlFailed};

pub const uninitialized: Platform = .{
    .is_initialized = false,
    .wait_timeout = undefined,
};

pub fn init(platform: *Platform, gpa: Allocator, io: Io, _: Options) !void {
    if (platform.is_initialized) @panic("cannot call init more than once");
    _ = gpa;
    _ = io;

    // NOTE(jae): 2026-06-30
    // If we're on Linux and have X11 or XWayland, prefer it over Wayland to have
    // more control of creation of multiple windows.
    switch (de_options.window_constraint) {
        .single_window => {},
        .multiple_window => {
            // NOTE(jae): 2026-07-01
            // Only force fallback to X11/Xwayland if there is no existing hint
            const video_driver_hint = sdl.SDL_GetHint(sdl.SDL_HINT_VIDEO_DRIVER);
            if (video_driver_hint == null) {
                const video_driver_count: u32 = @intCast(sdl.SDL_GetNumVideoDrivers());
                for (0..video_driver_count) |video_driver_index| {
                    const video_driver_name_cstr = sdl.SDL_GetVideoDriver(@intCast(video_driver_index));
                    if (video_driver_name_cstr == null) continue;
                    const video_driver_name = mem.span(video_driver_name_cstr);
                    if (mem.eql(u8, video_driver_name, "x11")) {
                        if (!sdl.SDL_SetHint(sdl.SDL_HINT_VIDEO_DRIVER, "x11")) return error.SdlFailed;
                        break;
                    }
                }
            }
        },
    }

    if (!sdl.SDL_SetAppMetadata(de_options.application_name, de_options.application_version, de_options.application_identifier)) {
        return error.SdlFailed;
    }
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_GAMEPAD)) {
        return error.SdlFailed;
    }
    errdefer sdl.SDL_Quit();

    platform.* = .{
        .is_initialized = false,
        .wait_timeout = 0,
    };
}

pub inline fn deinitHasError(platform: *Platform) void {
    if (!platform.is_initialized) return;
    // sdl.SDL_Quit() <- Do not call if errored, we need to return SDL_GetError() message without freeing that memory
    platform.deinitCommon();
}

pub fn deinitNoError(platform: *Platform) void {
    if (!platform.is_initialized) return;
    // NOTE(jae): 2026-06-29
    // Do not call SDL_Quit() for error handling path because when this is called as part of 'errdefer', we will lose
    // SDL_GetError() info when "SdlFailed" is called.
    sdl.SDL_Quit();
    platform.deinitCommon();
}

fn deinitCommon(platform: *Platform) void {
    platform.wait_timeout = undefined;
    platform.is_initialized = false;
}

pub const EventIterator = struct {
    platform: *Platform,
    sdl_event: sdl.SDL_Event,
    is_polling_events: bool,

    pub fn next(it: *EventIterator) ?*sdl.SDL_Event {
        const event = &it.sdl_event;
        const res = if (it.is_polling_events)
            sdl.SDL_PollEvent(event)
        else
            // To conserve CPU, this either blocks until {N}ms passed or until we get an event
            sdl.SDL_WaitEventTimeout(event, it.platform.wait_timeout);
        if (!res) return null;
        // If we received one event, start polling the rest of the events until queue is empty
        it.is_polling_events = true;
        return event;
    }
};

/// Used internally.
pub fn events(platform: *Platform) EventIterator {
    return .{
        .platform = platform,
        .is_polling_events = platform.wait_timeout == 0,
        .sdl_event = undefined,
    };
}

pub inline fn logUnhandledError(err: anyerror) void {
    switch (err) {
        error.SdlFailed => |sdl_failed_err| {
            if (sdlGetError()) |sdl_error_message| {
                log.err("{t} error: {s}", .{ sdl_failed_err, sdl_error_message });
            } else {
                log.err("{t} error", .{sdl_failed_err});
            }
        },
        else => {
            log.err("{t}", .{err});
        },
    }
}

/// Helper function for SDL_GetError(), returns null if the length of the error message is 0
pub fn sdlGetError() [*c]const u8 {
    const sdl_error = @as(?[*:0]const u8, sdl.SDL_GetError()) orelse return null;
    const error_message: [:0]const u8 = @import("std").mem.span(sdl_error);
    // NOTE(jae): This can return a C-string with length 0, so if thats the case, make it null
    if (error_message.len == 0) return null;
    return error_message;
}

const Platform = @This();
