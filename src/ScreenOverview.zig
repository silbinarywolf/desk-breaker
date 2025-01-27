const std = @import("std");
const builtin = @import("builtin");
const imgui = @import("imgui");

const App = @import("App.zig");
const Duration = @import("Duration.zig");

const log = std.log.default;
const assert = std.debug.assert;

pub fn render(app: *App) !void {
    assert(app.ui.screen == .overview);

    // List of timers
    {
        for (app.user_settings.timers.items, 0..) |*t, i| {
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
                    if (imgui.igCheckbox(try app.tprint("{s} - {s}", .{ t.name.slice(), duration_left }), &is_enabled)) {
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
                imgui.igSameLine(0, 16);
                if (imgui.igButton("Edit", .{})) {
                    const ui_timer = &app.ui.timer;
                    ui_timer.* = .{
                        .id = @intCast(i),
                        .kind = t.kind,
                        // .duration_time = if (t.timer_duration) |td| td. else "",
                    };
                    app.ui.screen = .timer;
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
    var viewport_size: imgui.ImVec2 = undefined;
    imgui.igGetWindowSize(&viewport_size);
    imgui.igSetNextWindowPos(.{ .x = 0, .y = viewport_size.y }, imgui.ImGuiCond_Always, .{ .x = 0, .y = 1 });
    if (imgui.igBegin("general-bottom-left-corner", null, App.ImGuiDefaultWindowFlags | imgui.ImGuiWindowFlags_AlwaysAutoResize)) {
        defer imgui.igEnd();

        if (app.snooze_times > 0) {
            imgui.igText(try app.tprint("Times snoozed: {d}", .{app.snooze_times}));
        }

        if (app.snooze_activity_break_timer) |*snooze_timer| {
            imgui.igText(try app.tprint("Snooze timer over in: {s}", .{
                app.user_settings.snooze_duration_or_default().diff(snooze_timer.read()),
            }));
        } else if (app.user_settings.settings.is_activity_break_enabled) {
            const time_till_activity_break_format = "Time till activity break: {s}";
            if (app.mode == .taking_break) {
                imgui.igText(try app.tprint(time_till_activity_break_format, .{
                    "(Currently happening)",
                }));
            } else if (app.is_user_mouse_active) {
                imgui.igText(try app.tprint(time_till_activity_break_format, .{
                    app.user_settings.time_till_break_or_default().diff(app.activity_timer.read()),
                }));
            } else {
                imgui.igText(try app.tprint(time_till_activity_break_format, .{
                    "(No mouse activity)",
                }));
            }
        }

        // DEBUG: Add debug info
        if (builtin.mode == .Debug) {
            {
                const time_in_seconds = @divFloor(app.activity_timer.read(), std.time.ns_per_s);
                imgui.igText("DEBUG: Time using computer: %d", time_in_seconds);
            }
            if (app.time_since_last_input) |*time_since_last_input| {
                const time_in_seconds = @divFloor(time_since_last_input.read(), std.time.ns_per_s);
                imgui.igText("DEBUG: Time since last activity: %d", time_in_seconds);
            } else {
                imgui.igText("DEBUG: Time since last activity: (none detected)");
            }
            if (app.time_till_next_timer_complete()) |next_timer| {
                imgui.igText(try app.tprint("DEBUG: Time till popout: {s}", .{next_timer.time_till_next_break}));
            }
        }
    }
}
