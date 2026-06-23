const std = @import("std");
const builtin = @import("builtin");
const time = std.time;
const Timer = @import("Timer.zig");
const GlobalCAllocator = @import("GlobalCAllocator.zig");
const wayland = @import("wayland.zig");
const de = @import("de");

const mem = std.mem;

const sdl = @import("sdl");
const imgui = @import("imgui");

const Image = @import("de").Image;
const UserConfig = @import("UserConfig.zig");
const Duration = @import("Duration.zig");
const ProcessList = @import("ProcessList.zig");
const Window = @import("Window.zig");

const ScreenOverview = @import("ScreenOverview.zig");
const ScreenAddEditTimer = @import("ScreenAddEditTimer.zig");
const ScreenOptions = @import("ScreenOptions.zig");
const ScreenIncomingBreak = @import("ScreenIncomingBreak.zig");
const ScreenTakingBreak = @import("ScreenTakingBreak.zig");

const log = std.log.scoped(.App);
const assert = std.debug.assert;

const winuser = struct {
    const WINBOOL = c_int;
    const HWND = std.os.windows.HWND;

    pub const SW_SHOWNOACTIVATE = @as(c_int, 4);
    pub extern fn ShowWindow(hWnd: HWND, nCmdShow: c_int) WINBOOL;
};

/// Threshold to have responsive event polling based on:
/// - Wait N frames before we do WaitEvent so that the initial rendering sets things up nicely
/// - Wait N frames after keyboard presses for responsiveness
const FrameWithoutInputThreshold: u16 = 250;

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

pub const StateTimer = struct {
    kind: TimerKind,

    // Common
    name: [:0]const u8 = &.{},

    // Alarm
    // alarm_time: ?Time = null,

    // ActivityBreak
    // time_till_break: Duration = Duration.init(30 * time.ns_per_min),
    // break_time: Duration = Duration.init(5 * time.ns_per_min),

    // Timer

    /// if not null then a timer has been started
    timer_started: ?Timer = null,
    timer_duration: ?Duration = null,

    // // Alarm
    // alarm_time: i64 = 0,

    pub fn deinit(t: *StateTimer, allocator: std.mem.Allocator) void {
        if (t.name.len > 0) allocator.free(t.name);
    }
};

