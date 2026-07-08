const App = @import("App.zig");
const de = @import("de");
const sdl = de.sdl;
const builtin = @import("builtin");
const Timer = @import("Timer.zig");

platform: switch (builtin.os.tag) {
    .windows => DummyState, // Windows just relies on mouse for now
    .macos => MacState,
    .linux => if (!builtin.abi.isAndroid()) LinuxState else DummyState,
    else => DummyState,
},

pub fn init(id: *IdleDetection) void {
    return id.platform.init();
}

pub fn run(id: *IdleDetection, app: *App) void {
    id.platform.run();

    // TODO(jae): 2026-07-08
    // Factor this out better into its own platform code
    switch (id.idleState()) {
        .unknown => {
            if (app.has_global_mouse_support) {
                // Detect global mouse movement
                var curr_mouse_pos: de.Vector2f = undefined;
                _ = sdl.SDL_GetGlobalMouseState(&curr_mouse_pos.x, &curr_mouse_pos.y);
                const diff: de.Vector2f = .{
                    .x = @abs(curr_mouse_pos.x - app.prev_mouse_pos.x),
                    .y = @abs(curr_mouse_pos.y - app.prev_mouse_pos.y),
                };
                app.prev_mouse_pos = curr_mouse_pos;
                if (diff.x >= 5 and
                    diff.y >= 5)
                {
                    app.time_since_last_input = Timer.start();
                    app.is_user_active = true;
                    // log.info("mouse moved: {}, {}", .{ curr_mouse_pos.x, curr_mouse_pos.y });
                }
            }
        },
        .idle => {
            // do nothing if idling
        },
        .resumed => {
            app.time_since_last_input = Timer.start();
            app.is_user_active = true;
        },
    }
}

inline fn idleState(id: *const IdleDetection) State {
    return id.platform.idleState();
}

const MacState = struct {
    const macos_c = @import("macos_idletime");

    idle_time_in_seconds: i64,
    state: State,

    fn init(ms: *MacState) void {
        ms.* = .{
            .idle_time_in_seconds = macos_c.getSystemIdleTimeInSeconds(),
            .state = .unknown, // Update "state" immediately via "run" below
        };
        ms.run();
    }

    fn run(ms: *MacState) void {
        const new_idle_time_in_seconds = macos_c.getSystemIdleTimeInSeconds();
        if (new_idle_time_in_seconds == -1) {
            // NOTE(jae): 2026-07-08
            // I didn't observe this happening in my testing but just incase.
            ms.state = .unknown;
            return;
        }
        const old_idle_time_in_seconds = ms.idle_time_in_seconds;
        ms.idle_time_in_seconds = new_idle_time_in_seconds;
        if (new_idle_time_in_seconds == 0 or new_idle_time_in_seconds < old_idle_time_in_seconds) {
            ms.state = .resumed;
            return;
        }
        ms.state = .idle;
    }

    inline fn idleState(ms: *const MacState) State {
        return ms.state;
    }
};

const LinuxState = struct {
    const WaylandState = @import("WaylandState.zig");

    fn init(_: *LinuxState) void {}

    fn run(_: *LinuxState) void {}

    inline fn idleState(_: *const LinuxState) State {
        return switch (WaylandState.idleState()) {
            .unknown => .unknown,
            .idle => .idle,
            .resumed => .resumed,
        };
    }
};

const DummyState = struct {
    fn init(_: *DummyState) void {}

    fn run(_: *DummyState) void {}

    inline fn idleState(_: *const DummyState) State {
        return .unknown;
    }
};

pub const State = enum(u8) {
    /// unknown means that we can't detect if idle or not
    unknown = 0,
    /// idle means the last reported state was idle (ie. Wayland)
    idle = 1,
    /// resumed means the last reported state was resumed (ie. Wayland)
    resumed = 2,
};

const IdleDetection = @This();
