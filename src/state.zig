const std = @import("std");
const builtin = @import("builtin");
const time = std.time;
const mem = std.mem;

const sdl = @import("sdl");
const imgui = @import("imgui");

const Duration = @import("time.zig").Duration;
const Alarm = @import("time.zig").Alarm;
const Lexer = @import("lexer.zig").Lexer;

const log = std.log.default;
const assert = std.debug.assert;

const winuser = struct {
    const WINBOOL = c_int;
    const HWND = std.os.windows.HWND;

    pub const SW_SHOWNOACTIVATE = @as(c_int, 4);
    pub extern fn ShowWindow(hWnd: HWND, nCmdShow: c_int) WINBOOL;
};
// const winuser_ = @cImport({
//     @cDefine("WIN32_LEAN_AND_MEAN", "1");
//     @cInclude("windows.h");
// });

pub const TimerKind = enum(c_int) {
    timer = 0,
    alarm = 1,

    pub fn label(self: TimerKind) [:0]const u8 {
        return switch (self) {
            .timer => "Timer",
            .alarm => "Alarm",
        };
    }

    pub const ImGuiItems: [:0]const u8 = @This().timer.label() ++ "\x00"; // ++ @This().alarm.label() ++ "\x00";
};

pub const Timer = struct {
    pub const Name = std.BoundedArray(u8, 128);

    kind: TimerKind,

    // Common
    name: Name = .{},

    // Alarm
    // alarm_time: ?Time = null,

    // // ActivityBreak
    // time_till_break: Duration = Duration.init(30 * time.ns_per_min),
    // break_time: Duration = Duration.init(5 * time.ns_per_min),

    // Timer

    /// if not null then a timer has been started
    timer_started: ?std.time.Timer = null,
    timer_duration: ?Duration = null,

    // // Alarm
    // alarm_time: i64 = 0,
};

pub const UserSettings = struct {
    default_time_till_break: Duration = Duration.init(30 * time.ns_per_min),
    default_break_time: Duration = Duration.init(5 * time.ns_per_min),
    default_exit_time: Duration = Duration.init(10 * time.ns_per_s),

    is_activity_break_enabled: bool = true,
    time_till_break: ?Duration = null,
    break_time: ?Duration = null,

    pub fn time_till_break_or_default(self: *const @This()) Duration {
        return self.time_till_break orelse self.default_time_till_break;
    }

    pub fn break_time_or_default(self: *const @This()) Duration {
        return self.break_time orelse self.default_break_time;
    }

    pub fn exit_time_or_default(self: *const @This()) Duration {
        return self.default_exit_time;
    }
};

pub const Mode = enum {
    regular,
    taking_break,
    incoming_break,
};

/// UiDuration is a fixed-size buffer that has more than enough length to write text like:
/// "365d 24h 60m 60s"
const UiDuration = [64:0]u8;

/// UiTimer is temporary user-interface data when creating and editing a timer
const UiTimer = struct {
    id: i32 = -1, // -1 = new
    kind: TimerKind = .timer,
    name: [128:0]u8 = std.mem.zeroes([128:0]u8),
    alarm_time: UiDuration = std.mem.zeroes(UiDuration),
    duration_time: UiDuration = std.mem.zeroes(UiDuration),
    errors: struct {
        duration_time: []const u8 = "",
    } = .{},
};

pub const UiStateKind = enum {
    none,
    timer, // add or edit timer
    options,
};

const UiState = struct {
    kind: UiStateKind = .none,
    timer: UiTimer = .{},
    options: struct {
        is_activity_break_enabled: bool = false,
        time_till_break: UiDuration = std.mem.zeroes(UiDuration),
        break_time: UiDuration = std.mem.zeroes(UiDuration),
        errors: struct {
            time_till_break: []const u8 = &[0]u8{},
            break_time: []const u8 = &[0]u8{},
        } = .{},
    } = .{},
};

