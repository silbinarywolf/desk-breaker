const std = @import("std");
const time = std.time;
const mem = std.mem;
const testing = std.testing;

const State = @import("state.zig").State;
const Timer = @import("state.zig").Timer;
const TimerKind = @import("state.zig").TimerKind;
const Duration = @import("time.zig").Duration;

const UserTimer = struct {
    kind: TimerKind,

    // Common
    name: []const u8,

    // Timer
    timer_duration: ?Duration = null,

    // Alarm
    // alarm_time: ?Time = null,

    // // ActivityBreak
    // time_till_break: Duration = Duration.init(30 * time.ns_per_min),
    // break_time: Duration = Duration.init(5 * time.ns_per_min),
};

pub const UserConfig = struct {
    version: u32 = 1,
    activity_timer: struct {
        is_enabled: bool = true,
        time_till_break: ?Duration = null,
        break_time: ?Duration = null,
    },
    timers: []UserTimer,
};

pub fn save_config_file(allocator: std.mem.Allocator, state: *State) !void {
    const path = try get_data_dir_path(allocator);
    defer allocator.free(path);

    var dir = blk: {
        const userdata_dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try std.fs.makeDirAbsolute(path);
                break :blk try std.fs.openDirAbsolute(path, .{});
            },
            else => return err,
        };
        break :blk userdata_dir;
    };
    defer dir.close();

    // Build user config
    var timers = try std.ArrayList(UserTimer).initCapacity(allocator, state.timers.items.len);
    for (state.timers.items) |*t| {
        switch (t.kind) {
            .timer => {
                try timers.append(.{
                    .kind = t.kind,
                    .name = t.name.slice(),
                    .timer_duration = t.timer_duration,
                });
            },
            .alarm => {
                @panic("TODO: handle saving alarm");
            },
        }
    }
    var user_config: UserConfig = .{
        .activity_timer = .{
            .is_enabled = state.user_settings.is_activity_break_enabled,
            .break_time = state.user_settings.break_time,
            .time_till_break = state.user_settings.time_till_break,
        },
        .timers = timers.items,
    };
    const json_data = try std.json.stringifyAlloc(allocator, &user_config, .{
        .whitespace = .indent_tab,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(json_data);
    try dir.writeFile(.{
        .sub_path = "config.json",
        .data = json_data,
    });
}

pub fn load_config_file(allocator: std.mem.Allocator, state: *State) !void {
    const path = try get_data_dir_path(allocator);
    defer allocator.free(path);

    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();

    const config_file_data = try dir.readFileAlloc(allocator, "config.json", 1024 * 1024 * 1024);
    defer allocator.free(config_file_data);

    const userconfig_parsed = try load_user_config(allocator, config_file_data);
    defer userconfig_parsed.deinit();

    const userconfig = &userconfig_parsed.value;
    state.user_settings.is_activity_break_enabled = userconfig.activity_timer.is_enabled;
    state.user_settings.break_time = userconfig.activity_timer.break_time;
    state.user_settings.time_till_break = userconfig.activity_timer.time_till_break;
    state.timers.clearRetainingCapacity();
    for (userconfig.timers) |*t| {
        try state.timers.append(.{
            .kind = t.kind,
            .name = try Timer.Name.fromSlice(t.name),
            .timer_duration = t.timer_duration,
        });
    }
}

fn load_user_config(allocator: std.mem.Allocator, config_file_data: []const u8) !std.json.Parsed(UserConfig) {
    const config_data = try std.json.parseFromSlice(UserConfig, allocator, config_file_data, .{});
    return config_data;
}

/// If "portable_mode_enabled" exists alongside binary then save in "%EXE_DIR%/userdata"
/// returns slice that is owned by the caller and should be freed by them
pub fn get_data_dir_path(allocator: mem.Allocator) ![]const u8 {
    const out_buf = try allocator.alloc(u8, std.fs.MAX_PATH_BYTES);
    defer allocator.free(out_buf);
    const path = try std.fs.selfExeDirPath(out_buf);

    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();

    // check if portable mode
    var is_portable_mode = true;
    _ = dir.statFile("portable_mode_enabled") catch {
        is_portable_mode = false;
    };

    // If portable create: "userdata" in same folder as EXE
    if (is_portable_mode) {
        return std.fs.path.join(allocator, &[_][]const u8{ path, "userdata" });
    }

    const userdir_path = try std.fs.getAppDataDir(allocator, "DeskBreaker");
    return userdir_path;
}