pub const UserSettings = struct {
    default_time_till_break: Duration = Duration.init(30 * time.ns_per_min),
    default_snooze: Duration = Duration.init(10 * time.ns_per_min),
    default_break_time: Duration = Duration.init(5 * time.ns_per_min),
    default_exit_time: Duration = Duration.init(10 * time.ns_per_s),
    default_incoming_break: Duration = Duration.init(20 * time.ns_per_s),

    settings: UserConfig.Settings,
    timers: std.ArrayList(StateTimer),

    pub const default: UserSettings = .{
        .settings = .{},
        .timers = .empty,
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
        for (self.timers.items) |*t| {
            t.deinit(allocator);
        }
        self.timers.deinit(allocator);
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
        display_names_buf: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    },

    /// allocBuffer will get a temporary buffer to use for UI elements
    pub fn allocBuffer(self: *@This()) std.mem.Allocator.Error![:0]u8 {
        return try self.ui_allocator.allocator().allocSentinel(u8, 96, 0);
    }

    /// allocDuration will return a buffer of [N:0]
    pub fn allocDuration(self: *@This(), duration: ?Duration) error{ OutOfMemory, NoSpaceLeft }![:0]u8 {
        const buf = try self.allocBuffer();
        buf[0] = '\x00';
        if (duration) |td| _ = try std.fmt.bufPrintZ(buf, "{f}", .{td.formatShort()});
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

io: std.Io,
allocator: std.mem.Allocator,
global_c_allocator: *GlobalCAllocator,
/// stores printed text per-frame and other temporary things
temp_allocator: std.heap.ArenaAllocator,

platform: *de.Platform,

icon: Image,
icon_red: Image,
icon_flash_timer: ?Timer,

// Windows

/// main application window
window: ?*Window,
popup_windows: std.ArrayListUnmanaged(Window) = .empty,
taking_break_windows: std.ArrayListUnmanaged(Window) = .empty,

/// system tray
tray: ?*sdl.SDL_Tray,
tray_icon: TrayIconMode = .default,

/// set to true to quit the application at the start of the next frame
has_tray_quit: bool = false,
/// set to true if the window was opened from system tray
has_opened_from_tray: bool = false,
/// set to true if the operating supports system tray
has_tray_support: bool = false,

/// If using Windows or Mac, then assume we have global mouse position support, otherwise do not.
has_global_mouse_support: bool = switch (builtin.os.tag) {
    .windows => true,
    .macos => true,
    // ie. Linux+Wayland does not have mouse support, Android does not have mouse support
    else => false,
},

/// if set to true, will minimize to system tray on the next frame
minimize_to_tray: bool = false,

// user settings are not owned by this struct and must be freed by the creator.
user_settings: *UserSettings,

time_since_last_input: ?Timer = null,

frames_without_app_input: u16 = 0,
prev_mouse_pos: de.Vector2f = .zero,

/// stores the current time, once the difference between this and current time > user_settings.break_time then a break is triggered
activity_timer: Timer,

// if you click snooze, a shorter timer will start
snooze_activity_break_timer: ?Timer = null,

is_user_active: bool = false,
is_game_active: bool = false,

process_list: ProcessList,
process_check_timer: Timer,

/// amount of times snooze button was hit
snooze_times: u32 = 0,
snooze_times_in_a_row: u32 = 0,

// break
break_mode: struct {
    /// if clicked the Exit button or ESC an amount of times, close break window
    esc_or_exit_presses: u32 = 0,
    held_down_timer: ?Timer = null,
    /// timer that runs while waiting for a break
    timer: Timer,
    duration: Duration,
} = .{
    .timer = std.mem.zeroes(Timer),
    .duration = Duration.init(0),
},

// ui state (temporary state when editing)
ui: UiState,

debug_frame_count: u32 = 0,

pub fn init(startup: de.Startup, app: *App) !void {
    const gpa = startup.gpa;
    const io = startup.io;

    // Setup custom allocators for SDL and Imgui
    // - We can use the GeneralPurposeAllocator to catch memory leaks
    var global_c_allocator = try GlobalCAllocator.init(gpa, io);
    errdefer global_c_allocator.deinit();

    // Setup platform
    {
        // Make the event polling wait
        // if (!sdl.SDL_SetHint(sdl.SDL_HINT_MAIN_CALLBACK_RATE, "waitevent")) return error.SdlFailed;

        // NOTE(jae): 2025-12-27
        // If we're on Linux and have X11, prefer it over Wayland
        // - I can control where the "Incoming Break" window gets created
        // - I can detect activity with global mouse movement
        if (comptime builtin.os.tag == .linux and !builtin.abi.isAndroid()) {
            const video_driver_count: u32 = @intCast(sdl.SDL_GetNumVideoDrivers());
            for (0..video_driver_count) |video_driver_index| {
                const video_driver_name_cstr = sdl.SDL_GetVideoDriver(@intCast(video_driver_index));
                if (video_driver_name_cstr == null) continue;
                const video_driver_name = std.mem.span(video_driver_name_cstr);
                if (std.mem.eql(u8, video_driver_name, "x11")) {
                    if (!sdl.SDL_SetHint(sdl.SDL_HINT_VIDEO_DRIVER, "x11")) return error.SdlFailed;
                    break;
                }
            }
        }
    }

    // Setup platform, ie. SDL_Init
    try startup.platform.init(.{});
    errdefer startup.platform.deinit();

    // Load your settings
    var user_settings: *UserSettings = gpa.create(UserSettings) catch |err| {
        log.err("unable to allocate UserSettings: {}", .{err});
        return err;
    };
    errdefer gpa.destroy(user_settings);

    user_settings.* = UserConfig.load(gpa, io) catch |err| switch (err) {
        // If no file found, use default
        error.FileNotFound => UserSettings.default,
        else => {
            log.err("unable to load user config: {}", .{err});
            return err;
        },
    };
    errdefer user_settings.deinit(gpa);

    var icon = try Image.loadPngFromBuffer(gpa, @embedFile("resources/icon.png"));
    errdefer icon.deinit(gpa);

    var icon_red = try Image.loadPngFromBuffer(gpa, @embedFile("resources/icon_red.png"));
    errdefer icon_red.deinit(gpa);

    // detect tray support
    const has_tray_support: bool = blk: {
        // NOTE(jae): 2025-05-25 - https://github.com/libsdl-org/SDL/issues/13119
        // Workaround issue where calling SDL_CreateTray before creating a window triggers SDL_EVENT_QUIT
        const last_window_close_hint = sdl.SDL_GetHint(sdl.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE);
        defer _ = sdl.SDL_SetHint(sdl.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, last_window_close_hint);
        assert(sdl.SDL_SetHint(sdl.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0"));

        const tray = sdl.SDL_CreateTray(null, App.Name) orelse {
            log.debug("CreateTray failed: {s}", .{sdl.SDL_GetError()});
            break :blk false;
        };
        sdl.SDL_DestroyTray(tray);
        break :blk true;
    };

    app.* = .{
        .mode = .regular,
        .io = io,
        .allocator = gpa,
        .global_c_allocator = global_c_allocator,
        .temp_allocator = std.heap.ArenaAllocator.init(gpa),
        .platform = startup.platform,
        .icon = icon,
        .icon_red = icon_red,
        .icon_flash_timer = try Timer.start(),
        .window = null,
        .has_tray_support = has_tray_support,
        .tray = null,
        .user_settings = user_settings,
        .activity_timer = try Timer.start(),
        .process_list = undefined, // Init after
        .process_check_timer = try Timer.start(),
        .ui = .{
            .ui_allocator = std.heap.ArenaAllocator.init(gpa),
            .timer = undefined,
            .options = undefined,
            .options_metadata = undefined,
        },
    };

    // setup process list
    try app.process_list.init();

    // setup main application window
    app.window = blk: {
        const main_app_window = try gpa.create(Window);
        main_app_window.* = try Window.init(.{
            .title = App.Name,
            // .size = .windowed_halfscreen,
            .width = 680,
            .height = 480,
            .resizeable = true,
            .icon = app.icon.surface,
        });
        break :blk main_app_window;
    };

    // setup tray
    if (app.has_tray_support) {
        app.tray = sdl.SDL_CreateTray(app.icon.surface, App.Name) orelse blk: {
            const err = sdl.SDL_GetError();
            if (err != null) {
                log.err("unable to initialize SDL tray: {s}", .{err});
                return error.SdlFailed;
            }
            break :blk null;
        };
    }

    // initialize tray
    if (app.tray) |tray| {
        const tray_menu: *sdl.SDL_TrayMenu = sdl.SDL_CreateTrayMenu(tray) orelse {
            log.err("unable to initialize SDL tray menu: {s}", .{sdl.SDL_GetError()});
            return error.SdlFailed;
        };
        if (sdl.SDL_InsertTrayEntryAt(tray_menu, -1, "Open", sdl.SDL_TRAYENTRY_BUTTON)) |tray_entry| {
            sdl.SDL_SetTrayEntryCallback(tray_entry, struct {
                pub fn callback(app_ptr: ?*anyopaque, _: ?*sdl.SDL_TrayEntry) callconv(.c) void {
                    const app_in_tray: *App = @ptrCast(@alignCast(app_ptr));
                    app_in_tray.has_opened_from_tray = true;
                }
            }.callback, app);
        }
        if (sdl.SDL_InsertTrayEntryAt(tray_menu, -1, "Quit", sdl.SDL_TRAYENTRY_BUTTON)) |tray_entry| {
            sdl.SDL_SetTrayEntryCallback(tray_entry, struct {
                pub fn callback(app_ptr: ?*anyopaque, _: ?*sdl.SDL_TrayEntry) callconv(.c) void {
                    const app_in_tray: *App = @ptrCast(@alignCast(app_ptr));
                    app_in_tray.has_tray_quit = true;
                }
            }.callback, app);
        }
    }

    // If using Linux and X11, then setup that we have global mouse support
    if (comptime builtin.os.tag == .linux and !builtin.abi.isAndroid()) {
        const video_driver_c = sdl.SDL_GetCurrentVideoDriver();
        if (video_driver_c != null) {
            const video_driver = std.mem.span(sdl.SDL_GetCurrentVideoDriver());
            if (std.mem.eql(u8, video_driver, "x11")) {
                app.has_global_mouse_support = true;
            }
        }
    }

    // Setup Wayland if available for checking input idle notifications
    if (wayland.available) try wayland.init();
    errdefer if (wayland.available) wayland.deinit();

    if (!app.has_global_mouse_support) {
        // NOTE(jae): 2025-12-28
        // Hack, if the user has no global mouse support, then assume they are always active
        // at their computer.
        //
        // For Wayland, it'd be ideal we could use the 'ext_idle_notifier' protocol instead
        // See: https://wayland.app/protocols/ext-idle-notify-v1
        //
        // However, for now Bazzite supports x11, so we default to that.
        app.is_user_active = true;
    } else {
        // Setup initial "previous mouse position"
        _ = sdl.SDL_GetGlobalMouseState(&app.prev_mouse_pos.x, &app.prev_mouse_pos.y);
    }
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
    app.taking_break_windows.deinit(allocator);
    if (app.tray) |tray| {
        sdl.SDL_DestroyTray(tray);
    }
    app.process_list.deinit();
    app.icon_red.deinit(allocator);
    app.icon.deinit(allocator);
    app.user_settings.deinit(allocator);
    allocator.destroy(app.user_settings);
    app.temp_allocator.deinit();
    app.platform.deinit();
    app.global_c_allocator.deinit();
    app.* = undefined;
}

pub fn onEvent(sdl_event: *const sdl.SDL_Event, app: *App) !void {
    // process events for each ImGui
    var want_capture_mouse: bool = false;
    var want_capture_keyboard: bool = false;
    {
        if (app.window) |window| {
            imgui.igSetCurrentContext(window.imgui_context);
            _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(sdl_event));

            const io = &imgui.igGetIO_ContextPtr(window.imgui_context)[0];
            want_capture_mouse = want_capture_mouse or io.WantCaptureMouse;
            want_capture_keyboard = want_capture_keyboard or io.WantCaptureKeyboard;
        }
        for (app.popup_windows.items) |*window| {
            imgui.igSetCurrentContext(window.imgui_context);
            _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(sdl_event));

            const io = &imgui.igGetIO_ContextPtr(window.imgui_context)[0];
            want_capture_mouse = want_capture_mouse or io.WantCaptureMouse;
            want_capture_keyboard = want_capture_keyboard or io.WantCaptureKeyboard;
        }
        for (app.taking_break_windows.items) |*window| {
            imgui.igSetCurrentContext(window.imgui_context);
            _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(sdl_event));

            const io = &imgui.igGetIO_ContextPtr(window.imgui_context)[0];
            want_capture_mouse = want_capture_mouse or io.WantCaptureMouse;
            want_capture_keyboard = want_capture_keyboard or io.WantCaptureKeyboard;
        }
    }

    switch (sdl_event.type) {
        sdl.SDL_EVENT_QUIT => {
            // If triggered quit, close entire app
            try de.quit();
        },
        sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
            const event = sdl_event.window;
            if (app.window) |app_window| {
                if (event.windowID == sdl.SDL_GetWindowID(app_window.window)) {
                    try de.quit();
                    // TODO: Add ability to configure when/how we minimize to system tray
                    // If closed the main app window and has no system tray, close entire app
                    // if (app.tray == null) {
                    //     de.quit();
                    // } else {
                    //     app.minimize_to_tray = true;
                    // }
                }
            }
        },
        sdl.SDL_EVENT_WINDOW_RESTORED, sdl.SDL_EVENT_MOUSE_MOTION => {
            app.frames_without_app_input = 0;
        },
        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const event = sdl_event.button;
            if (event.down) {
                app.frames_without_app_input = 0;
            }
        },
        sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
            const event = sdl_event.button;
            if (!event.down) {
                app.frames_without_app_input = 0;
            }
            switch (event.button) {
                sdl.SDL_BUTTON_LEFT => {
                    // Ignore mouse release events that can affect ImGui layout
                    // ie. 'held_down_timer = null' can re-layout ImGui so pressing "Snooze" wont take.
                    if (!want_capture_mouse) {
                        // event.state == sdl.SDL_RELEASED
                        if (!event.down) {
                            if (app.break_mode.held_down_timer != null) {
                                app.break_mode.held_down_timer = null;
                            }
                        }
                    }
                },
                else => {},
            }
        },
        sdl.SDL_EVENT_KEY_UP => {
            const event = sdl_event.key;
            if (event.down) {
                app.frames_without_app_input = 0;
            }

            switch (event.key) {
                sdl.SDLK_ESCAPE => {
                    // Ignore keyboard release events that can affect ImGui layout
                    // ie. 'held_down_timer = null' can re-layout ImGui so pressing "Snooze" wont take.
                    if (!want_capture_keyboard) {
                        // event.state == sdl.SDL_RELEASED
                        if (!event.down) {
                            // If released reset the held down timer
                            if (app.break_mode.held_down_timer == null) {
                                app.break_mode.held_down_timer = try Timer.start();
                            }
                        }
                    }
                    app.break_mode.esc_or_exit_presses += 1;
                },
                else => {},
            }
        },
        else => {},
    }
}

