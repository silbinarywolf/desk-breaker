const builtin = @import("builtin");
const sdl = @import("sdl");
const ArrayList = @import("std").ArrayList;
const dumpErrorReturnTrace = @import("std").debug.dumpErrorReturnTrace;

const log = @import("std").log.scoped(.sdl);

/// If set to 0, just call SDL_PollEvent, otherwise if non-0 value then use SDL_WaitEventTimeout.
wait_timeout: u16,

pub const Options = struct {};

pub fn init(platform: *Platform, _: Options) !void {
    // TODO: Set this up
    // sdl.SDL_SetAppMetadata();

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_GAMEPAD)) {
        return error.SdlFailed;
    }
    errdefer sdl.SDL_Quit();

    platform.* = .{
        .wait_timeout = 0,
    };
}

pub fn deinit(platform: *Platform) void {
    sdl.SDL_Quit();
    platform.* = undefined;
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