pub const State = struct {
    mode: Mode,
    window: Window,
    window_state: WindowState = .{},

    // user settings
    timers: std.ArrayList(Timer),
    user_settings: UserSettings = .{},

    time_since_last_input: ?time.Timer = null,
    time_till_next_state: time.Timer,

    is_user_mouse_active: bool = false,

    // break
    break_mode: struct {
        /// if clicked the Exit button or ESC an amount of times, close break window
        esc_or_exit_presses: u32 = 0,
        held_down_timer: ?std.time.Timer = null,
    } = .{},

    // ui state (temporary state when editing)
    ui: UiState = .{},

    /// stores printed text per-frame and other temporary things
    temp_allocator: std.heap.ArenaAllocator,

    /// tprint will allocate temporary text into a buffer that will stop existing next render frame
    pub fn tprint(self: *State, comptime fmt: []const u8, args: anytype) std.fmt.AllocPrintError![:0]u8 {
        return std.fmt.allocPrintZ(self.temp_allocator.allocator(), fmt, args);
    }

    /// check if a timers criteria has been triggered
    pub fn time_till_next_timer_complete(self: *State) ?Duration {
        var time_till_break: ?Duration = null;

        // Time till activity break
        {
            switch (self.mode) {
                .regular, .incoming_break => {
                    if (self.user_settings.is_activity_break_enabled) {
                        const time_active_in_ns = self.time_till_next_state.read();
                        time_till_break = self.user_settings.time_till_break_or_default().diff(time_active_in_ns);
                    }
                },
                .taking_break => {
                    // if taking a break, then the time until next timer is irrelevant
                    return null;
                },
            }
        }

        // Check timers
        for (self.timers.items) |*t| {
            switch (t.kind) {
                .timer => {
                    const timer_duration = t.timer_duration orelse continue;
                    var timer_started = t.timer_started orelse continue;
                    const diff = timer_duration.diff(timer_started.read());
                    const time_till_break_no_null = time_till_break orelse {
                        // If not set, then
                        time_till_break = diff;
                        continue;
                    };
                    if (diff.nanoseconds < time_till_break_no_null.nanoseconds) {
                        time_till_break = diff;
                    }
                },
                .alarm => {
                    @panic("TODO: handle alarm in time_till_next_timer_complete");
                },
            }
        }
        return time_till_break orelse null;
    }

    pub fn change_mode(state: *State, new_mode: Mode) void {
        if (state.mode == new_mode) {
            return;
        }
        if (state.mode == .regular) {
            log.info("change_mode: get state", .{});
            state.window_state = state.window.get_state();
        }
        switch (new_mode) {
            .regular => {
                state.window.exit_break_mode();
                state.window.update_from_state(state.window_state);

                // reset activity timer
                state.time_till_next_state.reset();

                // reset timers (that have been triggered)
                for (state.timers.items) |*t| {
                    switch (t.kind) {
                        .timer => {
                            // Check if timer started
                            var timer_started = t.timer_started orelse continue;
                            const timer_duration = t.timer_duration orelse unreachable;

                            const diff = timer_duration.diff(timer_started.read());
                            if (diff.nanoseconds == 0) {
                                // Disable timer
                                t.timer_started = null;
                            }
                        },
                        .alarm => {
                            @panic("TODO: handle alarm");
                        },
                    }
                }
            },
            .incoming_break => {
                if (!state.window.enter_incoming_break()) {
                    // Don't change state if we can't query display
                    return;
                }
                // state.time_till_next_state.reset(); // Do not reset this for this case
            },
            .taking_break => {
                log.info("change_mode: taking break", .{});
                state.window.enter_break_mode();
                state.time_till_next_state.reset();
                state.break_mode = .{}; // reset escape presses / etc
            },
        }
        state.mode = new_mode;
    }
};

const WindowState = struct {
    x: c_int = 0,
    y: c_int = 0,
    w: c_int = 0,
    h: c_int = 0,
    is_minimized: bool = false,
};