pub fn onIterate(app: *App) !void {
    // Has processed quit from system tray
    if (app.has_tray_quit) try de.quit();

    const allocator = app.allocator;
    _ = app.temp_allocator.reset(.retain_capacity);

    // Set new ImGui Frame *after* event polling, otherwise you get rare instances of sticky buttons / interactivity
    // (as per example code: https://github.com/ocornut/imgui/blob/master/examples/example_sdl2_sdlrenderer2/main.cpp)
    {
        for (app.popup_windows.items) |*window| {
            window.imguiNewFrame();
        }
        for (app.taking_break_windows.items) |*window| {
            window.imguiNewFrame();
        }
        if (app.window) |app_window| {
            app_window.imguiNewFrame();
        }
    }

    // process Wayland events
    if (wayland.available) try wayland.processEvents();

    // NOTE(jae): 2026-01-18
    // Used to test other platforms
    //
    // defer app.debug_frame_count += 1;
    // if (app.debug_frame_count > 10) {
    //     @panic("hey");
    // }

    const current_frame_time = sdl.SDL_GetPerformanceCounter();

    // Handle tray logic
    if (app.has_opened_from_tray) {
        app.has_opened_from_tray = false;

        if (app.window) |app_window| {
            if (!sdl.SDL_RestoreWindow(app_window.window)) return error.SdlFailed;
        } else {
            // If no app window exists, create it
            app.window = blk: {
                const app_window = try allocator.create(Window);
                app_window.* = try Window.init(.{
                    .title = App.Name,
                    .width = 680,
                    .height = 480,
                    .resizeable = true,
                    .icon = app.icon.surface,
                });
                break :blk app_window;
            };
            app.frames_without_app_input = 0;
        }
    }
    if (app.minimize_to_tray) {
        app.minimize_to_tray = false;
        if (app.window) |app_window| {
            app_window.deinit();
            allocator.destroy(app_window);
            app.window = null;
        }
    }

    // Threshold to have responsive event polling based on:
    // - Wait N frames before we do WaitEvent so that the initial rendering sets things up nicely
    // - Wait N frames after keyboard presses for responsiveness
    {
        // If minimized, increase the wait event delay to be even more power-saving
        app.platform.wait_timeout = waitblk: {
            // If below threshold, poll events, otherwise wait with timeout then collect subsequent events
            // with a poll
            if (app.frames_without_app_input < FrameWithoutInputThreshold) {
                break :waitblk 0;
            }

            const is_main_window_minimized_or_occluded = blk: {
                const app_window = app.window orelse break :blk false;
                const window_flags = sdl.SDL_GetWindowFlags(app_window.window);
                break :blk (window_flags & sdl.SDL_WINDOW_MINIMIZED != 0) or
                    (window_flags & sdl.SDL_WINDOW_OCCLUDED != 0);
            };

            const is_powersaving_mode = is_main_window_minimized_or_occluded and
                app.popup_windows.items.len == 0 and
                app.taking_break_windows.items.len == 0;
            if (is_powersaving_mode) {
                if (app.time_till_next_timer_complete()) |timer| {
                    const safe_delay_in_ms: u64 = 5000;
                    const safe_delay = app.user_settings.incoming_break_or_default().nanoseconds + (safe_delay_in_ms * time.ns_per_ms);
                    if (timer.time_till_next_break.nanoseconds >= safe_delay) {
                        // 5000ms timeout so we can at least occassionally detect global mouse position
                        break :waitblk safe_delay_in_ms;
                    }
                }
            }
            break :waitblk 500; // Milliseconds
        };
        if (app.frames_without_app_input < FrameWithoutInputThreshold) {
            app.frames_without_app_input += 1;
        }
        // log.info("frames without input: {}, wait timeout: {}", .{ app.frames_without_app_input, app.platform.wait_timeout });
    }

    // If we have a system tray and the user snoozed, then icon is set to be flashing at an interval
    if (app.tray) |tray| {
        const debug_blink_always_on = false;
        if (debug_blink_always_on and app.icon_flash_timer == null) {
            app.icon_flash_timer = try Timer.start();
        }

        // Disable timer if started but we should halt it
        if (!debug_blink_always_on and
            app.icon_flash_timer != null and
            (app.snooze_times_in_a_row == 0 or app.mode == .taking_break))
        {
            if (app.tray_icon != .default) {
                sdl.SDL_SetTrayIcon(tray, app.icon.surface);
                app.tray_icon = .default;
            }
            app.icon_flash_timer = null;
        }

        // Handle timer
        if (app.icon_flash_timer) |*icon_flash_timer| {
            if (icon_flash_timer.read() >= 2 * time.ns_per_s) {
                switch (app.tray_icon) {
                    .default => {
                        sdl.SDL_SetTrayIcon(tray, app.icon_red.surface);
                        app.tray_icon = .red;
                    },
                    .red => {
                        sdl.SDL_SetTrayIcon(tray, app.icon.surface);
                        app.tray_icon = .default;
                    },
                }
                app.icon_flash_timer = try Timer.start();
            }
        }

        // If we should toggle/flash icon
        if (app.icon_flash_timer == null and
            app.snooze_times_in_a_row == 0 and app.mode != .taking_break)
        {
            // If snoozed, then start flashing timer
            app.icon_flash_timer = try Timer.start();
        }
    }

    // Check process list every N seconds
    if (ProcessList.is_supported and
        app.process_check_timer.read() >= 5 * time.ns_per_s)
    {
        // Reset timer
        app.process_check_timer.reset();

        // Check each process
        var pl = &app.process_list;
        try pl.open(app.temp_allocator.allocator(), app.io);
        defer pl.close();
        const has_process_running_that_should_halt_activity_timer = procblk: {
            while (try pl.next()) |entry| {
                const filepath = entry.exe_filepath;
                const jar_arguments = entry.jar_arguments;

                // Debug process name
                // if (jar_filepaths.len > 0)
                //     log.info("java process: {s}", .{entry.jar_filepaths})
                // else
                //     log.info("process: {s}", .{entry.exe_filepath});

                // By default disallow any application launched from the Steam directory
                //
                // This pattern covers both the default folder and additional folders
                // - Default:               C:/Steam/steamapps/common/Expedition 33
                // - Custom Additional HDD: D:/SteamLibrary/steamapps/common/Among Us
                if (std.mem.indexOfPos(u8, filepath, 0, "/steamapps/common/") != null) {
                    // Current app matches a Steam application
                    var has_match = true;

                    // Steam has tools as well, so we have a whitelist to allow various tools/servers/etc
                    const steamapps_allow_contains_list = [_][]const u8{
                        // Source SDK
                        "/steamapps/common/SourceSDK",
                        // VR
                        "/steamapps/common/SteamVR",
                        "/steamapps/common/OVR Toolkit",
                        "/steamapps/common/OVR_AdvancedSettings",
                        // Game Engine / Tools
                        "/steamapps/common/gamemaker_studio",
                        "/steamapps/common/Substance 3D Designer 2022",
                        // Dedicated Servers
                        "/steamapps/common/PalServer",
                        // - /steamapps/common/Project Zomboid Dedicated Server
                        // - /steamapps/common/Source 2007 Dedicated Server
                        // - /steamapps/common/Left 4 Dead 2 Dedicated Server
                        // - /steamapps/common/Age of Chivalry Dedicated Server
                        " Dedicated Server",
                        // Dedicated Servers
                        // - steamapps/common/SatisfactoryDedicatedServer
                        "DedicatedServer",
                        // Chivalry Dedicated Servers
                        // - steamapps/common/chivalry_ded_server
                        // - steamapps/common/chivalry_dw_ded_server
                        "_ded_server",
                        // Game Modding
                        "/steamapps/common/Automation_SDK",
                        "/steamapps/common/RustSDK",
                        "/steamapps/common/Project Zomboid Modding Tools",
                        "/left 4 dead 2/bin/", // ie. /bin/hammer.exe, /bin/hlfaceposer.exe, root directory of "left 4 dead 2" has the actual exe
                        // Games (UI heavy, interruption won't cause game over states)
                        "/steamapps/common/Automation",
                    };
                    for (steamapps_allow_contains_list) |allow_contains| {
                        has_match = has_match and std.mem.indexOfPos(u8, filepath, 0, allow_contains) == null;
                    }
                    if (has_match) {
                        break :procblk true;
                    }
                }

                // Check Minecraft Launcher games
                {
                    var has_match = false;
                    const minecraft_launcher_disallow_contains_list = [_][]const u8{
                        "/Minecraft", // Java Edition, from main launcher: C:/Program Files/WindowsApps/Microsoft.4297127D64EC6_2.5.2.0_x64__8wekyb3d8bbwe/Minecraft.exe
                        "/Minecraft.Windows", // Bedrock Edition, from main launcher: C:/Program Files/WindowsApps/MICROSOFT.MINECRAFTUWP_1.21.13101.0_x64__8wekyb3d8bbwe/Minecraft.Windows.exe
                    };
                    for (minecraft_launcher_disallow_contains_list) |disallow_contains| {
                        has_match = has_match or std.mem.indexOfPos(u8, filepath, 0, disallow_contains) != null;
                    }
                    if (jar_arguments.len > 0) {
                        const minecraft_jar_disallow_contains_list = if (builtin.os.tag == .windows)
                            [_][]const u8{
                                "\\libraries\\com\\mojang\\", // Java Edition, from regular/terrible launcher (2025): C:\Users\Jae\AppData\Roaming\.minecraft\libraries\com\mojang\brigadier\1.3.10\brigadier-1.3.10.jar
                            }
                        else
                            [_][]const u8{
                                "/libraries/com/mojang/", // Java Edition, from Prism Launcher on Linux/Bazzite: /var/home/USER/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/libraries/com/mojang/minecraft/1.21.11/minecraft-1.21.11-client.jar"
                            };
                        for (minecraft_jar_disallow_contains_list) |disallow_jar_contains| {
                            has_match = has_match or std.mem.indexOfPos(u8, jar_arguments, 0, disallow_jar_contains) != null;
                        }
                    }
                    if (has_match) {
                        // Exclude processes like the Minecraft Launcher itself
                        const minecraft_launcher_allow_contains_list = [_][]const u8{
                            "/Minecraft Launcher/Content", // Windows
                            "/minecraft-launcher", // Linux, /var/home/jae/.minecraft/launcher/minecraft-launcher
                        };
                        for (minecraft_launcher_allow_contains_list) |allow_contains| {
                            has_match = has_match and std.mem.indexOfPos(u8, filepath, 0, allow_contains) == null;
                        }
                        if (has_match) {
                            break :procblk true;
                        }
                    }
                }

                // Check misc Java applications
                if (jar_arguments.len > 0) {
                    const jar_disallow_contains_list = [_][]const u8{
                        // Starsector
                        "com.fs.starfarer", // -Dcom.fs.starfarer.settings.paths.saves=..\\saves -Dcom.fs.starfarer.settings.paths.screenshots=..\\screenshots -Dcom.fs.starfarer.settings.paths.mods=..\\mods -Dcom.fs.starfarer.settings.paths.logs=. -classpath janino.jar;commons-compiler.jar;commons-compiler-jdk.jar;starfarer.api.jar;starfarer_obf.jar;jogg-0.0.7.jar;jorbis-0.0.15.jar;json.jar;lwjgl.jar;jinput.jar;log4j-1.2.9.jar;lwjgl_util.jar;fs.sound_obf.jar;fs.common_obf.jar;xstream-1.4.10.jar;txw2-3.0.2.jar;jaxb-api-2.4.0-b180830.0359.jar;webp-imageio-0.1.6.jar com.fs.starfarer.StarfarerLauncher
                    };
                    var has_match = false;
                    for (jar_disallow_contains_list) |disallow_jar_contains| {
                        has_match = has_match or std.mem.indexOfPos(u8, jar_arguments, 0, disallow_jar_contains) != null;
                    }
                    if (has_match) {
                        break :procblk true;
                    }
                }

                // Check misc applications
                {
                    const disallow_contains_list_os = if (comptime builtin.os.tag == .linux)
                        [_][]const u8{
                            "/dolphin-emu", // Gamecube/Wii emulator. Linux/Flatpak, /app/bin/dolphin-emu
                        }
                    else
                        [_][]const u8{
                            "/Dolphin", // Gamecube/Wii emulator. Don't exclude on Linux by default as it has a File Explorer called Dolphin
                        };
                    const disallow_contains_list = [_][]const u8{
                        // Emulation
                        "/retroarch",
                        "/duckstation-", // ie. duckstation-qt-x64-ReleaseLTCG.exe
                        "/ePSXe",
                        "/pcsxr",
                        "/mednafen",
                        "/fceux",
                        "/mGBA",
                        "/mupen64plus",
                        "/bsnes",
                        "/snes9x",
                        "/VisualBoyAdvance",
                        "/Cemu",
                        "/shadPS4", // ie. shadPS4QtLauncher.exe
                        "/Ryujinx",
                        "/xemu",
                        "/xenia",
                        // SteamVR on Linux
                        "/vrserver",
                        // Games
                        "/HytaleClient",
                        "/soh", // Ship of Harkinian
                        "/BarkleyV120",
                        "/AgosClient",
                        "/Bubsy3d",
                    } ++ disallow_contains_list_os;

                    var has_match = false;
                    for (disallow_contains_list) |disallow_contains| {
                        has_match = has_match or std.mem.indexOfPos(u8, filepath, 0, disallow_contains) != null;
                    }
                    if (has_match) {
                        break :procblk true;
                    }
                }
            }
            break :procblk false;
        };
        if (has_process_running_that_should_halt_activity_timer) {
            if (!app.is_game_active) {
                app.is_game_active = true;
            }
        } else {
            if (app.is_game_active) {
                if (app.user_settings.settings.is_activity_break_enabled) {
                    const time_till_next_break = app.user_settings.time_till_break_or_default().diff(app.activity_timer.read());
                    // TODO: Make activity timer give 2 minute interval instead of just resetting if below 2 mins
                    if (time_till_next_break.nanoseconds <= 120 * time.ns_per_s) {
                        app.activity_timer.reset();
                        app.snooze_activity_break_timer = null;
                    }
                }
                app.is_game_active = false;
            }
        }
    }

    // Detect activity and handle timers to pop-up break window
    {
        const idle_state = wayland.idleState();
        switch (idle_state) {
            .unknown => {
                if (app.has_global_mouse_support) {
                    // Detect global mouse movement
                    var curr_mouse_pos: de.Vector2f = undefined;
                    _ = sdl.SDL_GetGlobalMouseState(&curr_mouse_pos.x, &curr_mouse_pos.y);
                    const diff: de.Vector2f = .{
                        .x = @abs(curr_mouse_pos.x - app.prev_mouse_pos.x),
                        .y = @abs(curr_mouse_pos.y - app.prev_mouse_pos.y),
                    };
                    app.prev_mouse_pos = curr_mouse_pos;
                    if (diff.x >= 5 and
                        diff.y >= 5)
                    {
                        app.time_since_last_input = try Timer.start();
                        app.is_user_active = true;
                        // log.info("mouse moved: {}, {}", .{ curr_mouse_pos.x, curr_mouse_pos.y });
                    }
                }
            },
            .idle => {
                // do nothing if idling
            },
            .resumed => {
                app.time_since_last_input = try Timer.start();
                app.is_user_active = true;
            },
        }
        if (app.mode == .regular) {
            if (app.time_since_last_input) |*time_since_last_input| {
                // TODO: Make inactivity time a variable
                const inactivity_duration = 4 * std.time.ns_per_min;
                if (time_since_last_input.read() > inactivity_duration) {
                    app.is_user_active = false;
                    app.activity_timer.reset();
                }
            } else {
                app.activity_timer.reset();
                app.is_user_active = false;
            }
        }

        // Detect when to change mode
        switch (app.mode) {
            .regular, .incoming_break => {
                if (app.time_till_next_timer_complete()) |next_timer| {
                    if (next_timer.time_till_next_break.nanoseconds <= 0) {
                        const computer_was_in_sleep_mode = blk: {
                            // If it's an activity timer or sleep timer and the difference in time
                            // is over N seconds in the past, assume the computer was in sleep mode for a long
                            // period of time and ignore the break logic.
                            if (next_timer.id == .activity_timer or next_timer.id == .snooze_timer) {
                                if (next_timer.time_till_next_break.nanoseconds <= -180 * time.ns_per_s) {
                                    break :blk true;
                                }
                            }
                            break :blk false;
                        };
                        if (!computer_was_in_sleep_mode) {
                            try app.change_mode(.taking_break);
                        } else {
                            app.activity_timer.reset();
                            app.snooze_activity_break_timer = null;
                        }
                    } else if (next_timer.time_till_next_break.nanoseconds <= app.user_settings.incoming_break_or_default().nanoseconds) {
                        try app.change_mode(.incoming_break);
                    } else {
                        // If cancelled timer in main window
                        if (app.mode == .incoming_break) {
                            try app.change_mode(.regular);
                        }
                    }
                } else {
                    if (app.mode == .incoming_break) {
                        // If we somehow got in this buggy state and there is no next break
                        // then switch to regular mode
                        try app.change_mode(.regular);
                    }
                }
            },
            .taking_break => {
                const time_active_in_ns = app.break_mode.timer.read();
                const time_till_break_over = app.break_mode.duration.diff(time_active_in_ns);
                if (time_till_break_over.nanoseconds <= 0) {
                    app.snooze_times_in_a_row = 0;
                    try app.change_mode(.regular);
                }
            },
        }
    }

    // Main application window
    if (app.window) |app_window| appwindowblk: {
        imgui.igSetCurrentContext(app_window.imgui_context);

        const viewport = @as(?*imgui.ImGuiViewport, imgui.igGetMainViewport()) orelse {
            break :appwindowblk; // If no viewport skip
        };
        imgui.igSetNextWindowPos(viewport.Pos, imgui.ImGuiCond_None, .{});
        imgui.igSetNextWindowSize(viewport.Size, imgui.ImGuiCond_None);
        if (!imgui.igBegin("###mainwindow", null, App.ImGuiDefaultWindowFlags)) {
            break :appwindowblk;
        }
        defer imgui.igEnd();

        // DEBUG: Open metrics window
        // var open = true;
        // imgui.igShowMetricsWindow(&open);

        // Heading
        {
            const uiHeadingButton = struct {
                pub fn uiHeadingButton(label: [:0]const u8, is_selected: bool) bool {
                    if (is_selected) {
                        const activeColor = imgui.igGetStyleColorVec4(imgui.ImGuiCol_ButtonActive)[0];
                        imgui.igPushStyleColor_Vec4(imgui.ImGuiCol_Button, activeColor);
                        imgui.igPushStyleColor_Vec4(imgui.ImGuiCol_ButtonHovered, activeColor);
                    }
                    const r = imgui.igButton(label, .{});
                    if (is_selected) {
                        imgui.igPopStyleColor(2);
                    }
                    imgui.igSameLine(0, 4);
                    return r;
                }
            }.uiHeadingButton;

            var maybe_next_ui_screen: ?App.Screen = null;

            if (uiHeadingButton("Overview", app.ui.screen == .overview)) {
                maybe_next_ui_screen = .overview;
            }

            const has_selected_add_or_edit_timer = app.ui.screen == .timer;
            const add_edit_timer: [:0]const u8 = if (!has_selected_add_or_edit_timer or app.ui.timer.id == -1)
                "Add Timer"
            else
                "Edit Timer";
            if (uiHeadingButton(add_edit_timer, has_selected_add_or_edit_timer)) {
                maybe_next_ui_screen = .timer;
            }
            if (uiHeadingButton("Options", app.ui.screen == .options)) {
                maybe_next_ui_screen = .options;
            }
            if (uiHeadingButton("Take a break", false)) {
                try app.change_mode(.taking_break);
            }
            if (app.tray) |_| {
                if (uiHeadingButton("Minimize to tray", false)) {
                    app.minimize_to_tray = true;
                }
            }
            imgui.igNewLine();
            imgui.igSeparatorEx(imgui.ImGuiSeparatorFlags_Horizontal, 2);
            if (maybe_next_ui_screen) |next_ui_screen| uiblk: {
                // do nothing if same
                if (app.ui.screen == next_ui_screen) {
                    break :uiblk;
                }
                switch (next_ui_screen) {
                    .overview => {
                        // no state to reset
                    },
                    .timer => {
                        ScreenAddEditTimer.open(app);
                    },
                    .options => {
                        try ScreenOptions.open(app);
                    },
                }
                app.ui.screen = next_ui_screen;
            }
        }

        switch (app.ui.screen) {
            .overview => {
                try ScreenOverview.render(app);
            },
            .timer => {
                try ScreenAddEditTimer.render(app);
            },
            .options => {
                try ScreenOptions.render(app);
            },
        }
    }

    // Render Incoming break popup(s)
    try ScreenIncomingBreak.render(app);

    // Taking break windows
    try ScreenTakingBreak.render(app);

    // NOTE(jae): 2024-07-28
    // May want to disable this logic if using vsync
    const total_frame_time = sdl.SDL_GetPerformanceCounter() - current_frame_time;
    const total_frame_time_in_ms = 1000.0 * (@as(f64, @floatFromInt(total_frame_time)) / @as(f64, @floatFromInt(sdl.SDL_GetPerformanceFrequency())));
    const tick_rate: u64 = 60; // assume 60 FPS always
    const tick_rate_in_ms: f64 = 1000 / tick_rate;
    const time_to_delay_for = @floor(tick_rate_in_ms - total_frame_time_in_ms);
    if (time_to_delay_for >= 1) {
        const delay = @as(u32, @intFromFloat(time_to_delay_for));
        // std.debug.print("delay amount: {}, tick rate in ms: 0.{d}\n", .{ delay, @as(u64, @intFromFloat(total_frame_time_in_ms * 100)) });
        sdl.SDL_Delay(delay);
    }

    // Render
    const renderWindow = struct {
        pub fn renderWindow(window: *Window) void {
            const renderer = window.renderer;

            // Setup ImGui Context + Render Scale
            assert(window.imgui_new_frame);
            imgui.igSetCurrentContext(window.imgui_context);
            imgui.igRender();
            const io = &imgui.igGetIO_ContextPtr(imgui.igGetCurrentContext())[0];
            _ = sdl.SDL_SetRenderScale(renderer, io.DisplayFramebufferScale.x, io.DisplayFramebufferScale.y);

            // Clear screen
            _ = sdl.SDL_SetRenderDrawColor(renderer, 20, 20, 20, 0);
            _ = sdl.SDL_RenderClear(renderer);

            // Render ImGui Draw Calls
            imgui.ImGui_ImplSDLRenderer3_RenderDrawData(@ptrCast(imgui.igGetDrawData()), @ptrCast(window.renderer));
            window.imgui_new_frame = false;

            if (!sdl.SDL_RenderPresent(renderer)) {
                // TODO: Handle not rendering?
                @panic("SDL_RenderPresent failed for main application window");
            }
        }
    }.renderWindow;

    // Render app window
    if (app.window) |app_window| {
        renderWindow(app_window);
    }
    for (app.popup_windows.items) |*incoming_break_window| {
        renderWindow(incoming_break_window);
    }
    for (app.taking_break_windows.items) |*taking_break_window| {
        renderWindow(taking_break_window);
    }
}

