//! Based on: https://github.com/TylerGlaiel/FrameTimingControl/blob/master/frame_timer.cpp
//! From blog post: https://medium.com/@tglaiel/how-to-make-your-game-run-at-60fps-24c61210fe75

const de = @import("de.zig");
const sdl = @import("de.zig").sdl;
const StaticRingBuffer = de.StaticRingBuffer;

const log = @import("std").log.scoped(.frame_timer);

/// Tick rate (60 = 60 ticks per second)
update_rate: u24,
/// ie. 16 for 60 FPS
milliseconds_per_frame: u8,
/// Defaults to:
/// -    10_000_000 on Windows
/// - 1_000_000_000 on Linux
clocks_per_second: u32,
/// ie. 60fps = 0.0166666666667
fixed_delta_time: f32,
/// Defaults to 1, unlocked frame rate only, increase for test code running fast simulation
update_multiplicity: u24,
/// ie. 60fps = 166_666 (Windows) or 16_666_666 (Linux)
desired_frametime: u32,
frame_rate_type: Type,
/// clocks_per_second / 5000 = 2000 (Windows) or 200_000 (Linux)
vsync_max_error: u64,
snap_frequencies: [8]u32,
time_averager: de.StaticRingBuffer(u32, 4),
averager_residual: u32,
/// Update in beforeUpdate method
prev_frame_time: u64,
frame_accumulator: u64,
/// Store each frame for SDL_Delay
start_frame_time_for_os_delay: u64,

// frame

/// used by unlocked frame-rate to track variable-timestep update
delta_time: u32,
trigger_resync: bool,

pub const Options = struct {
    /// Tick rate (60 = 60 ticks per second)
    update_rate: u24,
    frame_rate_type: Type,
    /// Defaults to 1, increase for test code running fast simulation
    update_multiplicity: u24 = 1,
};

const Type = enum {
    /// Locked frame rate, No interpolation
    locked,
    /// Unlocked frame rate, Interpolation
    unlocked,
};

pub fn init(options: Options) FrameTimer {
    const clocks_per_second: u32 = @intCast(sdl.SDL_GetPerformanceFrequency());
    const prev_frame_time = sdl.SDL_GetPerformanceCounter();
    // TODO: Compute hz from the current Window
    // const display_mode = sdl.SDL_GetCurrentDisplayMode(0);
    return .{
        .update_rate = options.update_rate,
        .milliseconds_per_frame = @intCast(@divFloor(1000, options.update_rate)),
        .clocks_per_second = clocks_per_second,
        .fixed_delta_time = 1.0 / @as(f32, options.update_rate),
        .update_multiplicity = options.update_multiplicity,
        .frame_rate_type = options.frame_rate_type,
        .desired_frametime = clocks_per_second / options.update_rate,
        .vsync_max_error = @divFloor(clocks_per_second, 5000), // clocks_per_second * 0.0002,
        // TODO: Compute hz from the current Window
        .snap_frequencies = getSnapFrequencies(clocks_per_second, 0),
        .time_averager = .empty,
        .averager_residual = 0,
        .prev_frame_time = prev_frame_time,
        .frame_accumulator = 0,
        .trigger_resync = false,
        .delta_time = undefined,
        .start_frame_time_for_os_delay = undefined,
    };
}

pub fn beforeUpdate(ft: *FrameTimer) !void {
    // Store time taken in frame/iteration
    ft.start_frame_time_for_os_delay = sdl.SDL_GetTicks();

    // Update delta time
    var delta_time: u32 = blk: {
        const current_frame_time = sdl.SDL_GetPerformanceCounter();
        var dt = current_frame_time -| ft.prev_frame_time; // using '-|' is saturating subtraction, clamps at 0 for unsigned integer
        ft.prev_frame_time = current_frame_time;
        // Handle unexpected time anomalies like overflow, extra slow frames
        //
        // NOTE(jae): 2026-05-05
        // Cap the value here before we cast to u32 so it'll definitely
        // fit
        if (dt > ft.desired_frametime * 8) {
            dt = ft.desired_frametime;
        }
        break :blk @intCast(dt);
    };

    // Vsync time snapping
    for (ft.snap_frequencies) |snap| {
        // using '-|' is saturating subtraction, clamps at 0 for unsigned integer
        if (@abs(delta_time -| snap) < ft.vsync_max_error) {
            delta_time = snap;
            break;
        }
    }

    // Delta time averaging
    ft.time_averager.push(delta_time);

    const averager_sum = blk: {
        var sum: u32 = 0;
        var it = ft.time_averager.iterator();
        while (it.next()) |v| {
            sum += v;
        }
        break :blk sum;
    };
    delta_time = averager_sum / ft.time_averager.len;

    ft.averager_residual += averager_sum % ft.time_averager.len;
    delta_time += ft.averager_residual / ft.time_averager.len;
    ft.averager_residual %= ft.time_averager.len;

    // Add delta time to frame accumulator
    {
        ft.frame_accumulator += delta_time;

        // Spiral of death protection
        if (ft.frame_accumulator > ft.desired_frametime * 8) {
            ft.trigger_resync = true;
        }

        // Handle resync
        if (ft.trigger_resync) {
            ft.frame_accumulator = 0;
            delta_time = ft.desired_frametime;
            ft.trigger_resync = false;
        }
    }

    ft.delta_time = delta_time;
}

