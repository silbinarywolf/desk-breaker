const std = @import("std");
const time = std.time;
const builtin = @import("builtin");
const sdl = @import("sdl");
const imgui = @import("imgui");
const android = @import("android");
const winregistry = @import("winregistry.zig");

const UserConfig = @import("userconfig.zig").UserConfig;

const sdlpng = @import("sdlpng.zig");
const CLibAllocation = @import("c_lib_alloc.zig").CLibAllocation;
const Duration = @import("time.zig").Duration;
const Alarm = @import("time.zig").Alarm;

const State = @import("state.zig").State;
const UserSettings = @import("state.zig").UserSettings;
const Window = @import("state.zig").Window;
const Timer = @import("state.zig").Timer;
const NextTimer = @import("state.zig").NextTimer;

const log = std.log.default;
const assert = std.debug.assert;

/// custom standard options for Android
pub const std_options: std.Options = if (builtin.abi == .android)
    .{
        .logFn = android.logFn,
    }
else
    .{};

/// custom panic handler for Android
pub const panic = if (builtin.abi == .android)
    android.panic
else
    std.builtin.default_panic;

/// This needs to be exported for Android builds
export fn SDL_main() callconv(.C) void {
    if (builtin.abi == .android) {
        _ = std.start.callMain();
    } else {
        @panic("SDL_main should not be called outside of Android builds");
    }
}

const MousePos = struct {
    x: f32,
    y: f32,

    pub fn diff(self: MousePos, other: MousePos) MousePos {
        return .{
            .x = @abs(self.x - other.x),
            .y = @abs(self.y - other.y),
        };
    }
};

const GPAConfig: std.heap.GeneralPurposeAllocatorConfig = .{
    // NOTE(jae): 2024-04-21
    // Safety is true for debug/releaseSafe builds
    // .safety = true,
    // Extra debugging options to avoid segfaults
    // .never_unmap = true,
    //.retain_metadata = true,
};

var gpa_allocator: std.heap.GeneralPurposeAllocator(GPAConfig) = .{};