pub fn onQuit(_: *App) !void {}

/// tprint will allocate temporary text into a buffer that will stop existing next render frame
pub fn tprint(self: *App, comptime fmt: []const u8, args: anytype) error{OutOfMemory}![:0]u8 {
    return std.fmt.allocPrintSentinel(self.temp_allocator.allocator(), fmt, args, 0);
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
        if (app.is_game_active) {
            can_trigger_activity_break = false;
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

const SnoozeState = enum {
    can_snooze,
    cannot_snooze_max_snoozes_exceeded,
    cannot_snooze_is_timer_or_alarm,
};

pub fn snoozeCondition(app: *App) SnoozeState {
    // Disallow snooze button if hit max snooze limit
    const max_snoozes_in_a_row = app.user_settings.max_snoozes_in_a_row_or_default();
    if (max_snoozes_in_a_row != UserConfig.Settings.MaxSnoozesDisabled and
        app.snooze_times_in_a_row >= max_snoozes_in_a_row)
    {
        return .cannot_snooze_max_snoozes_exceeded;
    }

    // If it was an alarm or timer, disallow snoozing
    if (app.has_timer_or_alarm_triggered()) {
        return .cannot_snooze_is_timer_or_alarm;
    }

    return .can_snooze;
}

fn has_timer_or_alarm_triggered(app: *App) bool {
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
    const is_snoozeable: bool = app.snoozeCondition() == .can_snooze;
    assert(is_snoozeable);
    if (!is_snoozeable) {
        return;
    }

    // reset activity timer
    app.activity_timer.reset();
    app.snooze_activity_break_timer = Timer.start() catch unreachable;
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
                        if (diff.nanoseconds <= 0) {
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

                const width: u16 = 200;
                const height: u16 = 200;

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
                    // NOTE(jae): 2025-12-27
                    // Attempt to have the *audacity* on my own computer to get a
                    // a window to pop up in the right-bottom corner of the screen with Wayland (and fail)
                    // (Tried to use Wayland Popup Windows to do this)
                    // .parent = app.window,
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
            const display: Window.Rect = Window.getDisplayUsableBoundsFromIndex(display_index) orelse .{
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
                .timer = Timer.start() catch unreachable,
                .duration = break_time_duration,
                // reset escape presses / etc
            };
        },
    }
    app.mode = new_mode;
}

const TrayIconMode = enum {
    default,
    red,
};

const App = @This();
