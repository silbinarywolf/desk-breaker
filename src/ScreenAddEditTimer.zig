const std = @import("std");
const builtin = @import("builtin");
const imgui = @import("imgui");

const UserConfig = @import("UserConfig.zig");
const Duration = @import("Duration.zig");
const App = @import("App.zig");
const Timer = App.Timer;

const log = std.log.scoped(.ScreenAddEditTimer);
const assert = std.debug.assert;

/// called when the screen is first opened
pub fn open(app: *App) void {
    if (!app.ui.ui_allocator.reset(.retain_capacity)) {
        log.debug("[ui allocator] failed to reset", .{});
    }
    app.ui.timer = .{
        // ... resets all timer ui state ...
    };
}

pub fn render(app: *App) !void {
    assert(app.ui.screen == .timer);

    imgui.igBeginGroup();
    defer imgui.igEndGroup();

    const ui_timer = &app.ui.timer;
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
                _ = imgui.igText(try app.tprint("{s}", .{ui_timer.errors.duration_time}));
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
        const timer_name = std.mem.span(ui_timer.name[0..].ptr);
        if (timer_name.len == 0) {
            const default_name = switch (t.kind) {
                .timer => "Unnamed Timer",
                .alarm => "Unnamed Alarm",
            };
            t.name = try @TypeOf(t.name).fromSlice(default_name);
        } else {
            t.name = try @TypeOf(t.name).fromSlice(timer_name);
        }
        var should_save_or_create = false;
        switch (t.kind) {
            .timer => {
                const duration_time_str = std.mem.span(ui_timer.duration_time[0..].ptr);
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
                try app.user_settings.timers.append(t);
                ui_timer.id = @intCast(app.user_settings.timers.items.len - 1);
            } else {
                // Save
                app.user_settings.timers.items[@intCast(ui_timer.id)] = t;
            }
            app.ui.screen = .overview;

            // save
            try UserConfig.save(app.temp_allocator.allocator(), app.user_settings);
        }
    }
    imgui.igSameLine(0, 8);
    if (imgui.igButton("Cancel", .{})) {
        app.ui.screen = .overview;
    }
    if (!is_new) {
        imgui.igSameLine(0, 0);
        imgui.igSetCursorPosX(0);
        var viewport_size: imgui.ImVec2 = undefined;
        imgui.igGetWindowSize(&viewport_size);
        imgui.igSetNextWindowPos(.{ .x = viewport_size.x, .y = imgui.igGetCursorPosY() }, imgui.ImGuiCond_Always, .{ .x = 1 });
        if (imgui.igBegin("deletewindow", null, App.ImGuiDefaultWindowFlags)) {
            defer imgui.igEnd();
            if (imgui.igButton("Delete", .{})) {
                _ = app.user_settings.timers.orderedRemove(@intCast(ui_timer.id));
                app.ui.screen = .overview;

                // save
                try UserConfig.save(app.temp_allocator.allocator(), app.user_settings);
            }
        }
    }
}
