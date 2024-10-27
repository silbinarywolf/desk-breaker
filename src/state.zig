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
    default_snooze: Duration = Duration.init(10 * time.ns_per_min),
    default_break_time: Duration = Duration.init(5 * time.ns_per_min),
    default_exit_time: Duration = Duration.init(10 * time.ns_per_s),

    is_activity_break_enabled: bool = true,
    time_till_break: ?Duration = null,
    break_time: ?Duration = null,
    /// this is the monitor to display on
    display_index: u32 = 0,
    timers: std.ArrayList(Timer),

    pub fn deinit(self: *@This()) void {
        self.timers.deinit();
    }

    pub fn time_till_break_or_default(self: *const @This()) Duration {
        return self.time_till_break orelse self.default_time_till_break;
    }

    pub fn snooze_duration_or_default(self: *const @This()) Duration {
        // TODO(jae): make snooze configurable
        return self.default_snooze;
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
        /// os_startup is true if you want the application to boot on operating system startup
        os_startup: ?bool = switch (builtin.os.tag) {
            .windows => false,
            else => null,
        },
        display_index: u32 = 0,
        is_activity_break_enabled: bool = false,
        time_till_break: UiDuration = std.mem.zeroes(UiDuration),
        break_time: UiDuration = std.mem.zeroes(UiDuration),
        errors: struct {
            time_till_break: []const u8 = &[0]u8{},
            break_time: []const u8 = &[0]u8{},
        } = .{},
    } = .{},
    options_metadata: struct {
        display_names_buf: std.BoundedArray(u8, 4096) = std.BoundedArray(u8, 4096){},
    } = .{},
};

pub const NextTimer = struct {
    pub const ActivityTimer: i32 = -1;
    pub const SnoozeTimer: i32 = -2;

    id: i32,
    time_till_next_break: Duration,
};

