const std = @import("std");
const builtin = @import("builtin");
const wayland = if (builtin.os.tag == .linux) @import("wayland-gen.zig") else void;
const wl = wayland.client.wl;
const IdleNotifierV1 = wayland.client.ext.IdleNotifierV1;
const IdleNotificationV1 = wayland.client.ext.IdleNotificationV1;

const log = std.log.scoped(.wayland);

pub const IdleState = enum(u8) {
    /// unknown means that Wayland didn't initialize or we're on a non-Linux operating system
    unknown = 0,
    /// idle means the last reported state was idle from Wayland
    idle = 1,
    /// resumed means the last reported state was resumed from Wayland
    resumed = 2,
};

const WaylandNotifyState = struct {
    owned_display: ?*wl.Display = null,
    seat: ?*wl.Seat = null,
    idle_notifier: ?*IdleNotifierV1 = null,
    idle_notification: ?*IdleNotificationV1 = null,
    idle_state: std.atomic.Value(IdleState) = .init(.unknown),
};

var notify_state_data: WaylandNotifyState = .{};

pub const available = builtin.os.tag == .linux and !builtin.abi.isAndroid();

/// init our IdleNotification logic
/// Based on logic from: https://github.com/rcaelers/workrave/blob/main/libs/input-monitor/src/unix/WaylandInputMonitor.cc#L98C7-L98C22
pub fn init() error{ SdlFailed, IdleNotifierNotFound, RoundtripFailed, ConnectFailed, OutOfMemory, SeatNotFound }!void {
    const notify_state = &notify_state_data;

    // NOTE(jae): 2026-01-08
    // If I wanted, I could just use the existing display connection from SDL but
    // I see no reason to do that right now as we use 'x11' so that we can control
    // window placement.
    //
    // const sdl = @import("sdl");
    // const global_prop = sdl.SDL_GetGlobalProperties();
    // if (global_prop == 0) return error.SdlFailed;
    // const sdl_wl_display = sdl.SDL_GetPointerProperty(global_prop, sdl.SDL_PROP_GLOBAL_VIDEO_WAYLAND_WL_DISPLAY_POINTER, null) orelse {
    //     @panic("TODO: blah it was not found");
    // };

    const display = try wl.Display.connect(null);
    errdefer display.disconnect();

    const registry = try display.getRegistry();
    errdefer registry.destroy(); // NOTE: This won't be freed from memory until "display.disconnect" is called

    // Setup listener and then call "roundtrip" to trigger them
    registry.setListener(*WaylandNotifyState, handleGlobalListener, &notify_state_data);
    errdefer if (notify_state_data.idle_notifier) |idle_notifier| idle_notifier.destroy();
    errdefer if (notify_state_data.seat) |seat| seat.destroy();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    const idle_notifier = notify_state.idle_notifier orelse return error.IdleNotifierNotFound;
    const seat = notify_state_data.seat orelse return error.SeatNotFound;

    // TODO(jae): 2026-01-03
    // Consider fallback to older/other idle protocol depending on version
    // https://github.com/rcaelers/workrave/blob/main/libs/input-monitor/src/unix/WaylandInputMonitor.cc#L98C7-L98C22
    const idle_notification = try idle_notifier.getInputIdleNotification(1000, seat);
    notify_state.owned_display = display;
    notify_state.idle_notification = idle_notification;
    idle_notification.setListener(*WaylandNotifyState, handleIdleListener, notify_state);

    // if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    // const thread = try std.Thread.spawn(.{}, run_thread, .{notify_state});
    // notify_state.thread.thread = thread;
}

/// Returns .unknown on non-Linux operating systems and current idle state for Wayland
/// if the ext_idle_notifier protocol is supported
pub inline fn idleState() IdleState {
    if (available) {
        return notify_state_data.idle_state.load(.monotonic);
    }
    return .unknown;
}

/// processEvents will process events subscribed to like InputIdleNotification
pub fn processEvents() error{RoundtripFailed}!void {
    const owned_display = notify_state_data.owned_display orelse return;
    if (owned_display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
}

pub fn deinit() void {
    const notify_state = &notify_state_data;
    const owned_display = notify_state.owned_display orelse return;
    if (notify_state.idle_notification) |idle_notification| idle_notification.destroy();
    if (notify_state.idle_notifier) |idle_notifier| idle_notifier.destroy();
    if (notify_state.seat) |seat| seat.destroy();
    owned_display.disconnect();
}

// fn process_events_thread() !void {
//     const notify_state = &notify_state_data;
//     while (!notify_state.thread.aborted.load(.monotonic)) {
//         try process_events();
//     }
// }

fn handleGlobalListener(registry: *wl.Registry, event: wl.Registry.Event, notify_state: *WaylandNotifyState) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, IdleNotifierV1.interface.name) == .eq) {
                // Bind the ext_idle_notifier_v1 interface
                const idle_notifier = registry.bind(global.name, IdleNotifierV1, 2) catch {
                    // We catch this after our call to 'roundtrip'
                    return;
                };
                notify_state.idle_notifier = idle_notifier;
                return;
            }
            if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                const seat = registry.bind(global.name, wl.Seat, 1) catch {
                    // We catch this after our call to 'roundtrip'
                    return;
                };
                notify_state.seat = seat;
                seat.setListener(*WaylandNotifyState, handleSeatListener, notify_state);
                return;
            }
        },
        .global_remove => {}, // "THIS PAGE INTENTIONALLY LEFT BLANK."
    }
}

fn handleSeatListener(_: *wl.Seat, event: wl.Seat.Event, _: *WaylandNotifyState) void {
    switch (event) {
        .capabilities => |_| {
            // std.debug.print("Seat capabilities\n  Pointer {}\n  Keyboard {}\n  Touch {}\n", .{
            //     data.capabilities.pointer,
            //     data.capabilities.keyboard,
            //     data.capabilities.touch,
            // });
        },
        .name => {},
    }
}

fn handleIdleListener(_: *IdleNotificationV1, event: IdleNotificationV1.Event, notify_state: *WaylandNotifyState) void {
    switch (event) {
        .idled => {
            notify_state.idle_state.store(.idle, .monotonic);
        },
        .resumed => {
            notify_state.idle_state.store(.resumed, .monotonic);
        },
    }
}
