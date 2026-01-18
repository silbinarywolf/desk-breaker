const std = @import("std");
const sdl = @import("sdl");
const time = std.time;

started: i64,
previous: i64,

pub const none: Timer = .{
    .started = std.math.minInt(i64),
    .previous = std.math.minInt(i64),
};

pub fn start() error{TimerUnsupported}!Timer {
    var ticks: i64 = undefined;
    if (!sdl.SDL_GetCurrentTime(&ticks)) return Timer.none;
    return Timer{ .started = ticks, .previous = ticks };
}

/// Resets the timer value to 0/now.
pub fn reset(self: *Timer) void {
    const current = self.sample();
    self.started = @intCast(current);
}

pub fn read(self: *Timer) u64 {
    const current = self.sample();
    // Timestamps are directly in nanoseconds
    return @intCast(@as(i64, @intCast(current)) - self.started);
}

/// Returns an Instant sampled at the callsite that is
/// guaranteed to be monotonic with respect to the timer's starting point.
fn sample(self: *Timer) u64 {
    var current: i64 = undefined;
    if (!sdl.SDL_GetCurrentTime(&current)) unreachable;

    if (std.math.order(current, self.previous) == .gt) {
        self.previous = current;
    }
    return @intCast(self.previous);
}

const Timer = @This();