pub const State = struct {
    mode: Mode,
    window: Window,
    window_state: WindowState = .{},

    // user settings
    user_settings: UserSettings,

    time_since_last_input: ?time.Timer = null,

    /// stores the current time, once the difference between this and current time > user_settings.break_time then a break is triggered
    activity_timer: time.Timer,

    // if you click snooze, a shorter timer will start
    snooze_activity_break_timer: ?time.Timer = null,

    is_user_mouse_active: bool = false,

    /// amount of times snooze button was hit
    snooze_times: u32 = 0,

    // break
    break_mode: struct {
        /// if clicked the Exit button or ESC an amount of times, close break window
        esc_or_exit_presses: u32 = 0,
        held_down_timer: ?std.time.Timer = null,
        /// timer that runs while waiting for a break
        timer: std.time.Timer,
        duration: Duration,
    } = .{
        .timer = std.mem.zeroes(std.time.Timer),
        .duration = Duration.init(0),
    },

    // ui state (temporary state when editing)
    ui: UiState = .{},

    /// stores printed text per-frame and other temporary things
    temp_allocator: std.heap.ArenaAllocator,

    /// tprint will allocate temporary text into a buffer that will stop existing next render frame
    pub fn tprint(self: *State, comptime fmt: []const u8, args: anytype) std.fmt.AllocPrintError![:0]u8 {
        return std.fmt.allocPrintZ(self.temp_allocator.allocator(), fmt, args);
    }

    /// check if a timers criteria has been triggered
    pub fn time_till_next_timer_complete(state: *State) ?NextTimer {
        var next_timer: ?NextTimer = null;

        // If snoozing activity break
        if (state.snooze_activity_break_timer) |*snooze_timer| {
            const snooze_time_in_ns = snooze_timer.read();
            next_timer = NextTimer{
                .id = NextTimer.SnoozeTimer,
                .time_till_next_break = state.user_settings.snooze_duration_or_default().diff(snooze_time_in_ns),
            };
        }

        // Time till activity break
        {
            var can_trigger_activity_break = true;
            if (next_timer) |nt| {
                if (nt.id == NextTimer.SnoozeTimer) {
                    can_trigger_activity_break = false;
                }
            }
            if (can_trigger_activity_break) {
                switch (state.mode) {
                    .regular, .incoming_break => {
                        if (state.user_settings.is_activity_break_enabled) {
                            const time_active_in_ns = state.activity_timer.read();
                            next_timer = NextTimer{
                                .id = NextTimer.ActivityTimer,
                                .time_till_next_break = state.user_settings.time_till_break_or_default().diff(time_active_in_ns),
                            };
                        }
                    },
                    .taking_break => {
                        // if taking a break, then the time until next timer is irrelevant
                        return null;
                    },
                }
            }
        }

        // Check timers
        for (state.user_settings.timers.items, 0..) |*t, i| {
            switch (t.kind) {
                .timer => {
                    const timer_duration = t.timer_duration orelse continue;
                    var timer_started = t.timer_started orelse continue;
                    const diff = timer_duration.diff(timer_started.read());
                    const existing_next_timer: NextTimer = next_timer orelse {
                        // If no existing timer set, then
                        next_timer = NextTimer{
                            .id = @intCast(i),
                            .time_till_next_break = diff,
                        };
                        continue;
                    };
                    if (diff.nanoseconds < existing_next_timer.time_till_next_break.nanoseconds) {
                        next_timer = NextTimer{
                            .id = @intCast(i),
                            .time_till_next_break = diff,
                        };
                    }
                },
                .alarm => {
                    @panic("TODO: handle alarm in time_till_next_timer_complete");
                },
            }
        }
        return next_timer;
    }

    /// can_snooze is true if it's an activity timer but not a special alarm
    pub fn can_snooze(state: *State) bool {
        const is_snoozeable: bool = state.mode == .taking_break or state.mode == .incoming_break;
        assert(is_snoozeable);

        // Don't show snooze button if not taking break
        if (!is_snoozeable) {
            return false;
        }

        // If it was an alarm or timer, disallow snoozing
        if (state.has_timer_or_alarm_triggered()) {
            return false;
        }

        return true;
    }

    pub fn has_timer_or_alarm_triggered(state: *State) bool {
        for (state.user_settings.timers.items) |*t| {
            switch (t.kind) {
                .timer => {
                    const timer_duration = t.timer_duration orelse continue;
                    var timer_started = t.timer_started orelse continue;
                    const diff = timer_duration.diff(timer_started.read());
                    if (diff.nanoseconds <= 0) {
                        return true;
                    }
                },
                .alarm => {
                    @panic("TODO: handle alarm in has_timer_or_alarm_triggered");
                },
            }
        }
        return false;
    }

    pub fn snooze(state: *State) void {
        const is_snoozeable: bool = state.can_snooze();
        assert(is_snoozeable);
        if (!is_snoozeable) {
            return;
        }

        // reset activity timer
        state.activity_timer.reset();
        state.snooze_activity_break_timer = time.Timer.start() catch unreachable;
        state.snooze_times += 1;
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
                state.activity_timer.reset();

                // reset timers (that have been triggered)
                for (state.user_settings.timers.items) |*t| {
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
                if (!state.window.enter_incoming_break(state.user_settings.display_index)) {
                    // Don't change state if we can't query display
                    return;
                }
                // state.time_till_next_state.reset(); // Do not reset this for this case
            },
            .taking_break => {
                log.info("change_mode: taking break", .{});
                state.window.enter_break_mode(state.user_settings.display_index);

                // Setup break time
                var break_time_duration = state.user_settings.break_time_or_default();

                // If break for timer or alarm then make it 45 seconds
                if (state.time_till_next_timer_complete()) |next_timer| {
                    if (next_timer.id >= 0) {
                        // TODO(jae): Make this configurable
                        const timer_break_duration = 45 * time.ns_per_s;
                        if (break_time_duration.nanoseconds > timer_break_duration) {
                            break_time_duration = Duration.init(45 * time.ns_per_s);
                        }
                    } else {
                        switch (next_timer.id) {
                            NextTimer.ActivityTimer => {}, // no-op
                            NextTimer.SnoozeTimer => {
                                state.snooze_activity_break_timer = null;
                            },
                            else => {},
                        }
                    }
                } else {
                    // If invalid/unknown state
                    log.err("unexpected state in change_mode(.taking_break), no next timer", .{});
                }

                state.activity_timer.reset();
                state.break_mode = .{
                    // setup these fields
                    .timer = time.Timer.start() catch unreachable,
                    .duration = break_time_duration,
                    // reset escape presses / etc
                };
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
    display_index: u32 = 0,

    pub fn init(font_atlas: *imgui.ImFontAtlas, icon: *sdl.SDL_Surface, maybe_window: ?*sdl.SDL_Window) !Window {
        const window: *sdl.SDL_Window = maybe_window orelse {
            log.err("unable to create window: {s}", .{sdl.SDL_GetError()});
            return error.SDLWindowInitializationFailed;
        };
        _ = sdl.SDL_SetWindowIcon(window, icon);
        // TODO(jae): 2024-08-20
        // Add option to use hardware accelerated instead
        const renderer: *sdl.SDL_Renderer = sdl.SDL_CreateRenderer(window, sdl.SDL_SOFTWARE_RENDERER) orelse {
            log.err("unable to create renderer: {s}", .{sdl.SDL_GetError()});
            return error.SDLRendererInitializationFailed;
        };
        errdefer sdl.SDL_DestroyRenderer(renderer);

        const imgui_context = imgui.igCreateContext(font_atlas);
        errdefer imgui.igDestroyContext(imgui_context);

        const imgui_io = &imgui.igGetIO()[0];
        imgui_io.IniFilename = null; // disable imgui.ini
        imgui_io.IniSavingRate = -1; // disable imgui.ini

        _ = imgui.ImGui_ImplSDL3_InitForSDLRenderer(@ptrCast(window), @ptrCast(renderer));
        errdefer imgui.ImGui_ImplSDL3_Shutdown();

        _ = imgui.ImGui_ImplSDLRenderer3_Init(@ptrCast(renderer));
        errdefer imgui.ImGui_ImplSDLRenderer3_Shutdown();

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
        if (!sdl.SDL_GetWindowPosition(window, &state.x, &state.y)) {
            // TODO: handle this failure?
        }
        if (!sdl.SDL_GetWindowSize(window, &state.w, &state.h)) {
            // TODO: handle this failure?
        }
        return state;
    }

    fn update_from_state(self: *Window, state: WindowState) void {
        const window = self.window;

        // NOTE(jae): 2024-07-16 - SDL 2.30.5
        // On Windows 10, this must happen before minimizing
        _ = sdl.SDL_SetWindowSize(window, state.w, state.h);
        _ = sdl.SDL_SetWindowPosition(window, state.x, state.y);

        if (state.is_minimized) {
            _ = sdl.SDL_MinimizeWindow(window);
        }
    }

    fn get_display_id_from_index(display_index: u32) sdl.SDL_DisplayID {
        var display_count: c_int = undefined;
        const display_list_or_err = sdl.SDL_GetDisplays(&display_count);
        if (display_list_or_err == null) {
            return 0;
        }
        if (display_count == 0) {
            return 0;
        }
        const display_list = display_list_or_err[0..@intCast(display_count)];
        if (display_index < display_list.len) {
            // Use found display
            return display_list[display_index];
        }
        // If cannot find display by index, use first item
        return display_list[0];
    }

    fn enter_incoming_break(self: *Window, display_index: u32) bool {
        // Don't work if we can't get display dimensions
        var display: sdl.SDL_Rect = undefined;
        if (!sdl.SDL_GetDisplayUsableBounds(get_display_id_from_index(display_index), &display)) {
            return false;
        }
        const window = self.window orelse unreachable;

        _ = sdl.SDL_SetWindowResizable(window, false);
        _ = sdl.SDL_SetWindowBordered(window, false);

        const width: c_int = 200;
        const height: c_int = 200;
        _ = sdl.SDL_SetWindowSize(window, width, height);
        _ = sdl.SDL_SetWindowPosition(window, display.x + display.w - width, display.y + display.h - height);
        _ = sdl.SDL_SetWindowAlwaysOnTop(window, true);

        RestoreWindow_NoActivateFocus(window); // unminimize it
        return true;
    }

    fn enter_break_mode(self: *Window, display_index: u32) void {
        const window = self.window orelse unreachable;

        _ = sdl.SDL_SetWindowResizable(window, false);
        _ = sdl.SDL_SetWindowAlwaysOnTop(window, true);
        _ = sdl.SDL_SetWindowBordered(window, false); // For Windows/Kbuntu, must be after SetWindowPosition/SetWindowSize

        var display: sdl.SDL_Rect = undefined;
        if (sdl.SDL_GetDisplayUsableBounds(get_display_id_from_index(display_index), &display)) {
            log.info("change_mode: got display: {}", .{display});
            _ = sdl.SDL_SetWindowPosition(window, display.x, display.y);
            _ = sdl.SDL_SetWindowSize(window, display.w, display.h);
        } else {
            // Fallback if cannot query display
            _ = sdl.SDL_SetWindowPosition(window, 0, 0);
            _ = sdl.SDL_SetWindowSize(window, 640, 480);
        }

        _ = sdl.SDL_SetWindowMouseGrab(window, true); // lock mouse to window
        _ = sdl.SDL_SetWindowKeyboardGrab(window, true); // lock keyboard to window

        RaiseAndActivateFocus(window); // unminimize and set input focus
    }

    fn exit_break_mode(self: *Window) void {
        const window = self.window;

        _ = sdl.SDL_SetWindowMouseGrab(window, false); // free mouse lock from window
        _ = sdl.SDL_SetWindowKeyboardGrab(window, false); // lock keyboard to window

        _ = sdl.SDL_SetWindowAlwaysOnTop(window, true);
        _ = sdl.SDL_SetWindowBordered(window, true);
        _ = sdl.SDL_SetWindowResizable(window, true);
    }
};

fn RestoreWindow_NoActivateFocus(window: *sdl.SDL_Window) void {
    const oldActivateWhenRaised = sdl.SDL_GetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED);
    const oldActivateWhenShown = sdl.SDL_GetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN);
    _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED, "0");
    _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "0");
    defer {
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED, oldActivateWhenRaised);
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, oldActivateWhenShown);
    }

    const isMinimized = sdl.SDL_GetWindowFlags(window) & sdl.SDL_WINDOW_MINIMIZED != 0;
    if (isMinimized) {
        // TODO(jae): 2024-10-27
        // - Windows has issue where restoring from minimize causes this to steal focus.
        _ = sdl.SDL_RestoreWindow(window); // unminimize
    } else {
        _ = sdl.SDL_HideWindow(window);
        _ = sdl.SDL_ShowWindow(window); // put above every other window
    }
}

