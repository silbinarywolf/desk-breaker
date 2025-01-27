const std = @import("std");
const builtin = @import("builtin");
const imgui = @import("imgui");

const App = @import("App.zig");

pub fn render(app: *App) !void {
    // if no longer pending a break, destroy each window
    if (app.mode != .incoming_break) {
        for (app.popup_windows.items) |*window| {
            window.deinit();
        }
        app.popup_windows.clearRetainingCapacity();
    }
    for (app.popup_windows.items) |*window| {
        imgui.igSetCurrentContext(window.imgui_context);

        const viewport: *imgui.ImGuiViewport = @as(?*imgui.ImGuiViewport, imgui.igGetMainViewport()) orelse {
            // If no viewport skip
            continue;
        };
        const viewport_pos = viewport.Pos;
        const viewport_size = viewport.Size;
        imgui.igSetNextWindowPos(viewport_pos, 0, .{});
        imgui.igSetNextWindowSize(viewport_size, 0);

        if (!imgui.igBegin("incoming_break_window", null, App.ImGuiDefaultWindowFlags)) {
            // if not rendering
            continue;
        }
        defer imgui.igEnd();

        const next_timer = app.time_till_next_timer_complete() orelse {
            break;
        };

        const heading_text: [:0]const u8 = switch (next_timer.id) {
            .activity_timer => "Break time in:",
            // TODO(jae): Better phrasing here, for now it informs you that you hit snooze already
            .snooze_timer => "Snooze in:",
            else => "Timer or alarm in:",
        };

        imgui.igTextWrapped(heading_text);
        imgui.igTextWrapped(try app.tprint("{s}", .{next_timer.time_till_next_break}));

        const user_defined_incoming_break_message = app.user_settings.settings.incoming_break_message;
        if (user_defined_incoming_break_message.len > 0) {
            imgui.igNewLine();
            imgui.igTextWrapped(try app.tprint("{s}", .{app.user_settings.settings.incoming_break_message}));
        }

        if (next_timer.id == .activity_timer or
            next_timer.id == .snooze_timer)
        {
            if (app.can_snooze()) {
                if (imgui.igButton("Snooze", .{})) {
                    app.snooze();
                    try app.change_mode(.regular);
                }
            }
        }
    }
}