pub fn callFixedAndVariableUpdate(frame_timer: *FrameTimer, app: anytype) !void {
    const AppType = @TypeOf(app);
    const App = switch (@typeInfo(AppType)) {
        .pointer => |info| info.child,
        else => @compileError("expected pointer type but got " ++ @typeName(AppType)),
    };
    switch (frame_timer.frame_rate_type) {
        .unlocked => {
            var consumed_delta_time = frame_timer.delta_time;
            const fixed_delta_time = frame_timer.fixed_delta_time;
            while (frame_timer.frame_accumulator >= frame_timer.desired_frametime) {
                try App.onFixedUpdate(FixedUpdate{
                    .delta_time = fixed_delta_time,
                }, app);
                if (consumed_delta_time > frame_timer.desired_frametime) { //cap variable update's dt to not be larger than fixed update, and interleave it (so game state can always get animation frames it needs)
                    try App.onVariableUpdate(VariableUpdate{
                        .delta_time = fixed_delta_time,
                    }, app);
                    consumed_delta_time -= frame_timer.desired_frametime;
                }
                frame_timer.frame_accumulator -= frame_timer.desired_frametime;
            }
            const variable_update_arg = VariableUpdate{
                .delta_time = @floatCast(@as(f64, consumed_delta_time) / @as(f64, frame_timer.clocks_per_second)),
            };
            try App.onVariableUpdate(variable_update_arg, app);
            // TODO: Handle interpolation in render() function
            // ie. game.render((double)frame_accumulator / desired_frametime);
            log.err("TODO: handle interpolation in onDraw arg", .{});
        },
        .locked => {
            var it = frame_timer.lockedFrameIterator();
            while (it.next()) {
                try App.onFixedUpdate(FixedUpdate{
                    .delta_time = frame_timer.fixed_delta_time,
                }, app);
                try App.onVariableUpdate(VariableUpdate{
                    .delta_time = frame_timer.fixed_delta_time,
                }, app);
            }
        },
    }
}

/// Calls SDL_Delay / sleep function
pub fn delay(frame_timer: *const FrameTimer) void {
    const end_frame_time = sdl.SDL_GetTicks();
    const milliseconds_passed_this_frame: u32 = @intCast(end_frame_time -| frame_timer.start_frame_time_for_os_delay); // using '-|' is saturating subtraction, clamps at 0 for unsigned integer
    const scheduler_drift = 2; // N milliseconds are taken of SDL_Delay to account for imprecision with scheduler
    const delay_in_milliseconds = frame_timer.milliseconds_per_frame -| (milliseconds_passed_this_frame + scheduler_drift);
    if (delay_in_milliseconds > 0) {
        // log.debug("waiting ms: {}, time: {d:2}", .{ delay_in_milliseconds, frame_timer.frame_accumulator });
        sdl.SDL_Delay(delay_in_milliseconds);
    }
}

pub fn lockedFrameIterator(ft: *FrameTimer) LockedFrameIterator {
    return .{
        .ft = ft,
        .update_multiplicity_index = 0,
    };
}

pub const LockedFrameIterator = struct {
    ft: *FrameTimer,
    update_multiplicity_index: u24,

    pub fn next(it: *LockedFrameIterator) bool {
        const ft = it.ft;
        if (ft.frame_accumulator < ft.desired_frametime * ft.update_multiplicity) return false;
        if (it.update_multiplicity_index >= ft.update_multiplicity) return false;
        ft.frame_accumulator -= ft.desired_frametime;
        it.update_multiplicity_index += 1;
        return true;
    }
};

fn getSnapFrequencies(clocks_per_second: u32, refresh_rate: u24) [8]u32 {
    // Get the refresh rate of the display
    const snap_hz: u24 = if (refresh_rate > 0)
        refresh_rate
    else
        // Default to 60hz
        60;

    // These are to snap deltaTime to vsync values if it's close enough
    var snap_frequencies: [8]u32 = undefined;
    var i: u32 = 0;
    for (0..snap_frequencies.len) |_| {
        snap_frequencies[i] = (clocks_per_second / snap_hz) * (i + 1);
        i += 1;
    }
    return snap_frequencies;
}

pub const FixedUpdate = struct {
    delta_time: f32,
};

pub const VariableUpdate = struct {
    delta_time: f32,
};

const FrameTimer = @This();
