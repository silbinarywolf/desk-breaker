//! User configuration files loading/saving

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const time = std.time;
const mem = std.mem;
const testing = std.testing;

const App = @import("App.zig");
const UserSettings = App.UserSettings;
const StateTimer = App.Timer;
const TimerKind = App.TimerKind;

const Duration = @import("Duration.zig");

const CurrentVersion = 2;

const CanLoadConfig = builtin.os.tag != .emscripten and !builtin.abi.isAndroid();

/// PartialVersion is used to deserialize just the "version" field first
const PartialVersion = struct {
    version: u32,
};

/// UserConfig version 1
pub const Version1 = struct {
    version: u32 = 1,
    display_index: u32 = 0,
    activity_timer: struct {
        is_enabled: bool = true,
        time_till_break: ?Duration = null,
        break_time: ?Duration = null,
    },
    timers: []UserConfig.Timer,
};

pub const Timer = struct {
    kind: TimerKind,

    // Common
    name: [:0]const u8,

    // Timer
    timer_duration: ?Duration = null,

    // Alarm
    // alarm_time: ?Time = null,

    // // ActivityBreak
    // time_till_break: Duration = Duration.init(30 * time.ns_per_min),
    // break_time: Duration = Duration.init(5 * time.ns_per_min),
};

/// This maps to data saved into config.json and can be naively used with Zig's JSON decoder
pub const Settings = struct {
    pub const MaxSnoozesDisabled: i32 = -1;

    /// this is the monitor to display on
    display_index: u32 = 0,
    is_activity_break_enabled: bool = true,
    time_till_break: ?Duration = null,
    break_time: ?Duration = null,
    // the amount of warning you get before the fullscreen popup appears
    incoming_break: ?Duration = null,
    // customized incoming break message underneath the pending timer
    incoming_break_message: []const u8 = &[0]u8{},
    // maximum times you can hit snooze in a row
    // set to -1 to disable
    max_snoozes_in_a_row: ?i32 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.incoming_break_message);
        self.* = undefined;
    }
};

version: u32 = CurrentVersion,
settings: Settings = .{},
timers: []Timer,

const LoadError = std.fs.File.OpenError ||
    DataDirPathError ||
    std.fs.File.GetSeekPosError ||
    std.posix.ReadError ||
    std.json.ParseError(std.json.Scanner) ||
    error{InvalidConfigVersion};

pub fn load(allocator: std.mem.Allocator) LoadError!UserSettings {
    if (builtin.os.tag == .freestanding or builtin.abi == .none) {
        return error.FileNotFound;
    }

    const path = get_data_dir_path(allocator) catch |err| switch (err) {
        error.AppDataDirUnavailable => {
            // If missing $HOME environment variable and not in portable mode
            // then assume we cannot find the config file.
            return error.FileNotFound;
        },
        else => return err,
    };
    defer allocator.free(path);

    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();

    var file = try dir.openFile("config.json", .{});
    defer file.close();
    const stat_size = std.math.cast(usize, try file.getEndPos()) orelse return error.FileTooBig;
    var config_file_data = try allocator.alloc(u8, stat_size);
    const read_all_size = try file.readAll(config_file_data);
    config_file_data = config_file_data[0..read_all_size];
    defer allocator.free(config_file_data);

    const file_version = verblk: {
        const version_parsed = try std.json.parseFromSlice(PartialVersion, allocator, config_file_data, .{
            .ignore_unknown_fields = true,
        });
        defer version_parsed.deinit();
        break :verblk version_parsed.value.version;
    };

    switch (file_version) {
        1 => {
            // Old format
            const userconfig_parsed = try std.json.parseFromSlice(Version1, allocator, config_file_data, .{});
            defer userconfig_parsed.deinit();
            const userconfig: *const Version1 = &userconfig_parsed.value;

            var user_settings: UserSettings = .{
                .settings = .{
                    .display_index = userconfig.display_index,
                    .is_activity_break_enabled = userconfig.activity_timer.is_enabled,
                    .break_time = userconfig.activity_timer.break_time,
                    .time_till_break = userconfig.activity_timer.time_till_break,
                },
                .timers = try std.ArrayList(StateTimer).initCapacity(allocator, userconfig.timers.len),
            };
            for (userconfig.timers) |*t| {
                try user_settings.timers.append(allocator, .{
                    .kind = t.kind,
                    .name = try allocator.dupeZ(u8, t.name),
                    .timer_duration = t.timer_duration,
                });
            }
            return user_settings;
        },
        CurrentVersion => {
            const userconfig_parsed = try std.json.parseFromSlice(UserConfig, allocator, config_file_data, .{});
            defer userconfig_parsed.deinit();
            const userconfig = &userconfig_parsed.value;

            var user_settings: UserSettings = .{
                .settings = userconfig.settings,
                .timers = try std.ArrayList(StateTimer).initCapacity(allocator, userconfig.timers.len),
            };

            // Copy memory from JSON memory
            user_settings.settings.incoming_break_message = try allocator.dupe(u8, userconfig.settings.incoming_break_message);

            // Copy timers
            for (userconfig.timers) |*t| {
                try user_settings.timers.append(allocator, .{
                    .kind = t.kind,
                    .name = try allocator.dupeZ(u8, t.name),
                    .timer_duration = t.timer_duration,
                });
            }
            return user_settings;
        },
        else => return error.InvalidConfigVersion,
    }
    unreachable;
}

pub fn save(allocator: std.mem.Allocator, user_settings: *const UserSettings) !void {
    const path = get_data_dir_path(allocator) catch |err| switch (err) {
        error.AppDataDirUnavailable => {
            // If unavailable like on Android, do nothing
            return;
        },
        else => return err,
    };
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
    var timers = try std.ArrayList(Timer).initCapacity(allocator, user_settings.timers.items.len);
    for (user_settings.timers.items) |*t| {
        switch (t.kind) {
            .timer => {
                try timers.append(allocator, .{
                    .kind = t.kind,
                    .name = t.name,
                    .timer_duration = t.timer_duration,
                });
            },
            .alarm => {
                @panic("TODO: handle saving alarm");
            },
        }
    }
    var user_config: UserConfig = .{
        .settings = user_settings.settings,
        .timers = timers.items,
    };

    const json_data = try std.json.Stringify.valueAlloc(allocator, &user_config, .{
        .whitespace = .indent_tab,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(json_data);
    try dir.writeFile(.{
        .sub_path = "config.json",
        .data = json_data,
    });
}

const DataDirPathError = std.fs.GetAppDataDirError || std.fs.SelfExePathError || std.fs.File.OpenError || std.mem.Allocator.Error;

/// If "portable_mode_enabled" exists alongside binary then save in "%EXE_DIR%/userdata"
/// returns slice that is owned by the caller and should be freed by them
pub fn get_data_dir_path(allocator: mem.Allocator) DataDirPathError![]const u8 {
    if (!CanLoadConfig) {
        // If not supported by platform/OS like Emscripten or Android
        return error.AppDataDirUnavailable;
    }
    const out_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
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

const UserConfig = @This();
