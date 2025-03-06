const std = @import("std");
const builtin = @import("builtin");
const time = std.time;
const mem = std.mem;

const sdl = @import("sdl");
const imgui = @import("imgui");

const SdlPng = @import("SdlPng.zig");
const UserConfig = @import("UserConfig.zig");
const Duration = @import("Duration.zig");

const Window = @import("Window.zig");

const log = std.log.scoped(.App);
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

/// Name of the application
pub const Name = "Desk Breaker";

/// For Windows operating systems, this is the key used for opening the application on start-up
///
/// ie. SOFTWARE\Microsoft\Windows\CurrentVersion\Run
pub const StartupRegistryKey = "DeskBreaker";

pub const ImGuiDefaultWindowFlags = imgui.ImGuiWindowFlags_NoTitleBar | imgui.ImGuiWindowFlags_NoDecoration |
    imgui.ImGuiWindowFlags_NoResize | imgui.ImGuiWindowFlags_NoBackground;

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
    pub const TimerName = std.BoundedArray(u8, 128);

    kind: TimerKind,

    // Common
    name: TimerName = .{},

    // Alarm
    // alarm_time: ?Time = null,

    // ActivityBreak
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
    default_incoming_break: Duration = Duration.init(20 * time.ns_per_s),

    settings: UserConfig.Settings,
    timers: std.ArrayList(Timer),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .settings = .{},
            .timers = std.ArrayList(Timer).init(allocator),
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
        self.timers.deinit();
    }

    pub fn time_till_break_or_default(self: *const @This()) Duration {
        return self.settings.time_till_break orelse self.default_time_till_break;
    }

    pub fn snooze_duration_or_default(self: *const @This()) Duration {
        // TODO(jae): make snooze configurable
        return self.default_snooze;
    }

    pub fn break_time_or_default(self: *const @This()) Duration {
        return self.settings.break_time orelse self.default_break_time;
    }

    pub fn exit_time_or_default(self: *const @This()) Duration {
        return self.default_exit_time;
    }

    /// Get the max allowed snoozes in a row
    pub fn max_snoozes_in_a_row_or_default(self: *const @This()) i32 {
        return self.settings.max_snoozes_in_a_row orelse 2;
    }

    /// The amount of warning you get before the break takes up the full screen in nanoseconds
    pub fn incoming_break_or_default(self: *const @This()) Duration {
        return self.settings.incoming_break orelse self.default_incoming_break;
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

/// [128:0]u8
const UiMessage = [128:0]u8;

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

pub const Screen = enum {
    overview,
    timer, // add or edit timer
    options,
};

const UiState = struct {
    screen: Screen = .overview,
    /// allocate buffers for each input field as needed, this buffer is cleared when the timer or options
    /// screen is opened.
    ui_allocator: std.heap.ArenaAllocator,
    timer: UiTimer,
    options: struct {
        /// os_startup is true if you want the application to boot on operating system startup
        os_startup: ?bool = switch (builtin.os.tag) {
            .windows => false,
            else => null,
        },
        display_index: u32 = 0,
        is_activity_break_enabled: bool = false,
        time_till_break: [:0]u8,
        break_time: [:0]u8,
        incoming_break: UiDuration = std.mem.zeroes(UiDuration),
        incoming_break_message: [128:0]u8 = std.mem.zeroes([128:0]u8),
        max_snoozes_in_a_row: [128:0]u8 = std.mem.zeroes([128:0]u8),
        errors: struct {
            time_till_break: []const u8 = &[0]u8{},
            break_time: []const u8 = &[0]u8{},
            incoming_break: []const u8 = &[0]u8{},
            incoming_break_message: []const u8 = &[0]u8{},
            max_snoozes_in_a_row: []const u8 = &[0]u8{},
        } = .{},
    },
    options_metadata: struct {
        display_names_buf: std.BoundedArray(u8, 4096) = std.BoundedArray(u8, 4096){},
    },

    /// allocBuffer will get a temporary buffer to use for UI elements
    pub fn allocBuffer(self: *@This()) std.mem.Allocator.Error![:0]u8 {
        return try self.ui_allocator.allocator().allocSentinel(u8, 96, 0);
    }

    /// allocDuration will return a buffer of [N:0]
    pub fn allocDuration(self: *@This(), duration: ?Duration) error{ OutOfMemory, NoSpaceLeft }![:0]u8 {
        const buf = try self.allocBuffer();
        buf[0] = '\x00';
        if (duration) |td| _ = try std.fmt.bufPrintZ(buf, "{sh}", .{td});
        // NOTE(jae): 2025-01-31
        // Return the full buffer for use with ImGui, this is why we ignore bufPrintZ
        return buf;
    }
};

pub const NextTimer = struct {
    /// ID is either
    /// - -1 or lesser, which represents custom built-in timer types
    /// - 0 or greater and represents a user-configured timer
    const ID = enum(i32) {
        /// a timer used when the user has snoozed the activity timer
        snooze_timer = -2,
        /// a built-in timer type that triggers from computer usage
        activity_timer = -1,
        /// If 0 or higher, than it represents a configured timer
        _,
    };

    id: ID,
    time_till_next_break: Duration,
};

mode: Mode,

allocator: std.mem.Allocator,
/// stores printed text per-frame and other temporary things
temp_allocator: std.heap.ArenaAllocator,

icon: SdlPng.Image,

// Windows

/// main application window
window: ?*Window,
tray: ?*sdl.SDL_Tray,
popup_windows: std.ArrayListUnmanaged(Window) = .{},
taking_break_windows: std.ArrayListUnmanaged(Window) = .{},

/// set to true to quit the application at the start of the next frame
has_quit: bool = false,

/// if set to true, will minimize to system tray
minimize_to_tray: bool = false,

// user settings are not owned by this struct and must be freed by the creator.
user_settings: *UserSettings,

time_since_last_input: ?time.Timer = null,

/// stores the current time, once the difference between this and current time > user_settings.break_time then a break is triggered
activity_timer: time.Timer,

// if you click snooze, a shorter timer will start
snooze_activity_break_timer: ?time.Timer = null,

is_user_mouse_active: bool = false,

/// amount of times snooze button was hit
snooze_times: u32 = 0,
snooze_times_in_a_row: u32 = 0,

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
ui: UiState,

pub fn init(allocator: std.mem.Allocator, user_settings: *UserSettings) !App {
    var icon_png = try SdlPng.load(allocator, @embedFile("resources/icon.png"));
    errdefer icon_png.deinit(allocator);

    return .{
        .mode = .regular,
        .allocator = allocator,
        .temp_allocator = std.heap.ArenaAllocator.init(allocator),
        .icon = icon_png,
        .window = null,
        .tray = null,
        .user_settings = user_settings,
        .activity_timer = try std.time.Timer.start(),
        .ui = .{
            .ui_allocator = std.heap.ArenaAllocator.init(allocator),
            .timer = undefined,
            .options = undefined,
            .options_metadata = undefined,
        },
    };
}

pub fn deinit(app: *App) void {
    const allocator = app.allocator;
    app.ui.ui_allocator.deinit();
    if (app.window) |app_window| {
        app_window.deinit();
        allocator.destroy(app_window);
    }
    for (app.popup_windows.items) |*window| {
        window.deinit();
    }
    app.popup_windows.deinit(allocator);
    for (app.taking_break_windows.items) |*window| {
        window.deinit();
    }
    if (app.tray) |tray| {
        sdl.SDL_DestroyTray(tray);
    }
    app.taking_break_windows.deinit(allocator);
    app.icon.deinit(allocator);
    app.user_settings.deinit(allocator);
    allocator.destroy(app.user_settings);
    // NOTE(jae): 2024-11-15: user_settings is freed outside of this
    // state.user_settings.deinit(state.allocator);
    app.temp_allocator.deinit();
    app.* = undefined;
}

/// tprint will allocate temporary text into a buffer that will stop existing next render frame
pub fn tprint(self: *App, comptime fmt: []const u8, args: anytype) std.fmt.AllocPrintError![:0]u8 {
    return std.fmt.allocPrintZ(self.temp_allocator.allocator(), fmt, args);
}

/// check if a timers criteria has been triggered
pub fn time_till_next_timer_complete(app: *App) ?NextTimer {
    var next_timer: ?NextTimer = null;

    // If snoozing activity break
    if (app.snooze_activity_break_timer) |*snooze_timer| {
        const snooze_time_in_ns = snooze_timer.read();
        next_timer = .{
            .id = .snooze_timer,
            .time_till_next_break = app.user_settings.snooze_duration_or_default().diff(snooze_time_in_ns),
        };
    }

    // Time till activity break
    {
        var can_trigger_activity_break = true;
        if (next_timer) |nt| {
            if (nt.id == .snooze_timer) {
                can_trigger_activity_break = false;
            }
        }
        if (can_trigger_activity_break) {
            switch (app.mode) {
                .regular, .incoming_break => {
                    if (app.user_settings.settings.is_activity_break_enabled) {
                        const time_active_in_ns = app.activity_timer.read();
                        next_timer = .{
                            .id = .activity_timer,
                            .time_till_next_break = app.user_settings.time_till_break_or_default().diff(time_active_in_ns),
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
    for (app.user_settings.timers.items, 0..) |*t, i| {
        switch (t.kind) {
            .timer => {
                const timer_duration = t.timer_duration orelse continue;
                var timer_started = t.timer_started orelse continue;
                const diff = timer_duration.diff(timer_started.read());
                const existing_next_timer: NextTimer = next_timer orelse {
                    // If no existing timer set, then
                    next_timer = .{
                        .id = @enumFromInt(i),
                        .time_till_next_break = diff,
                    };
                    continue;
                };
                if (diff.nanoseconds < existing_next_timer.time_till_next_break.nanoseconds) {
                    next_timer = .{
                        .id = @enumFromInt(i),
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
pub fn can_snooze(app: *App) bool {
    // Disallow snooze button if hit max snooze limit
    const max_snoozes_in_a_row = app.user_settings.max_snoozes_in_a_row_or_default();
    if (max_snoozes_in_a_row != UserConfig.Settings.MaxSnoozesDisabled and
        app.snooze_times_in_a_row >= max_snoozes_in_a_row)
    {
        return false;
    }

    // If it was an alarm or timer, disallow snoozing
    if (app.has_timer_or_alarm_triggered()) {
        return false;
    }

    return true;
}

pub fn has_timer_or_alarm_triggered(app: *App) bool {
    for (app.user_settings.timers.items) |*t| {
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

pub fn snooze(app: *App) void {
    const is_snoozeable: bool = app.can_snooze();
    assert(is_snoozeable);
    if (!is_snoozeable) {
        return;
    }

    // reset activity timer
    app.activity_timer.reset();
    app.snooze_activity_break_timer = time.Timer.start() catch unreachable;
    app.snooze_times += 1;
    app.snooze_times_in_a_row += 1;
}

pub fn change_mode(app: *App, new_mode: Mode) !void {
    if (app.mode == new_mode) {
        return;
    }
    switch (new_mode) {
        .regular => {
            log.debug("change_mode: regular", .{});

            // reset activity timer
            app.activity_timer.reset();

            // reset timers (that have been triggered)
            for (app.user_settings.timers.items) |*t| {
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
            log.debug("change_mode: incoming break", .{});
            const should_change_state = blk: {
                const display_index = app.user_settings.settings.display_index;

                // Don't work if we can't get display dimensions
                const display = Window.getDisplayUsableBoundsFromIndex(display_index) orelse {
                    log.err("incoming_break: unable to query display usable bounds: {s}", .{sdl.SDL_GetError()});
                    return error.SdlFailed;
                };

                const width: c_int = 200;
                const height: c_int = 200;

                const popup_window = Window.init(.{
                    .title = "Incoming Break",
                    .icon = app.icon.surface,
                    .focusable = false,
                    .borderless = true,
                    .always_on_top = true,
                    .x = display.x + display.w - width,
                    .y = display.y + display.h - height,
                    .width = width,
                    .height = height,
                }) catch |err| {
                    log.err("incoming_break: failed to init window after creation: {}", .{err});
                    return err;
                };
                try app.popup_windows.append(app.allocator, popup_window);

                break :blk true;
            };
            if (!should_change_state) {
                // Don't change state if we can't query display
                return;
            }
            // state.time_till_next_state.reset(); // Do not reset this for this case
        },
        .taking_break => {
            log.debug("change_mode: taking break", .{});

            const display_index = app.user_settings.settings.display_index;

            // Don't work if we can't get display dimensions
            const display: sdl.SDL_Rect = Window.getDisplayUsableBoundsFromIndex(display_index) orelse .{
                // Fallback if cannot query display
                .x = 0,
                .y = 0,
                .w = 640,
                .h = 480,
            };

            const taking_break_window = Window.init(.{
                .title = "Take a break",
                .icon = app.icon.surface,
                .borderless = true,
                .always_on_top = true,
                .mouse_grabbed = true,
                .x = display.x,
                .y = display.y,
                .width = display.w,
                .height = display.h,
            }) catch |err| {
                log.err("taking_break: failed to init window after creation: {}", .{err});
                return err;
            };
            try app.taking_break_windows.append(app.allocator, taking_break_window);

            // Setup break time
            var break_time_duration = app.user_settings.break_time_or_default();

            // If break for timer or alarm then make it 45 seconds
            if (app.time_till_next_timer_complete()) |next_timer| {
                switch (next_timer.id) {
                    .activity_timer => {}, // no-op
                    .snooze_timer => {
                        app.snooze_activity_break_timer = null;
                    },
                    else => {
                        // TODO(jae): Make this configurable
                        const timer_break_duration = 45 * time.ns_per_s;
                        if (break_time_duration.nanoseconds > timer_break_duration) {
                            break_time_duration = Duration.init(45 * time.ns_per_s);
                        }
                    },
                }
            } else {
                // If invalid/unknown state
                log.err("unexpected state in change_mode(.taking_break), no next timer", .{});
            }

            app.activity_timer.reset();
            app.break_mode = .{
                // setup these fields
                .timer = time.Timer.start() catch unreachable,
                .duration = break_time_duration,
                // reset escape presses / etc
            };
        },
    }
    app.mode = new_mode;
}

const App = @This();

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
