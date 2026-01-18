const std = @import("std");
const time = std.time;
const builtin = @import("builtin");
const imgui = @import("imgui");

const Timer = @import("Timer.zig");
const App = @import("App.zig");

pub fn render(app: *App) !void {
    if (app.mode != .taking_break) {
        for (app.taking_break_windows.items) |*window| {
            window.deinit();
        }
        app.taking_break_windows.clearRetainingCapacity();
    }
    for (app.taking_break_windows.items) |*window| {
        imgui.igSetCurrentContext(window.imgui_context);

        const viewport = @as(?*imgui.ImGuiViewport, imgui.igGetMainViewport()) orelse {
            continue; // If no viewport skip
        };
        const viewport_pos = viewport.Pos;
        const viewport_size = viewport.Size;
        imgui.igSetNextWindowPos(viewport_pos, imgui.ImGuiCond_None, .{});
        imgui.igSetNextWindowSize(viewport_size, imgui.ImGuiCond_None);
        if (!imgui.igBegin("###taking_break", null, App.ImGuiDefaultWindowFlags)) {
            continue;
        }
        defer imgui.igEnd();

        var has_triggered_exiting_break_mode = false;
        const required_esc_presses = 30;

        // Top-Left
        imgui.igSetNextWindowPos(viewport_pos, imgui.ImGuiCond_Always, .{ .x = 0, .y = 0 });
        if (imgui.igBegin("###break-top-left", null, App.ImGuiDefaultWindowFlags | imgui.ImGuiWindowFlags_AlwaysAutoResize)) {
            defer imgui.igEnd();

            imgui.igText(try app.tprint("Time till break is over: {f}", .{
                app.break_mode.duration.diff(app.break_mode.timer.read()).formatLong(),
            }));
        }

        // Top-Right
        imgui.igSetNextWindowPos(.{ .x = viewport_size.x, .y = 0 }, imgui.ImGuiCond_Always, .{ .x = 1, .y = 0 });
        if (imgui.igBegin("###break-top-right", null, App.ImGuiDefaultWindowFlags | imgui.ImGuiWindowFlags_AlwaysAutoResize)) {
            defer imgui.igEnd();

            if (imgui.igButton("Exit", .{})) {
                if (app.break_mode.held_down_timer == null) {
                    app.break_mode.held_down_timer = try Timer.start();
                }

                // increment exit presses
                app.break_mode.esc_or_exit_presses += 1;

                // DEBUG: Quit immediately as we're likely just testing the screen
                if (app.user_settings.time_till_break_or_default().nanoseconds <= 1 * time.ns_per_s) {
                    app.has_quit = true;
                }
            }
        }

        // Center
        imgui.igSetNextWindowPos(.{ .x = viewport_size.x / 2, .y = viewport_size.y / 2 }, imgui.ImGuiCond_Always, .{ .x = 0.5, .y = 0.5 });
        if (imgui.igBegin("###break-center", null, App.ImGuiDefaultWindowFlags)) {
            defer imgui.igEnd();

            const has_active_timers = timercheck: {
                for (app.user_settings.timers.items) |*t| {
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
                for (app.user_settings.timers.items) |*t| {
                    switch (t.kind) {
                        .timer => {
                            // If not using this timer, skip
                            var timer_started = t.timer_started orelse continue;
                            // If no duration configured, skip
                            const timer_duration = t.timer_duration orelse continue;

                            // Show timer with time left
                            const duration_left = timer_duration.diff(timer_started.read());
                            imgui.igText(try app.tprint("{s} - {f}", .{ t.name[0..], duration_left.formatLong() }));
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
            _ = imgui.igBegin("break-bottom-right-corner", null, App.ImGuiDefaultWindowFlags | imgui.ImGuiWindowFlags_AlwaysAutoResize);
            defer imgui.igEnd();

            if (app.break_mode.held_down_timer) |*exit_timer| {
                imgui.igText(
                    try app.tprint("Will exit in: {f}", .{app.user_settings.exit_time_or_default().diff(exit_timer.read()).formatLong()}),
                );
            }

            if (app.break_mode.esc_or_exit_presses > 1) {
                imgui.igText(
                    try app.tprint("Presses until exit: {}/{}", .{ app.break_mode.esc_or_exit_presses, required_esc_presses }),
                );
            }

            if (app.can_snooze()) {
                if (imgui.igButton("Snooze", .{})) {
                    app.snooze();
                    has_triggered_exiting_break_mode = true;
                }
            }
        }

        // Check if triggered exit break mode manually
        if (app.break_mode.held_down_timer) |*exit_timer| {
            const exit_time_left = app.user_settings.exit_time_or_default().diff(exit_timer.read());
            if (exit_time_left.nanoseconds <= 0) {
                has_triggered_exiting_break_mode = true;
            }
        }
        if (app.break_mode.esc_or_exit_presses >= required_esc_presses) {
            has_triggered_exiting_break_mode = true;
        }
        if (has_triggered_exiting_break_mode) {
            // NOTE(jae): 2024-11-25: should this also reset "state.snooze_times_in_a_row"? :thinking_emoji:
            try app.change_mode(.regular);
        }
    }
}