pub const Window = struct {
    window: ?*sdl.SDL_Window = null,
    renderer: ?*sdl.SDL_Renderer = null,
    imgui_context: ?*imgui.ImGuiContext = null,

    // TODO: make this configurable
    const break_display_id: c_int = 0;

    pub fn init(font_atlas: *imgui.ImFontAtlas, icon: *sdl.SDL_Surface, maybe_window: ?*sdl.SDL_Window) !Window {
        const window: *sdl.SDL_Window = maybe_window orelse {
            log.err("unable to create window: {s}", .{sdl.SDL_GetError()});
            return error.SDLWindowInitializationFailed;
        };
        sdl.SDL_SetWindowIcon(window, icon);
        // TODO: Make SOFTWARE renderer optional in settings
        const renderer: *sdl.SDL_Renderer = sdl.SDL_CreateRenderer(window, -1, 0) orelse {
            log.err("unable to create renderer: {s}", .{sdl.SDL_GetError()});
            return error.SDLRendererInitializationFailed;
        };
        errdefer sdl.SDL_DestroyRenderer(renderer);

        const imgui_context = imgui.igCreateContext(font_atlas);
        errdefer imgui.igDestroyContext(imgui_context);

        const imgui_io = &imgui.igGetIO()[0];
        imgui_io.IniFilename = null; // disable imgui.ini
        imgui_io.IniSavingRate = -1; // disable imgui.ini

        _ = imgui.ImGui_ImplSDL2_InitForSDLRenderer(@ptrCast(window), @ptrCast(renderer));
        errdefer imgui.ImGui_ImplSDL2_Shutdown();

        _ = imgui.ImGui_ImplSDLRenderer2_Init(@ptrCast(renderer));
        errdefer imgui.ImGui_ImplSDLRenderer2_Shutdown();

        return .{
            .window = window,
            .renderer = renderer,
            .imgui_context = imgui_context,
        };
    }

    pub fn deinit(self: *Window) void {
        if (self.imgui_context) |imgui_context| {
            imgui.igDestroyContext(imgui_context);
        }
        if (self.renderer) |renderer| {
            sdl.SDL_DestroyRenderer(renderer);
        }
        if (self.window) |window| {
            sdl.SDL_DestroyWindow(window);
        }
        self.* = .{};
    }

    fn get_state(self: *const Window) WindowState {
        const window = self.window;
        var state: WindowState = .{
            .is_minimized = sdl.SDL_GetWindowFlags(window) & sdl.SDL_WINDOW_MINIMIZED != 0,
        };
        sdl.SDL_GetWindowPosition(window, &state.x, &state.y);
        sdl.SDL_GetWindowSize(window, &state.w, &state.h);
        return state;
    }

    fn update_from_state(self: *Window, state: WindowState) void {
        const window = self.window;

        // NOTE(jae): 2024-07-16 - SDL 2.30.5
        // On Windows 10, this must happen before minimizing
        sdl.SDL_SetWindowSize(window, state.w, state.h);
        sdl.SDL_SetWindowPosition(window, state.x, state.y);

        if (state.is_minimized) {
            sdl.SDL_MinimizeWindow(window);
        }
    }

    fn enter_incoming_break(self: *Window) bool {
        // Don't work if we can't get display dimensions
        var display: sdl.SDL_Rect = undefined;
        if (sdl.SDL_GetDisplayUsableBounds(break_display_id, &display) != 0) {
            return false;
        }
        const window = self.window orelse unreachable;

        RestoreWindow_NoActivateFocus(window); // unminimize it
        sdl.SDL_SetWindowResizable(window, 0);
        if (builtin.os.tag == .macos) {
            _ = sdl.SDL_SetWindowBordered(window, 0);
        }

        const width: c_int = 200;
        const height: c_int = 200;
        sdl.SDL_SetWindowSize(window, width, height);
        sdl.SDL_SetWindowPosition(window, display.x + display.w - width, display.y + display.h - height);

        _ = sdl.SDL_SetWindowAlwaysOnTop(window, 1);
        if (builtin.os.tag != .macos) {
            _ = sdl.SDL_SetWindowBordered(window, 0); // For Windows/Kbuntu, must be after SetWindowPosition/SetWindowSize
        }
        return true;
    }

    fn enter_break_mode(self: *Window) void {
        const window = self.window orelse unreachable;

        sdl.SDL_SetWindowMouseGrab(window, 1); // lock mouse to window
        sdl.SDL_SetWindowKeyboardGrab(window, 1); // lock keyboard to window

        RaiseAndActivateFocus(window); // unminimize and set input focus
        sdl.SDL_SetWindowResizable(window, 0);
        if (builtin.os.tag == .macos) {
            _ = sdl.SDL_SetWindowBordered(window, 0);
        }

        var display: sdl.SDL_Rect = undefined;
        if (sdl.SDL_GetDisplayUsableBounds(break_display_id, &display) == 0) {
            log.info("change_mode: got display: {}", .{display});
            sdl.SDL_SetWindowPosition(window, display.x, display.y);
            sdl.SDL_SetWindowSize(window, display.w, display.h);
        } else {
            // Fallback if cannot query display
            sdl.SDL_SetWindowPosition(window, 0, 0);
            sdl.SDL_SetWindowSize(window, 640, 480);
        }

        _ = sdl.SDL_SetWindowAlwaysOnTop(window, 1);
        if (builtin.os.tag != .macos) {
            _ = sdl.SDL_SetWindowBordered(window, 0); // For Windows/Kbuntu, must be after SetWindowPosition/SetWindowSize
        }
    }

    fn exit_break_mode(self: *Window) void {
        const window = self.window;

        sdl.SDL_SetWindowMouseGrab(window, 0); // free mouse lock from window
        sdl.SDL_SetWindowKeyboardGrab(window, 0); // lock keyboard to window

        sdl.SDL_SetWindowAlwaysOnTop(window, 0);
        sdl.SDL_SetWindowBordered(window, 1);
        sdl.SDL_SetWindowResizable(window, 1);
    }
};