pub fn main() !void {
    const allocator = gpa_allocator.allocator();
    defer {
        _ = gpa_allocator.deinit();
    }

    // Setup custom allocators for SDL and Imgui
    // - We can use the GeneralPurposeAllocator to catch memory leaks
    const c_lib_alloc = try CLibAllocation.init(allocator);
    defer c_lib_alloc.deinit();

    // Load your settings
    var user_settings: UserSettings = .{
        .settings = .{},
        .timers = std.ArrayList(Timer).init(allocator),
    };
    UserConfig.load(allocator, &user_settings) catch |err| switch (err) {
        error.FileNotFound => {
            // do nothing if there is no config file
        },
        else => return err,
    };

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        log.err("unable to initialize SDL: {s}", .{sdl.SDL_GetError()});
        return error.SDLInitializationFailed;
    }
    defer sdl.SDL_Quit();

    var icon_png = try sdlpng.load_from_surface_from_buffer(allocator, @embedFile("icon.png"));
    defer icon_png.deinit(allocator);

    var app_window = try Window.init(.{
        .title = "Desk Breaker",
        .width = 640,
        .height = 480,
        .resizeable = true,
        .icon = icon_png.surface,
    });
    defer app_window.deinit();

    // Setup initial "previous mouse position"
    var prev_mouse_pos: MousePos = .{ .x = 0, .y = 0 };
    _ = sdl.SDL_GetGlobalMouseState(&prev_mouse_pos.x, &prev_mouse_pos.y);

    var state: *State = try allocator.create(State);
    defer allocator.destroy(state);
    state.* = .{
        .mode = .regular,
        .allocator = allocator,
        .temp_allocator = std.heap.ArenaAllocator.init(allocator),
        .icon = icon_png.surface,
        .window = &app_window,
        .user_settings = user_settings,
        .activity_timer = try std.time.Timer.start(),
    };
    defer state.deinit();

    // DEBUG: Test break screen
    // state.user_settings.default_time_till_break = Duration.init(30 * time.ns_per_s);
    // state.user_settings.default_break_time = Duration.init(5 * time.ns_per_s);

    var has_quit = false;
    var frames_without_app_input: u16 = 0;
    while (!has_quit) {
        _ = state.temp_allocator.reset(.retain_capacity);

        const current_frame_time = sdl.SDL_GetPerformanceCounter();

        // Event polling
        {
            // Threshold to have responsive event polling based on:
            // - Wait N frames before we do WaitEvent so that the initial rendering sets things up nicely
            // - Wait N frames after keyboard presses for responsiveness
            const FrameWithoutInputThreshold: u16 = 250;
            if (frames_without_app_input < FrameWithoutInputThreshold) {
                frames_without_app_input += 1;
            }
            // If below threshold, poll events, otherwise wait with timeout then collect subsequent events
            // with a poll
            var is_polling_events = frames_without_app_input < FrameWithoutInputThreshold;
            while (true) {
                var sdl_event: sdl.SDL_Event = undefined;
                // Get next event
                {
                    const ev_res = blk: {
                        const window_flags = sdl.SDL_GetWindowFlags(state.window.window);
                        const is_main_window_minimized_or_occluded = (window_flags & sdl.SDL_WINDOW_MINIMIZED != 0) or
                            (window_flags & sdl.SDL_WINDOW_OCCLUDED != 0);

                        // log.debug("frames_without_app_input: {}, is minimized or occluded: {}", .{ frames_without_app_input, is_main_window_minimized_or_occluded });
                        if (is_polling_events) {
                            // Poll events and be responsive
                            break :blk sdl.SDL_PollEvent(&sdl_event);
                        }

                        // If minimized, increase the wait event delay to be even more power-saving
                        const is_powersaving_mode = is_main_window_minimized_or_occluded and
                            state.popup_windows.items.len == 0 and
                            state.taking_break_windows.items.len == 0;
                        if (is_powersaving_mode) {
                            if (state.time_till_next_timer_complete()) |timer| {
                                const safe_delay_in_ms: u64 = 5000;
                                const safe_delay = state.user_settings.incoming_break_or_default().nanoseconds + (safe_delay_in_ms * time.ns_per_ms);
                                if (timer.time_till_next_break.nanoseconds >= safe_delay) {
                                    // 5000ms timeout so we can at least occassionally detect global mouse position
                                    break :blk sdl.SDL_WaitEventTimeout(&sdl_event, safe_delay_in_ms);
                                }
                            }
                        }

                        // This either blocks until {N}ms passed or we get an event
                        // Conserves CPU. Opted for 500ms so it definitely refreshes every second
                        // for the live update on the home screen.
                        //
                        // We also need the timeout so that it eventually reads global mouse position
                        // outside of this loop to detect activity.
                        break :blk sdl.SDL_WaitEventTimeout(&sdl_event, 500);
                    };
                    if (!ev_res) {
                        break;
                    }
                    // If we received one event, start polling
                    is_polling_events = true;
                }

                // process events
                {
                    imgui.igSetCurrentContext(state.window.imgui_context);
                    _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(&sdl_event));

                    for (state.popup_windows.items) |*window| {
                        imgui.igSetCurrentContext(window.imgui_context);
                        _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(&sdl_event));
                    }
                    for (state.taking_break_windows.items) |*window| {
                        imgui.igSetCurrentContext(window.imgui_context);
                        _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(&sdl_event));
                    }
                }

                switch (sdl_event.type) {
                    sdl.SDL_EVENT_QUIT => {
                        // If triggered quit, close entire app
                        has_quit = true;
                        break;
                    },
                    sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                        const event = sdl_event.window;
                        if (event.windowID == sdl.SDL_GetWindowID(state.window.window)) {
                            // If closed the main app window, close entire app
                            has_quit = true;
                            break;
                        }
                    },
                    sdl.SDL_EVENT_MOUSE_MOTION => {
                        frames_without_app_input = 0;
                    },
                    sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                        const event = sdl_event.button;
                        if (event.down) {
                            frames_without_app_input = 0;
                        }
                    },
                    sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                        const event = sdl_event.button;
                        if (!event.down) {
                            frames_without_app_input = 0;
                        }
                        switch (event.button) {
                            sdl.SDL_BUTTON_LEFT => {
                                // event.state == sdl.SDL_RELEASED
                                if (!event.down) {
                                    if (state.break_mode.held_down_timer != null) {
                                        state.break_mode.held_down_timer = null;
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    sdl.SDL_EVENT_KEY_UP => {
                        const event = sdl_event.key;
                        if (event.down) {
                            frames_without_app_input = 0;
                        }
                        switch (event.key) {
                            sdl.SDLK_ESCAPE => {
                                // event.state == sdl.SDL_RELEASED
                                if (!event.down) {
                                    // If released reset the held down timer
                                    if (state.break_mode.held_down_timer == null) {
                                        state.break_mode.held_down_timer = try time.Timer.start();
                                    }
                                }
                                state.break_mode.esc_or_exit_presses += 1;
                            },
                            else => {},
                        }
                    },
                    sdl.SDL_EVENT_WINDOW_RESTORED => {
                        frames_without_app_input = 0;
                    },
                    else => {},
                }
            }
        }

        // Set new ImGui Frame *after* event polling, otherwise you get rare instances of sticky buttons / interactivity
        // (as per example code: https://github.com/ocornut/imgui/blob/master/examples/example_sdl2_sdlrenderer2/main.cpp)
        {
            for (state.popup_windows.items) |*window| {
                imgui.igSetCurrentContext(window.imgui_context);
                imgui.ImGui_ImplSDLRenderer3_NewFrame();
                imgui.ImGui_ImplSDL3_NewFrame();
                imgui.igNewFrame();
            }
            for (state.taking_break_windows.items) |*window| {
                imgui.igSetCurrentContext(window.imgui_context);
                imgui.ImGui_ImplSDLRenderer3_NewFrame();
                imgui.ImGui_ImplSDL3_NewFrame();
                imgui.igNewFrame();
            }

            imgui.igSetCurrentContext(state.window.imgui_context);
            imgui.ImGui_ImplSDLRenderer3_NewFrame();
            imgui.ImGui_ImplSDL3_NewFrame();
            imgui.igNewFrame();
        }

        // Detect activity and handle timers to pop-up break window
        {
            // Detect global mouse movement
            var curr_mouse_pos: MousePos = undefined;
            _ = sdl.SDL_GetGlobalMouseState(&curr_mouse_pos.x, &curr_mouse_pos.y);
            defer prev_mouse_pos = curr_mouse_pos;
            const diff = curr_mouse_pos.diff(prev_mouse_pos);
            if (diff.x >= 5 and
                diff.y >= 5)
            {
                state.time_since_last_input = try std.time.Timer.start();
                state.is_user_mouse_active = true;
            }

            if (state.mode == .regular) {
                // Track time using computer
                if (state.time_since_last_input) |*time_since_last_input| {
                    // TODO: Make inactivity time a variable
                    const inactivity_duration = 5 * std.time.ns_per_min;
                    if (time_since_last_input.read() > inactivity_duration) {
                        state.is_user_mouse_active = false;
                        state.activity_timer.reset();
                    }
                } else {
                    state.activity_timer.reset();
                    state.is_user_mouse_active = false;
                }
            }

            // Detect when to change mode
            switch (state.mode) {
                .regular, .incoming_break => {
                    if (state.time_till_next_timer_complete()) |next_timer| {
                        if (next_timer.time_till_next_break.nanoseconds <= 0) {
                            try state.change_mode(.taking_break);
                        } else if (next_timer.time_till_next_break.nanoseconds <= state.user_settings.incoming_break_or_default().nanoseconds) {
                            try state.change_mode(.incoming_break);
                        } else {
                            // If cancelled timer in main window
                            if (state.mode == .incoming_break) {
                                try state.change_mode(.regular);
                            }
                        }
                    } else {
                        if (state.mode == .incoming_break) {
                            // If we somehow got in this buggy state and there is no next break
                            // then switch to regular mode
                            try state.change_mode(.regular);
                        }
                    }
                },
                .taking_break => {
                    const time_active_in_ns = state.break_mode.timer.read();
                    const time_till_break_over = state.break_mode.duration.diff(time_active_in_ns);
                    if (time_till_break_over.nanoseconds <= 0) {
                        try state.change_mode(.regular);
                    }
                },
            }
        }

        // Default flags we use for each window
        const ImGuiDefaultWindowFlags = imgui.ImGuiWindowFlags_NoTitleBar | imgui.ImGuiWindowFlags_NoDecoration |
            imgui.ImGuiWindowFlags_NoResize | imgui.ImGuiWindowFlags_NoBackground;

        // Main application window
        {
            imgui.igSetCurrentContext(state.window.imgui_context);
            const viewport = &imgui.igGetMainViewport()[0];
            const viewport_pos = viewport.Pos;
            const viewport_size = viewport.Size;

            imgui.igSetNextWindowPos(viewport_pos, 0, .{});
            imgui.igSetNextWindowSize(viewport_size, 0);
            // NOTE(jae): 2024-11-03
            // Removed "imgui.ImGuiWindowFlags_MenuBar" as we no longer use menu bar
            _ = imgui.igBegin("mainwindow", null, ImGuiDefaultWindowFlags);
            defer imgui.igEnd();

            // NOTE(jae): 2024-11-03
            // Removed because kind of useless and it annoyed my partner, the one other user so far.
            // if (imgui.igBeginMenuBar()) {
            //     defer imgui.igEndMenuBar();
            //     if (imgui.igBeginMenu("Preferences", true)) {
            //         defer imgui.igEndMenu();
            //         if (imgui.igMenuItem_Bool("Take a Break", "", false, true)) {
            //             try state.change_mode(.taking_break);
            //         }
            //         if (imgui.igMenuItem_Bool("Exit", "", false, true)) {
            //             has_quit = true;
            //         }
            //     }
            // }

            switch (state.ui.kind) {
                .none => {
                    // {
                    //     imgui.igShowDemoWindow(null);
                    // }

                    // _ = imgui.igBeginTabBar("Tabs", imgui.ImGuiTabBarFlags_None);
                    // _ = imgui.igBeginTabItem("Overview", null, 0);
                    // imgui.igEndTabItem();
                    // _ = imgui.igBeginTabItem("Timers", null, 0);
                    // imgui.igEndTabItem();
                    // defer imgui.igEndTabBar();

                    // Heading
                    {
                        if (imgui.igButton("Add timer", .{})) {
                            state.ui.timer = .{
                                // ... resets all timer ui state ...
                            };
                            state.ui.kind = .timer;
                        }
                        imgui.igSameLine(0, 16);
                        if (imgui.igButton("Options", .{})) {
                            state.ui.options = .{
                                // ... resets all options ui state ...
                                // set this
                                .is_activity_break_enabled = state.user_settings.settings.is_activity_break_enabled,
                                .display_index = state.user_settings.settings.display_index,
                                // set below...
                                // .time_till_break =
                                // .break_time =
                                // .incoming_break =
                            };
                            const ui_options = &state.ui.options;
                            if (state.user_settings.settings.time_till_break) |td| _ = try std.fmt.bufPrintZ(ui_options.time_till_break[0..], "{sh}", .{td});
                            if (state.user_settings.settings.break_time) |td| _ = try std.fmt.bufPrintZ(ui_options.break_time[0..], "{sh}", .{td});
                            if (state.user_settings.settings.incoming_break) |td| _ = try std.fmt.bufPrintZ(ui_options.incoming_break[0..], "{sh}", .{td});

                            // OS-specific
                            switch (builtin.os.tag) {
                                .windows => {
                                    // Set os startup
                                    ui_options.os_startup = blk: {
                                        const temp_allocator = state.temp_allocator.allocator();
                                        const startup_run = try winregistry.RegistryWtf8.openKey(std.os.windows.HKEY_CURRENT_USER, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", .{});
                                        defer startup_run.closeKey();
                                        const startup_desk_breaker_path = startup_run.getString(temp_allocator, "", "DeskBreaker") catch |err| switch (err) {
                                            error.ValueNameNotFound => "",
                                            else => return err,
                                        };
                                        const out_buf = try temp_allocator.alloc(u8, std.fs.max_path_bytes);
                                        const exe_path = try std.fs.selfExePath(out_buf);
                                        break :blk std.mem.eql(u8, exe_path, startup_desk_breaker_path);
                                    };
                                },
                                else => {},
                            }

                            // List displays by name (if supported by operating system)
                            // - Windows: "0: MSI G241", "1: UGREEN"
                            // - MacOS: "0: 0" and "1: 1"
                            {
                                // Reset list
                                state.ui.options_metadata.display_names_buf.len = 0;

                                var display_count: c_int = undefined;
                                const display_list_or_err = sdl.SDL_GetDisplays(&display_count);
                                defer sdl.SDL_free(display_list_or_err);
                                if (display_list_or_err != null) {
                                    const display_list = display_list_or_err[0..@intCast(display_count)];
                                    for (display_list, 0..) |display_id, i| {
                                        const name_c_str = sdl.SDL_GetDisplayName(display_id);
                                        if (name_c_str == null) {
                                            continue;
                                        }
                                        try state.ui.options_metadata.display_names_buf.writer().print("{d}: {s}\x00", .{ i, name_c_str });
                                    }
                                }
                            }

                            // set ui to options
                            state.ui.kind = .options;
                        }
                        imgui.igSameLine(0, 16);
                        if (imgui.igButton("Take a break", .{})) {
                            try state.change_mode(.taking_break);
                        }
                    }

                    // List of timers
                    {
                        for (state.user_settings.timers.items, 0..) |*t, i| {
                            imgui.igPushID_Int(@intCast(i));
                            defer imgui.igPopID();
                            switch (t.kind) {
                                .timer => {
                                    const timer_duration = t.timer_duration orelse break;

                                    // Get duration to print
                                    var duration_left: Duration = timer_duration;
                                    if (t.timer_started) |*timer_started| {
                                        const diff = timer_duration.diff(timer_started.read());
                                        duration_left = diff;
                                    }

                                    var is_enabled = t.timer_started != null;
                                    if (imgui.igCheckbox(try state.tprint("{s} - {s}", .{ t.name.slice(), duration_left }), &is_enabled)) {
                                        if (!is_enabled) {
                                            t.timer_started = null;
                                        } else {
                                            t.timer_started = try std.time.Timer.start();
                                        }
                                    }
                                },
                                .alarm => {
                                    @panic("TODO: handle rendering alarm in list");
                                },
                            }

                            {
                                // TODO: Make Edit button align to right side
                                // const oldCursorPosX = imgui.igGetCursorPosX();
                                // const oldCursorPosY = imgui.igGetCursorPosY();
                                // defer {
                                //     imgui.igSetCursorPosX(oldCursorPosX);
                                //     imgui.igSetCursorPosY(oldCursorPosY);
                                // }
                                // imgui.igSameLine(0, 0);
                                // imgui.igSetNextWindowPos(.{ .x = viewport_size.x, .y = imgui.igGetCursorPosY() }, imgui.ImGuiCond_Always, .{ .x = 1 });
                                // // NOTE(jae): 2024-07-28
                                // // igBegin is globally scoped in rendering
                                // _ = imgui.igBegin(try state.tprint("edit-timer-{}", .{i}), null, imgui_default_window_flags);
                                // defer imgui.igEnd();
                                // imgui.igSetCursorPosX(0);

                                imgui.igSameLine(0, 16);
                                if (imgui.igButton("Edit", .{})) {
                                    const ui_timer = &state.ui.timer;
                                    ui_timer.* = .{
                                        .id = @intCast(i),
                                        .kind = t.kind,
                                        // .duration_time = if (t.timer_duration) |td| td. else "",
                                    };
                                    state.ui.kind = .timer;
                                    _ = try std.fmt.bufPrintZ(ui_timer.name[0..], "{s}", .{t.name.slice()});
                                    if (t.timer_duration) |td| _ = try std.fmt.bufPrintZ(ui_timer.duration_time[0..], "{sh}", .{td});
                                }
                            }
                        }

                        // TODO(jae): 2024-08-28
                        // Try to get table working for the above listing instead but can't get it to work
                        // if (imgui.igBeginTable("table", 2, imgui.ImGuiTableFlags_Borders |
                        //     imgui.ImGuiTableFlags_SizingFixedFit, .{}, 0))
                        // {
                        //     for (state.user_settings.timers.items) |*t| {
                        //         imgui.igTableNextRow(imgui.ImGuiTableRowFlags_None, 0);
                        //         {
                        //             imgui.igNextColumn();
                        //             imgui.igText(try state.tprint("{s}", .{t.name.slice()}));
                        //         }
                        //         if (t.timer_duration) |timer_duration| {
                        //             imgui.igNextColumn();
                        //             imgui.igText(try state.tprint("{}", .{timer_duration}));
                        //         }
                        //     }
                        //     imgui.igEndTable();
                        // }
                    }

                    // Bottom-left-corner
                    {
                        imgui.igSetNextWindowPos(.{ .x = 0, .y = viewport_size.y }, imgui.ImGuiCond_Always, .{ .x = 0, .y = 1 });
                        _ = imgui.igBegin("general-bottom-left-corner", null, ImGuiDefaultWindowFlags | imgui.ImGuiWindowFlags_AlwaysAutoResize);
                        defer imgui.igEnd();

                        if (state.snooze_times > 0) {
                            imgui.igText(try state.tprint("Times snoozed: {d}", .{state.snooze_times}));
                        }

                        if (state.snooze_activity_break_timer) |*snooze_timer| {
                            imgui.igText(try state.tprint("Snooze timer over in: {s}", .{
                                state.user_settings.snooze_duration_or_default().diff(snooze_timer.read()),
                            }));
                        } else if (state.user_settings.settings.is_activity_break_enabled) {
                            const time_till_activity_break_format = "Time till activity break: {s}";
                            if (state.is_user_mouse_active) {
                                imgui.igText(try state.tprint(time_till_activity_break_format, .{
                                    state.user_settings.time_till_break_or_default().diff(state.activity_timer.read()),
                                }));
                            } else {
                                imgui.igText(try state.tprint(time_till_activity_break_format, .{
                                    "(No mouse activity)",
                                }));
                            }
                        }

                        // DEBUG: Add debug info
                        if (builtin.mode == .Debug) {
                            {
                                const time_in_seconds = @divFloor(state.activity_timer.read(), std.time.ns_per_s);
                                imgui.igText("DEBUG: Time using computer: %d", time_in_seconds);
                            }
                            if (state.time_since_last_input) |*time_since_last_input| {
                                const time_in_seconds = @divFloor(time_since_last_input.read(), std.time.ns_per_s);
                                imgui.igText("DEBUG: Time since last activity: %d", time_in_seconds);
                            } else {
                                imgui.igText("DEBUG: Time since last activity: (none detected)");
                            }
                            if (state.time_till_next_timer_complete()) |next_timer| {
                                imgui.igText(try state.tprint("DEBUG: Time till popout: {s}", .{next_timer.time_till_next_break}));
                            }
                        }
                    }
                },
                .timer => {
                    imgui.igBeginGroup();
                    defer imgui.igEndGroup();
                    const ui_timer = &state.ui.timer;
                    _ = imgui.igCombo_Str("Type", @ptrCast(&ui_timer.kind), @TypeOf(ui_timer.kind).ImGuiItems, 0);
                    _ = imgui.igInputTextWithHint(
                        "Name (Optional)",
                        "Take out washing, Do dishes",
                        ui_timer.name[0..].ptr,
                        ui_timer.name.len,
                        0,
                        null,
                        null,
                    );
                    switch (ui_timer.kind) {
                        .timer => {
                            if (imgui.igInputTextWithHint(
                                "Duration",
                                "1h 30m 45s",
                                ui_timer.duration_time[0..].ptr,
                                ui_timer.duration_time.len,
                                0,
                                null,
                                null,
                            )) {
                                ui_timer.errors.duration_time = ""; // reset error message if changed
                            }
                            if (ui_timer.errors.duration_time.len > 0) {
                                _ = imgui.igText(try state.tprint("{s}", .{ui_timer.errors.duration_time}));
                            }
                        },
                        .alarm => {
                            _ = imgui.igInputTextWithHint(
                                "Time",
                                "6pm, 6:30pm, 19:00",
                                ui_timer.alarm_time[0..].ptr,
                                ui_timer.alarm_time.len,
                                0,
                                null,
                                null,
                            );
                        },
                    }
                    const is_new = ui_timer.id == -1;
                    const save_label: [:0]const u8 = if (is_new) "Create" else "Save";
                    if (imgui.igButton(save_label, .{})) {
                        var t: Timer = .{
                            .kind = ui_timer.kind,
                        };
                        const name_data = ui_timer.name[0..std.mem.len(ui_timer.name[0..].ptr)];
                        if (name_data.len == 0) {
                            t.name = try @TypeOf(t.name).fromSlice("Unnamed Alarm");
                        } else {
                            t.name = try @TypeOf(t.name).fromSlice(name_data);
                        }
                        var should_save_or_create = false;
                        switch (t.kind) {
                            .timer => {
                                const duration_time_str = ui_timer.duration_time[0..std.mem.len(ui_timer.duration_time[0..].ptr)];
                                // validate and set fields
                                if (duration_time_str.len == 0) {
                                    ui_timer.errors.duration_time = "required field";
                                } else {
                                    t.timer_duration = Duration.parseString(duration_time_str) catch null;
                                    if (t.timer_duration == null) {
                                        ui_timer.errors.duration_time = "invalid value, expect format: 1h 30m 45s";
                                    }
                                }
                                // If all fields are valid
                                if (t.timer_duration != null) {
                                    should_save_or_create = true;
                                }
                            },
                            .alarm => {
                                @panic("TODO: handle saving alarm");
                            },
                        }
                        if (should_save_or_create) {
                            if (ui_timer.id == -1) {
                                // Create
                                try state.user_settings.timers.append(t);
                                ui_timer.id = @intCast(state.user_settings.timers.items.len - 1);
                            } else {
                                // Save
                                state.user_settings.timers.items[@intCast(ui_timer.id)] = t;
                            }
                            state.ui.kind = .none;

                            // save
                            try UserConfig.save(state.temp_allocator.allocator(), &state.user_settings);
                        }
                    }
                    imgui.igSameLine(0, 8);
                    if (imgui.igButton("Cancel", .{})) {
                        state.ui.kind = .none;
                    }
                    if (!is_new) {
                        imgui.igSameLine(0, 0);
                        imgui.igSetCursorPosX(0);
                        imgui.igSetNextWindowPos(.{ .x = viewport_size.x, .y = imgui.igGetCursorPosY() }, imgui.ImGuiCond_Always, .{ .x = 1 });
                        _ = imgui.igBegin("deletewindow", null, ImGuiDefaultWindowFlags);
                        defer imgui.igEnd();
                        if (imgui.igButton("Delete", .{})) {
                            _ = state.user_settings.timers.orderedRemove(@intCast(ui_timer.id));
                            state.ui.kind = .none;

                            // save
                            try UserConfig.save(state.temp_allocator.allocator(), &state.user_settings);
                        }
                    }
                },
                .options => {
                    const ui_options = &state.ui.options;
                    const ui_metadata = &state.ui.options_metadata;

                    if (ui_options.os_startup) |os_startup| {
                        var is_enabled = os_startup;
                        if (imgui.igCheckbox("Open on startup", &is_enabled)) {
                            if (!is_enabled) {
                                ui_options.os_startup = false;
                            } else {
                                ui_options.os_startup = true;
                            }
                        }
                    }

                    if (state.ui.options_metadata.display_names_buf.len > 0) {
                        var display_index_ui: c_int = @intCast(ui_options.display_index);
                        _ = imgui.igCombo_Str(
                            "Display",
                            &display_index_ui,
                            ui_metadata.display_names_buf.buffer[0..],
                            0,
                        );
                        if (display_index_ui >= 0) {
                            ui_options.display_index = @intCast(display_index_ui);
                        }
                    }

                    var is_enabled = ui_options.is_activity_break_enabled;
                    if (imgui.igCheckbox("Enable Activity Timer", &is_enabled)) {
                        if (!is_enabled) {
                            ui_options.is_activity_break_enabled = false;
                        } else {
                            ui_options.is_activity_break_enabled = true;
                        }
                    }

                    if (imgui.igInputTextWithHint(
                        "Time till break",
                        try state.tprint("default: {sh}", .{state.user_settings.default_time_till_break}),
                        ui_options.time_till_break[0..].ptr,
                        ui_options.time_till_break.len,
                        0,
                        null,
                        null,
                    )) {
                        ui_options.errors.time_till_break = ""; // reset error message if changed
                    }
                    if (ui_options.errors.time_till_break.len > 0) {
                        _ = imgui.igText(try state.tprint("{s}", .{ui_options.errors.time_till_break}));
                    }

                    if (imgui.igInputTextWithHint(
                        "Break time",
                        try state.tprint("default: {sh}", .{state.user_settings.default_break_time}),
                        ui_options.break_time[0..].ptr,
                        ui_options.break_time.len,
                        0,
                        null,
                        null,
                    )) {
                        ui_options.errors.break_time = ""; // reset error message if changed
                    }
                    if (ui_options.errors.break_time.len > 0) {
                        _ = imgui.igText(try state.tprint("{s}", .{ui_options.errors.break_time}));
                    }

                    if (imgui.igInputTextWithHint(
                        "Incoming break",
                        try state.tprint("default: {sh}", .{state.user_settings.default_incoming_break}),
                        ui_options.incoming_break[0..].ptr,
                        ui_options.incoming_break.len,
                        0,
                        null,
                        null,
                    )) {
                        ui_options.errors.incoming_break = ""; // reset error message if changed
                    }
                    if (ui_options.errors.incoming_break.len > 0) {
                        _ = imgui.igText(try state.tprint("{s}", .{ui_options.errors.incoming_break}));
                    }

                    if (imgui.igButton("Save", .{})) {
                        // Get time till break
                        const time_till_break_str = ui_options.time_till_break[0..std.mem.len(ui_options.time_till_break[0..].ptr)];
                        const time_till_break: ?Duration = blk: {
                            const d = Duration.parseOptionalString(time_till_break_str) catch {
                                ui_options.errors.time_till_break = "invalid value, expect format: 1h 30m 45s";
                                break :blk null;
                            };
                            break :blk d;
                        };

                        // Get break time
                        const break_time_str = ui_options.time_till_break[0..std.mem.len(ui_options.break_time[0..].ptr)];
                        const break_time: ?Duration = blk: {
                            const d = Duration.parseOptionalString(break_time_str) catch {
                                ui_options.errors.break_time = "invalid value, expect format: 1h 30m 45s";
                                break :blk null;
                            };
                            break :blk d;
                        };

                        // Get incoming break
                        const incoming_break: ?Duration = blk: {
                            const d = Duration.parseOptionalString(std.mem.span(ui_options.incoming_break[0..].ptr)) catch {
                                ui_options.errors.incoming_break = "invalid value, expect format: 1h 30m 45s";
                                break :blk null;
                            };
                            break :blk d;
                        };

                        if (ui_options.os_startup) |os_startup| {
                            switch (builtin.os.tag) {
                                .windows => {
                                    const temp_allocator = state.temp_allocator.allocator();
                                    const startup_run = try winregistry.RegistryWtf8.openKey(std.os.windows.HKEY_CURRENT_USER, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", .{});
                                    defer startup_run.closeKey();
                                    if (!os_startup) {
                                        startup_run.deleteValue("DeskBreaker") catch |err| switch (err) {
                                            error.ValueNameNotFound => {}, // If entry doesn't exist, do nothing
                                            else => return err,
                                        };
                                    } else {
                                        const out_buf = try temp_allocator.alloc(u8, std.fs.max_path_bytes);
                                        const exe_path = try std.fs.selfExePath(out_buf);
                                        try startup_run.setString("DeskBreaker", exe_path);
                                    }
                                },
                                else => {},
                            }
                        }

                        const has_error = ui_options.errors.time_till_break.len > 0 and ui_options.errors.break_time.len > 0;
                        if (!has_error) {
                            // update from fields / text
                            state.user_settings.settings = .{
                                .is_activity_break_enabled = ui_options.is_activity_break_enabled,
                                .time_till_break = time_till_break,
                                .break_time = break_time,
                                .incoming_break = incoming_break,
                                .display_index = ui_options.display_index,
                            };

                            // save
                            try UserConfig.save(state.temp_allocator.allocator(), &state.user_settings);

                            // close
                            state.ui.kind = .none;
                        }
                    }
                    imgui.igSameLine(0, 8);
                    if (imgui.igButton("Cancel", .{})) {
                        state.ui.kind = .none;
                    }
                },
            }
        }

        if (state.mode != .incoming_break) {
            for (state.popup_windows.items) |*window| {
                window.deinit();
            }
            state.popup_windows.clearRetainingCapacity();
        }
        for (state.popup_windows.items) |*window| {
            imgui.igSetCurrentContext(window.imgui_context);

            const viewport = &imgui.igGetMainViewport()[0];
            const viewport_pos = viewport.Pos;
            const viewport_size = viewport.Size;
            imgui.igSetNextWindowPos(viewport_pos, 0, .{});
            imgui.igSetNextWindowSize(viewport_size, 0);

            _ = imgui.igBegin("incoming_break_window", null, ImGuiDefaultWindowFlags);
            defer imgui.igEnd();

            const next_timer = state.time_till_next_timer_complete() orelse {
                break;
            };

            var heading_text: [:0]const u8 = "Time in:";
            if (next_timer.id >= 0) {
                heading_text = "Timer or alarm in:";
            } else {
                switch (next_timer.id) {
                    NextTimer.ActivityTimer => {
                        heading_text = "Break time in:";
                    },
                    NextTimer.SnoozeTimer => {
                        // TODO(jae): Better phrasing here, for now it informs you that you hit snooze already
                        heading_text = "Snooze in:";
                    },
                    else => {},
                }
            }

            imgui.igText(heading_text);
            imgui.igText(try state.tprint("{s}", .{next_timer.time_till_next_break}));
            if (next_timer.id == NextTimer.ActivityTimer or
                next_timer.id == NextTimer.SnoozeTimer)
            {
                if (imgui.igButton("Snooze", .{})) {
                    state.snooze();
                    try state.change_mode(.regular);
                }
            }
        }

        // Taking break windows
        if (state.mode != .taking_break) {
            for (state.taking_break_windows.items) |*window| {
                window.deinit();
            }
            state.taking_break_windows.clearRetainingCapacity();
        }
        for (state.taking_break_windows.items) |*window| {
            imgui.igSetCurrentContext(window.imgui_context);
            const viewport = &imgui.igGetMainViewport()[0];
            const viewport_pos = viewport.Pos;
            const viewport_size = viewport.Size;
            imgui.igSetNextWindowPos(viewport_pos, 0, .{});
            imgui.igSetNextWindowSize(viewport_size, 0);

            var has_triggered_exiting_break_mode = false;
            const required_esc_presses = 30;

            // Top-Left
            {
                imgui.igSetNextWindowPos(viewport_pos, 0, .{ .x = 0, .y = 0 });
                _ = imgui.igBegin("break-top-left", null, ImGuiDefaultWindowFlags | imgui.ImGuiWindowFlags_AlwaysAutoResize);
                defer imgui.igEnd();

                imgui.igText(try state.tprint("Time till break is over: {s}", .{
                    state.break_mode.duration.diff(state.break_mode.timer.read()),
                }));
            }

            // Top-Right
            {
                imgui.igSetNextWindowPos(.{ .x = viewport_size.x, .y = 0 }, imgui.ImGuiCond_Always, .{ .x = 1, .y = 0 });
                _ = imgui.igBegin("break-top-right", null, ImGuiDefaultWindowFlags | imgui.ImGuiWindowFlags_AlwaysAutoResize);
                defer imgui.igEnd();

                if (imgui.igButton("Exit", .{})) {
                    if (state.break_mode.held_down_timer == null) {
                        state.break_mode.held_down_timer = try time.Timer.start();
                    }

                    // increment exit presses
                    state.break_mode.esc_or_exit_presses += 1;

                    // DEBUG: Quit immediately as we're likely just testing the screen
                    if (state.user_settings.time_till_break_or_default().nanoseconds <= 1 * time.ns_per_s) {
                        has_quit = true;
                    }
                }
            }

            {
                imgui.igSetNextWindowPos(.{ .x = viewport_size.x / 2, .y = viewport_size.y / 2 }, imgui.ImGuiCond_Always, .{ .x = 0.5, .y = 0.5 });
                _ = imgui.igBegin("break-center", null, ImGuiDefaultWindowFlags);
                defer imgui.igEnd();

                const has_active_timers = timercheck: {
                    for (state.user_settings.timers.items) |*t| {
                        switch (t.kind) {
                            .timer => {
                                if (t.timer_started == null or // If not using this timer, skip
                                    t.timer_duration == null // If no duration configured, skip
                                ) {
                                    continue;
                                }
                                break :timercheck true;
                            },
                            .alarm => @panic("TODO: Handle listing alarm"),
                        }
                    }
                    break :timercheck false;
                };
                imgui.igText("It's time for a break. Get up, stretch your limbs a bit!");
                if (has_active_timers) {
                    imgui.igNewLine();
                    imgui.igText("Timers:");
                    for (state.user_settings.timers.items) |*t| {
                        switch (t.kind) {
                            .timer => {
                                // If not using this timer, skip
                                var timer_started = t.timer_started orelse continue;
                                // If no duration configured, skip
                                const timer_duration = t.timer_duration orelse continue;

                                // Show timer with time left
                                const duration_left = timer_duration.diff(timer_started.read());
                                imgui.igText(try state.tprint("{s} - {s}", .{ t.name.slice(), duration_left }));
                            },
                            .alarm => @panic("TODO: Handle listing alarm"),
                        }
                    }
                }
                // if (builtin.mode == .Debug) {
                //     imgui.igText("Daily To-Do List");
                //     _ = imgui.igCheckbox("Todo Item One", &todo_checkbox);
                //     _ = imgui.igCheckbox("Todo Item Two", &todo_checkbox);
                //     _ = imgui.igCheckbox("Todo Item Three", &todo_checkbox);
                // }
            }

            // Bottom-right
            {
                imgui.igSetNextWindowPos(.{ .x = viewport_size.x, .y = viewport_size.y }, imgui.ImGuiCond_Always, .{ .x = 1, .y = 1 });
                _ = imgui.igBegin("break-bottom-right-corner", null, ImGuiDefaultWindowFlags | imgui.ImGuiWindowFlags_AlwaysAutoResize);
                defer imgui.igEnd();

                if (state.break_mode.held_down_timer) |*exit_timer| {
                    imgui.igText(
                        try state.tprint("Will exit in: {s}", .{state.user_settings.exit_time_or_default().diff(exit_timer.read())}),
                    );
                }

                if (state.break_mode.esc_or_exit_presses > 1) {
                    imgui.igText(
                        try state.tprint("Presses until exit: {}/{}", .{ state.break_mode.esc_or_exit_presses, required_esc_presses }),
                    );
                }

                if (state.can_snooze()) {
                    if (imgui.igButton("Snooze", .{})) {
                        state.snooze();
                        has_triggered_exiting_break_mode = true;
                    }
                }
            }

            // Check if triggered exit break mode manually
            if (state.break_mode.held_down_timer) |*exit_timer| {
                const exit_time_left = state.user_settings.exit_time_or_default().diff(exit_timer.read());
                if (exit_time_left.nanoseconds <= 0) {
                    has_triggered_exiting_break_mode = true;
                }
            }
            if (state.break_mode.esc_or_exit_presses >= required_esc_presses) {
                has_triggered_exiting_break_mode = true;
            }
            if (has_triggered_exiting_break_mode) {
                try state.change_mode(.regular);
            }
        }

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
                imgui.igSetCurrentContext(window.imgui_context);
                imgui.igRender();

                _ = sdl.SDL_SetRenderDrawColor(renderer, 20, 20, 20, 0);
                _ = sdl.SDL_RenderClear(renderer);

                imgui.ImGui_ImplSDLRenderer3_RenderDrawData(@ptrCast(imgui.igGetDrawData()), @ptrCast(renderer));
                if (!sdl.SDL_RenderPresent(renderer)) {
                    // TODO: Handle not rendering?
                    @panic("SDL_RenderPresent failed for main application window");
                }
            }
        }.renderWindow;

        // Render app window
        renderWindow(state.window);
        for (state.popup_windows.items) |*incoming_break_window| {
            renderWindow(incoming_break_window);
        }
        for (state.taking_break_windows.items) |*taking_break_window| {
            renderWindow(taking_break_window);
        }
    }
}
