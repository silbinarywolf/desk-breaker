const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const imgui = @import("imgui");

const winregistry = @import("winregistry.zig");
const UserConfig = @import("UserConfig.zig");
const Duration = @import("Duration.zig");
const App = @import("App.zig");
const Timer = App.Timer;

const log = std.log.scoped(.ScreenOptions);
const assert = std.debug.assert;

pub fn open(app: *App) !void {
    if (!app.ui.ui_allocator.reset(.retain_capacity)) {
        log.debug("[ui allocator] failed to reset", .{});
    }

    const ui_options = &app.ui.options;
    app.ui.options = .{
        // ... resets all options ui state ...
        // set this
        .is_activity_break_enabled = app.user_settings.settings.is_activity_break_enabled,
        .display_index = app.user_settings.settings.display_index,
        // set below...
        .time_till_break = try app.ui.allocDuration(app.user_settings.settings.time_till_break),
        .break_time = try app.ui.allocDuration(app.user_settings.settings.break_time),
        // .incoming_break =
        // .incoming_break_message =
        // .max_snoozes_in_a_row =
        // .break_time =
        // .incoming_break =
        // .incoming_break_message =
        // .max_snoozes_in_a_row =
    };

    // TODO: Switch each item to new temporary allocator
    if (app.user_settings.settings.incoming_break) |td| _ = try std.fmt.bufPrintZ(ui_options.incoming_break[0..], "{sh}", .{td});
    if (app.user_settings.settings.incoming_break_message.len > 0) _ = try std.fmt.bufPrintZ(ui_options.incoming_break_message[0..], "{s}", .{app.user_settings.settings.incoming_break_message});
    if (app.user_settings.settings.max_snoozes_in_a_row) |max_snoozes| {
        if (max_snoozes == UserConfig.Settings.MaxSnoozesDisabled) {
            // Disabled
            _ = try std.fmt.bufPrintZ(ui_options.max_snoozes_in_a_row[0..], "{}", .{UserConfig.Settings.MaxSnoozesDisabled});
        } else {
            _ = try std.fmt.bufPrintZ(ui_options.max_snoozes_in_a_row[0..], "{}", .{max_snoozes});
        }
    }

    // OS-specific
    switch (builtin.os.tag) {
        .windows => {
            // Set os startup
            ui_options.os_startup = blk: {
                const temp_allocator = app.temp_allocator.allocator();
                const startup_run = try winregistry.RegistryWtf8.openKey(std.os.windows.HKEY_CURRENT_USER, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", .{});
                defer startup_run.closeKey();
                const startup_desk_breaker_path = startup_run.getString(temp_allocator, "", App.StartupRegistryKey) catch |err| switch (err) {
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
        // Reset options
        app.ui.options_metadata = .{};

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
                try app.ui.options_metadata.display_names_buf.writer().print("{d}: {s}\x00", .{ i, name_c_str });
            }
        }
    }
}

pub fn render(app: *App) !void {
    const ui_options = &app.ui.options;
    const ui_metadata = &app.ui.options_metadata;

    imgui.igPushItemWidth(300);
    defer imgui.igPopItemWidth();

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

    if (app.ui.options_metadata.display_names_buf.len > 0) {
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
        try app.tprint("default: {sh}", .{app.user_settings.default_time_till_break}),
        ui_options.time_till_break[0..].ptr,
        ui_options.time_till_break.len,
        0,
        null,
        null,
    )) {
        ui_options.errors.time_till_break = ""; // reset error message if changed
    }
    if (ui_options.errors.time_till_break.len > 0) {
        _ = imgui.igText(try app.tprint("{s}", .{ui_options.errors.time_till_break}));
    }

    if (imgui.igInputTextWithHint(
        "Break time",
        try app.tprint("default: {sh}", .{app.user_settings.default_break_time}),
        ui_options.break_time[0..].ptr,
        ui_options.break_time.len,
        0,
        null,
        null,
    )) {
        ui_options.errors.break_time = ""; // reset error message if changed
    }
    if (ui_options.errors.break_time.len > 0) {
        _ = imgui.igText(try app.tprint("{s}", .{ui_options.errors.break_time}));
    }

    // Incoming break
    {
        const default_value = app.user_settings.default_incoming_break;
        const current_value = &ui_options.incoming_break;
        const error_message = &ui_options.errors.incoming_break;
        if (imgui.igInputTextWithHint(
            "Incoming break",
            try app.tprint("default: {sh}", .{default_value}),
            current_value[0..].ptr,
            current_value.len,
            0,
            null,
            null,
        )) {
            error_message.* = ""; // reset error message if changed
        }
        if (error_message.len > 0) {
            _ = imgui.igText(try app.tprint("{s}", .{error_message.*}));
        }
    }

    {
        const current_value = &ui_options.incoming_break_message;
        const error_message = &ui_options.errors.incoming_break_message;
        if (imgui.igInputTextWithHint(
            "Incoming break message",
            "default: (none)",
            current_value[0..].ptr,
            current_value.len,
            0,
            null,
            null,
        )) {
            error_message.* = ""; // reset error message if changed
        }
        if (error_message.len > 0) {
            _ = imgui.igText(try app.tprint("{s}", .{error_message.*}));
        }
    }

    {
        const current_value = &ui_options.max_snoozes_in_a_row;
        const error_message = &ui_options.errors.max_snoozes_in_a_row;
        if (imgui.igInputTextWithHint(
            "Max snoozes in a row (-1 = off)",
            "default: 2",
            current_value[0..].ptr,
            current_value.len,
            imgui.ImGuiInputTextFlags_CharsDecimal,
            null,
            null,
        )) {
            error_message.* = ""; // reset error message if changed
        }
        if (error_message.len > 0) {
            _ = imgui.igText(try app.tprint("{s}", .{error_message.*}));
        }
    }

    if (imgui.igButton("Save", .{})) {
        const InvalidDurationMessage = "invalid value, expect format: 1h 30m 45s";

        // Get time till break
        const time_till_break: ?Duration = Duration.parseOptionalString(std.mem.span(ui_options.time_till_break[0..].ptr)) catch blk: {
            ui_options.errors.time_till_break = InvalidDurationMessage;
            break :blk null;
        };

        // Get break time
        const break_time: ?Duration = Duration.parseOptionalString(std.mem.span(ui_options.break_time[0..].ptr)) catch blk: {
            ui_options.errors.break_time = InvalidDurationMessage;
            break :blk null;
        };

        // Get incoming break
        const incoming_break: ?Duration = Duration.parseOptionalString(std.mem.span(ui_options.incoming_break[0..].ptr)) catch blk: {
            ui_options.errors.incoming_break = InvalidDurationMessage;
            break :blk null;
        };

        // Get incoming break message
        const incoming_break_message = std.mem.span(ui_options.incoming_break_message[0..].ptr);

        // Get max snoozes in a row
        const max_snoozes_in_a_row: ?i32 = blk: {
            const value_as_string = std.mem.span(ui_options.max_snoozes_in_a_row[0..].ptr);
            if (value_as_string.len == 0) {
                break :blk null;
            }
            const error_message = &ui_options.errors.max_snoozes_in_a_row;
            const v = std.fmt.parseInt(i32, value_as_string, 10) catch |err| switch (err) {
                error.InvalidCharacter => {
                    error_message.* = "invalid character (must be blank or a number)";
                    break :blk null;
                },
                error.Overflow => {
                    error_message.* = "invalid amount (number too small or too large)";
                    break :blk null;
                },
            };
            if (v < 0 and v != UserConfig.Settings.MaxSnoozesDisabled) {
                error_message.* = "cannot be lower than 0, only -1 is allowed to disable snoozing completely";
                break :blk null;
            }
            break :blk v;
        };

        if (ui_options.os_startup) |os_startup| {
            switch (builtin.os.tag) {
                .windows => {
                    const temp_allocator = app.temp_allocator.allocator();
                    const startup_run = try winregistry.RegistryWtf8.openKey(std.os.windows.HKEY_CURRENT_USER, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", .{});
                    defer startup_run.closeKey();
                    if (!os_startup) {
                        startup_run.deleteValue(App.StartupRegistryKey) catch |err| switch (err) {
                            error.ValueNameNotFound => {}, // If entry doesn't exist, do nothing
                            else => return err,
                        };
                    } else {
                        const out_buf = try temp_allocator.alloc(u8, std.fs.max_path_bytes);
                        const exe_path = try std.fs.selfExePath(out_buf);
                        try startup_run.setString(App.StartupRegistryKey, exe_path);
                    }
                },
                else => {},
            }
        }

        // Check each field in errors (currently just assume '[]const u8' type)
        var has_error = false;
        inline for (std.meta.fields(@TypeOf(ui_options.errors))) |f| {
            const errorField = @field(ui_options.errors, f.name);
            has_error = has_error or errorField.len > 0;
        }
        if (!has_error) {
            // free allocated data that changed (strings)
            app.allocator.free(app.user_settings.settings.incoming_break_message);

            // update from fields / text
            app.user_settings.settings = .{
                .display_index = ui_options.display_index,
                .is_activity_break_enabled = ui_options.is_activity_break_enabled,
                .time_till_break = time_till_break,
                .break_time = break_time,
                .incoming_break = incoming_break,
                .incoming_break_message = try app.allocator.dupe(u8, incoming_break_message),
                .max_snoozes_in_a_row = max_snoozes_in_a_row,
            };

            // save
            try UserConfig.save(app.temp_allocator.allocator(), app.user_settings);

            // close
            app.ui.screen = .overview;
        }
    }
    imgui.igSameLine(0, 8);
    if (imgui.igButton("Cancel", .{})) {
        app.ui.screen = .overview;
    }
}