fn RestoreWindow_NoActivateFocus(window: *sdl.SDL_Window) void {
    switch (builtin.os.tag) {
        .windows => {
            // NOTE(jae): 2024-07-16 - SDL 2.30.5
            // Do this to make sure the window appears where we set it
            sdl.SDL_HideWindow(window);
            sdl.SDL_RestoreWindow(window);

            // NOTE(jae): 2024-07-16 - SDL 2.30.5
            // This hint is only supported on the Windows OS right now
            _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_NO_ACTIVATION_WHEN_SHOWN, "1");
            sdl.SDL_ShowWindow(window);
            _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_NO_ACTIVATION_WHEN_SHOWN, "0");
        },
        else => {
            sdl.SDL_RestoreWindow(window); // unminimize
            sdl.SDL_RaiseWindow(window); // put above every other window
        },
    }
}

fn RaiseAndActivateFocus(window: *sdl.SDL_Window) void {
    switch (builtin.os.tag) {
        .windows => {
            // NOTE(jae): 2024-07-16 - SDL 2.30.5
            // We do this so that on a multiple monitor setup so that minimizing / raising the window
            // captures the mouse into the window and locks it in
            sdl.SDL_MinimizeWindow(window);

            sdl.SDL_RaiseWindow(window);

            _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_NO_ACTIVATION_WHEN_SHOWN, "0");
            sdl.SDL_ShowWindow(window);
            _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_NO_ACTIVATION_WHEN_SHOWN, "1");
        },
        else => {
            // NOTE(jae): 2024-07-16 - SDL 2.30.5
            // Do this to capture mouse on X11 (Linux), needs ShowWindow afterward to activate it
            sdl.SDL_RaiseWindow(window);
            sdl.SDL_HideWindow(window); // X11: hide window first, then do ShowWindow to activate it
            sdl.SDL_ShowWindow(window);
        },
    }
}

// SDL_VERSION alterantive that works, Zig 0.13.0 can't translate the macro
// pub fn SDL_VERSION(v: *sdl.SDL_version) void {
//     v.major = sdl.SDL_MAJOR_VERSION;
//     v.minor = sdl.SDL_MINOR_VERSION;
//     v.patch = sdl.SDL_PATCHLEVEL;
// }

// const hwnd = GetWindowsHwnd(window) catch |err| @panic(@errorName(err));
// _ = winuser.ShowWindow(hwnd, winuser.SW_SHOWNOACTIVATE);
//
// fn GetWindowsHwnd(window: *sdl.SDL_Window) error{SDLGetWindowWMInfo}!std.os.windows.HWND {
//     var wmInfo: sdl.SDL_SysWMinfo = undefined;
//     SDL_VERSION(&wmInfo.version);
//     if (sdl.SDL_GetWindowWMInfo(window, &wmInfo) != 1) {
//         return error.SDLGetWindowWMInfo;
//     }
//     return @ptrCast(wmInfo.info.win.window);
// }
