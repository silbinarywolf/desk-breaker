const std = @import("std");
const builtin = @import("builtin");
const time = std.time;
const mem = std.mem;

const sdl = @import("sdl");
const imgui = @import("imgui");

const UserConfig = @import("userconfig.zig").UserConfig;
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
    pub fn max_snoozes_in_a_row_or_default(self: *const @This()) u32 {
        return self.settings.max_snoozes_in_a_row orelse 3;
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
    window_state: WindowState = .{},

    allocator: std.mem.Allocator,
    /// stores printed text per-frame and other temporary things
    temp_allocator: std.heap.ArenaAllocator,

    icon: *sdl.SDL_Surface,

    // Windows

    /// main application window
    window: *Window,
    popup_windows: std.ArrayListUnmanaged(Window) = .{},
    taking_break_windows: std.ArrayListUnmanaged(Window) = .{},

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
    ui: UiState = .{},

    pub fn deinit(state: *State) void {
        for (state.popup_windows.items) |*window| {
            window.deinit();
        }
        state.popup_windows.deinit(state.allocator);
        for (state.taking_break_windows.items) |*window| {
            window.deinit();
        }
        state.taking_break_windows.deinit(state.allocator);
        // NOTE(jae): 2024-11-15: user_settings is freed outside of this
        // state.user_settings.deinit(state.allocator);
        state.temp_allocator.deinit();
    }

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
                        if (state.user_settings.settings.is_activity_break_enabled) {
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
        // Disallow snooze button if hit max snooze limit
        const max_snoozes_in_a_row = state.user_settings.max_snoozes_in_a_row_or_default();
        if (max_snoozes_in_a_row > 0 and state.snooze_times_in_a_row >= max_snoozes_in_a_row) {
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
        state.snooze_times_in_a_row += 1;
    }

    pub fn change_mode(state: *State, new_mode: Mode) !void {
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
                const should_change_state = blk: {
                    const display_index = state.user_settings.settings.display_index;

                    // Don't work if we can't get display dimensions
                    var display: sdl.SDL_Rect = undefined;
                    if (!sdl.SDL_GetDisplayUsableBounds(getDisplayIdFromIndex(display_index), &display)) {
                        log.err("incoming_break: unable to query display usable bounds: {s}", .{sdl.SDL_GetError()});
                        return error.SdlFailed;
                    }

                    const use_popout_window = true;
                    if (use_popout_window) {
                        const width: c_int = 200;
                        const height: c_int = 200;

                        const popup_window = Window.init(.{
                            .title = "Incoming Break",
                            .icon = state.icon,
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
                        try state.popup_windows.append(state.allocator, popup_window);
                    } else {
                        // Old deprecated code

                        const window = state.window.window;
                        // NOTE(jae): 2024-11-03
                        // Restore window logic should happen before we set the window size/etc otherwise ive seen an issue
                        RestoreWindow_NoActivateFocus(window); // unminimize it

                        _ = sdl.SDL_SetWindowResizable(window, false);
                        _ = sdl.SDL_SetWindowBordered(window, false);

                        const width: c_int = 200;
                        const height: c_int = 200;
                        _ = sdl.SDL_SetWindowSize(window, width, height);
                        _ = sdl.SDL_SetWindowPosition(window, display.x + display.w - width, display.y + display.h - height);
                        _ = sdl.SDL_SetWindowAlwaysOnTop(window, true); // where the window doesn't move position and size doesn't change in SDL3
                    }
                    break :blk true;
                };
                if (!should_change_state) {
                    // Don't change state if we can't query display
                    return;
                }
                // state.time_till_next_state.reset(); // Do not reset this for this case
            },
            .taking_break => {
                log.info("change_mode: taking break", .{});

                const use_popout_window = true;
                if (use_popout_window) {
                    const display_index = state.user_settings.settings.display_index;

                    // Don't work if we can't get display dimensions
                    var display: sdl.SDL_Rect = undefined;
                    if (!sdl.SDL_GetDisplayUsableBounds(getDisplayIdFromIndex(display_index), &display)) {
                        // Fallback if cannot query display
                        display.x = 0;
                        display.y = 0;
                        display.w = 640;
                        display.h = 480;
                    }

                    const taking_break_window = Window.init(.{
                        .title = "Take a break",
                        .icon = state.icon,
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
                    try state.taking_break_windows.append(state.allocator, taking_break_window);
                } else {
                    const display_index = state.user_settings.display_index;
                    const window = state.window;

                    _ = sdl.SDL_SetWindowResizable(window, false);
                    _ = sdl.SDL_SetWindowAlwaysOnTop(window, true);
                    _ = sdl.SDL_SetWindowBordered(window, false); // For Windows/Kbuntu, must be after SetWindowPosition/SetWindowSize

                    var display: sdl.SDL_Rect = undefined;
                    if (sdl.SDL_GetDisplayUsableBounds(getDisplayIdFromIndex(display_index), &display)) {
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

pub const WindowOptions = struct {
    title: [:0]const u8 = &[0:0]u8{},
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    resizeable: bool = false,
    focusable: bool = true,
    borderless: bool = false,
    always_on_top: bool = false,
    /// Starts window with grabbed mouse focus
    mouse_grabbed: bool = false,
    icon: ?*sdl.SDL_Surface = null,
};

pub const Window = struct {
    window: *sdl.SDL_Window,
    window_properties: u32,
    renderer: *sdl.SDL_Renderer,
    imgui_context: *imgui.ImGuiContext,
    imgui_font_atlas: *imgui.ImFontAtlas,

    pub fn init(options: WindowOptions) !@This() {
        const props = sdl.SDL_CreateProperties();
        if (props == 0) {
            log.err("SDL_CreateProperties failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlFailed;
        }
        errdefer sdl.SDL_DestroyProperties(props);

        if (options.title.len > 0) {
            if (!sdl.SDL_SetStringProperty(props, sdl.SDL_PROP_WINDOW_CREATE_TITLE_STRING, options.title)) return error.SdlSetPropertyFailed;
        }
        if (options.resizeable) {
            if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN, true)) return error.SdlSetPropertyFailed;
        }
        if (!options.focusable) {
            // SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, defaults to true
            if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, false)) return error.SdlSetPropertyFailed;
        }
        if (options.borderless) {
            // SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, defaults to true
            if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_BORDERLESS_BOOLEAN, true)) return error.SdlSetPropertyFailed;
        }
        if (options.always_on_top) {
            if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_ALWAYS_ON_TOP_BOOLEAN, true)) return error.SdlSetPropertyFailed;
        }
        if (options.mouse_grabbed) {
            if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_MOUSE_GRABBED_BOOLEAN, true)) return error.SdlSetPropertyFailed;
        }
        if (options.x) |x| {
            if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_X_NUMBER, x)) return error.SdlSetPropertyFailed;
        }
        if (options.y) |y| {
            if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_Y_NUMBER, y)) return error.SdlSetPropertyFailed;
        }
        if (options.width) |width| {
            if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, width)) return error.SdlSetPropertyFailed;
        }
        if (options.height) |height| {
            if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, height)) return error.SdlSetPropertyFailed;
        }

        const window = sdl.SDL_CreateWindowWithProperties(props) orelse {
            log.err("SDL_CreateWindowWithProperties failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlFailed;
        };
        if (options.icon) |icon| {
            if (!sdl.SDL_SetWindowIcon(window, icon)) {
                log.err("unable to set window icon: {s}", .{sdl.SDL_GetError()});
                return error.SDLFailed;
            }
        }
        // TODO(jae): 2024-08-20
        // Add option to use hardware accelerated instead
        const renderer: *sdl.SDL_Renderer = sdl.SDL_CreateRenderer(window, sdl.SDL_SOFTWARE_RENDERER) orelse {
            log.err("unable to create renderer: {s}", .{sdl.SDL_GetError()});
            return error.SDLFailed;
        };
        errdefer sdl.SDL_DestroyRenderer(renderer);

        // Reset to previous context after setup
        const previous_imgui_context = imgui.igGetCurrentContext();
        defer {
            if (previous_imgui_context) |prev_imgui_context| {
                imgui.igSetCurrentContext(prev_imgui_context);
            }
        }

        // NOTE(jae): 2024-11-07
        // Using embedded font data that isn't owned by the atlas
        var font_config = &imgui.ImFontConfig_ImFontConfig()[0];
        defer imgui.ImFontConfig_destroy(font_config);
        font_config.FontDataOwnedByAtlas = false;

        // NOTE(jae): 2024-06-11
        // Each context needs its own font atlas or issues occur with rendering
        const font_data = @embedFile("fonts/Lato-Regular.ttf");
        const imgui_font_atlas: *imgui.ImFontAtlas = imgui.ImFontAtlas_ImFontAtlas();
        errdefer imgui.ImFontAtlas_destroy(imgui_font_atlas);
        _ = imgui.ImFontAtlas_AddFontFromMemoryTTF(
            imgui_font_atlas,
            @constCast(@ptrCast(font_data[0..].ptr)),
            font_data.len,
            28,
            font_config,
            null,
        );

        const imgui_context = imgui.igCreateContext(imgui_font_atlas) orelse {
            log.err("unable to create imgui context: {s}", .{sdl.SDL_GetError()});
            return error.ImguiFailed;
        };
        errdefer imgui.igDestroyContext(imgui_context);

        // NOTE(jae): This call is needed for multiple windows, ie. creation of the second window
        imgui.igSetCurrentContext(imgui_context);

        const imgui_io = &imgui.igGetIO()[0];
        imgui_io.IniFilename = null; // disable imgui.ini
        imgui_io.IniSavingRate = -1; // disable imgui.ini

        _ = imgui.ImGui_ImplSDL3_InitForSDLRenderer(@ptrCast(window), @ptrCast(renderer));
        errdefer imgui.ImGui_ImplSDL3_Shutdown();

        _ = imgui.ImGui_ImplSDLRenderer3_Init(@ptrCast(renderer));
        errdefer imgui.ImGui_ImplSDLRenderer3_Shutdown();

        // If new context created that isn't the first, setup new frame
        if (previous_imgui_context != null) {
            imgui.ImGui_ImplSDLRenderer3_NewFrame();
            imgui.ImGui_ImplSDL3_NewFrame();
            imgui.igNewFrame();
        }

        // TODO(jae): 2024-11-07
        // Figure out how to force mouse onto break window
        // if (force_focus) {
        //     const oldActivateWhenRaised = sdl.SDL_GetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED);
        //     const oldActivateWhenShown = sdl.SDL_GetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN);
        //     const oldForceRaiseWindow = sdl.SDL_GetHint(sdl.SDL_HINT_FORCE_RAISEWINDOW);
        //     _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED, "1");
        //     _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "1");
        //     _ = sdl.SDL_SetHint(sdl.SDL_HINT_FORCE_RAISEWINDOW, "1");
        //
        //     _ = sdl.SDL_HideWindow(window);
        //     _ = sdl.SDL_ShowWindow(window);
        //
        //     defer {
        //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED, oldActivateWhenRaised);
        //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, oldActivateWhenShown);
        //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_FORCE_RAISEWINDOW, oldForceRaiseWindow);
        //     }
        // }

        return .{
            .window = window,
            .window_properties = props,
            .renderer = renderer,
            .imgui_context = imgui_context,
            .imgui_font_atlas = imgui_font_atlas,
        };
    }

    pub fn deinit(self: *Window) void {
        {
            const previous_imgui_context = imgui.igGetCurrentContext();
            defer {
                if (previous_imgui_context) |prev_imgui_context| {
                    imgui.igSetCurrentContext(prev_imgui_context);
                }
            }
            imgui.igSetCurrentContext(self.imgui_context);
            imgui.ImGui_ImplSDLRenderer3_Shutdown();
            imgui.ImGui_ImplSDL3_Shutdown();
        }
        imgui.igDestroyContext(self.imgui_context);
        imgui.ImFontAtlas_destroy(self.imgui_font_atlas);
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_DestroyProperties(self.window_properties);
        self.* = undefined;
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

    fn enter_incoming_break(self: *Window, display_index: u32) bool {
        // Don't work if we can't get display dimensions
        var display: sdl.SDL_Rect = undefined;
        if (!sdl.SDL_GetDisplayUsableBounds(getDisplayIdFromIndex(display_index), &display)) {
            return false;
        }
        const window = self.window;

        // NOTE(jae): 2024-11-03
        // Restore window logic should happen before we set the window size/etc otherwise ive seen an issue
        // where the window doesn't move position and size doesn't change in SDL3
        RestoreWindow_NoActivateFocus(window); // unminimize it

        _ = sdl.SDL_SetWindowResizable(window, false);
        _ = sdl.SDL_SetWindowBordered(window, false);

        const width: c_int = 200;
        const height: c_int = 200;
        _ = sdl.SDL_SetWindowSize(window, width, height);
        _ = sdl.SDL_SetWindowPosition(window, display.x + display.w - width, display.y + display.h - height);
        _ = sdl.SDL_SetWindowAlwaysOnTop(window, true);
        return true;
    }

    fn exit_break_mode(self: *Window) void {
        const window = self.window;

        _ = sdl.SDL_SetWindowMouseGrab(window, false); // free mouse lock from window
        _ = sdl.SDL_SetWindowKeyboardGrab(window, false); // lock keyboard to window

        _ = sdl.SDL_SetWindowAlwaysOnTop(window, false);
        _ = sdl.SDL_SetWindowBordered(window, true);
        _ = sdl.SDL_SetWindowResizable(window, true);
    }
};

fn getDisplayIdFromIndex(display_index: u32) sdl.SDL_DisplayID {
    var display_count: c_int = undefined;
    const display_list_or_err = sdl.SDL_GetDisplays(&display_count);
    if (display_list_or_err == null) {
        return 0;
    }
    defer sdl.SDL_free(display_list_or_err);
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
        // NOTE(jae): 2024-11-03
        // Issue on Windows where this takes focus unfortunately
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