fn RaiseAndActivateFocus(window: *sdl.SDL_Window) void {
    const oldActivateWhenRaised = sdl.SDL_GetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED);
    const oldActivateWhenShown = sdl.SDL_GetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN);
    const oldForceRaiseWindow = sdl.SDL_GetHint(sdl.SDL_HINT_FORCE_RAISEWINDOW);
    _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED, "1");
    _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "1");
    _ = sdl.SDL_SetHint(sdl.SDL_HINT_FORCE_RAISEWINDOW, "1");
    defer {
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED, oldActivateWhenRaised);
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, oldActivateWhenShown);
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_FORCE_RAISEWINDOW, oldForceRaiseWindow);
    }

    const isMinimized = sdl.SDL_GetWindowFlags(window) & sdl.SDL_WINDOW_MINIMIZED != 0;
    if (isMinimized) {
        _ = sdl.SDL_RestoreWindow(window); // unminimize
    } else {
        _ = sdl.SDL_RaiseWindow(window);
    }

    _ = sdl.SDL_HideWindow(window);
    _ = sdl.SDL_ShowWindow(window); // put above every other window

    // switch (builtin.os.tag) {
    //     .windows => {
    //         // NOTE(jae): 2024-07-16 - SDL 2.30.5
    //         // We do this so that on a multiple monitor setup so that minimizing / raising the window
    //         // captures the mouse into the window and locks it in
    //         _ = sdl.SDL_MinimizeWindow(window);

    //         _ = sdl.SDL_RaiseWindow(window);

    //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "1");
    //         _ = sdl.SDL_ShowWindow(window);
    //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "0");
    //     },
    //     else => {
    //         // NOTE(jae): 2024-07-16 - SDL 2.30.5
    //         // Do this to capture mouse on X11 (Linux), needs ShowWindow afterward to activate it
    //         _ = sdl.SDL_RaiseWindow(window);
    //         _ = sdl.SDL_HideWindow(window); // X11: hide window first, then do ShowWindow to activate it

    //         // TODO(jae): 2024-10-08
    //         // Investigate and see if this hint works on other OSes as of SDL3: SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN
    //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "1");
    //         _ = sdl.SDL_ShowWindow(window);
    //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "0");
    //     },
    // }
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
