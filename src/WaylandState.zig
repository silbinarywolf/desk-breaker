const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("de").sdl;

const has_wayland_support = builtin.os.tag == .linux and !builtin.abi.isAndroid();

const wayland = if (has_wayland_support) @import("wayland") else void;
const wl = wayland.client.wl;
const IdleNotifierV1 = wayland.client.ext.IdleNotifierV1;
const IdleNotificationV1 = wayland.client.ext.IdleNotificationV1;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.wayland);

/// NOTE(jae): 2026-07-05
/// Store wayland state globally for convenience for now
var wayland_state_data: WaylandState = .uninitialized;

initialized_dll: bool,
owned_display: ?*wl.Display,
seat: ?*wl.Seat,
idle_notifier: ?*IdleNotifierV1,
idle_notification: ?*IdleNotificationV1,
idle_state: std.atomic.Value(IdleState),

const uninitialized: WaylandState = .{
    .initialized_dll = false,
    .owned_display = null,
    .seat = null,
    .idle_notifier = null,
    .idle_notification = null,
    .idle_state = .init(.unknown),
};

pub const IdleState = enum(u8) {
    /// unknown means that Wayland didn't initialize or we're on a non-Linux operating system
    unknown = 0,
    /// idle means the last reported state was idle from Wayland
    idle = 1,
    /// resumed means the last reported state was resumed from Wayland
    resumed = 2,
};

const InitError = error{SdlFailed} ||
    Allocator.Error ||
    error{ IdleNotifierNotFound, RoundtripFailed, ConnectFailed, SeatNotFound };

pub inline fn init() InitError!void {
    if (!has_wayland_support) return;

    try initInner();
}

pub fn deinit() void {
    if (!has_wayland_support) return;

    const wayland_state = &wayland_state_data;
    if (!wayland_state.initialized_dll) return;
    const owned_display = wayland_state.owned_display orelse return;
    if (wayland_state.idle_notification) |idle_notification| idle_notification.destroy();
    if (wayland_state.idle_notifier) |idle_notifier| idle_notifier.destroy();
    if (wayland_state.seat) |seat| seat.destroy();
    owned_display.disconnect();
}

/// init our IdleNotification logic
/// Based on logic from: https://github.com/rcaelers/workrave/blob/main/libs/input-monitor/src/unix/WaylandInputMonitor.cc#L98C7-L98C22
fn initInner() InitError!void {
    wayland.ffi.load() catch |err| switch (err) {
        error.WaylandClientNotFound => {
            log.info("wayland-client.so not found, cannot detect using idle notify", .{});
            return;
        },
        error.WaylandClientFunctionNotFound => {
            log.err("wayland-client had missing functions, cannot use idle notify ", .{});
            return;
        },
        else => |serr| return serr,
    };

    const display = try wl.Display.connect(null);
    errdefer display.disconnect();

    const registry = try display.getRegistry();
    errdefer registry.destroy(); // NOTE: This won't be freed from memory until "display.disconnect" is called

    // Setup listener and then call "roundtrip" to trigger them
    const wayland_state = &wayland_state_data;
    wayland_state.initialized_dll = true;
    registry.setListener(*WaylandState, handleGlobalListener, &wayland_state_data);
    errdefer if (wayland_state.idle_notifier) |idle_notifier| idle_notifier.destroy();
    errdefer if (wayland_state.seat) |seat| seat.destroy();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    const idle_notifier = wayland_state.idle_notifier orelse return error.IdleNotifierNotFound;
    const seat = wayland_state.seat orelse return error.SeatNotFound;

    // TODO(jae): 2026-01-03
    // Consider fallback to older/other idle protocol depending on version
    // https://github.com/rcaelers/workrave/blob/main/libs/input-monitor/src/unix/WaylandInputMonitor.cc#L98C7-L98C22
    const idle_notification = try idle_notifier.getInputIdleNotification(1000, seat);
    wayland_state.owned_display = display;
    wayland_state.idle_notification = idle_notification;
    idle_notification.setListener(*WaylandState, handleIdleListener, wayland_state);
}

/// Returns .unknown on non-Linux operating systems and current idle state for Wayland
/// if the ext_idle_notifier protocol is supported
pub inline fn idleState() IdleState {
    if (!has_wayland_support) return .unknown;
    if (!wayland_state_data.initialized_dll) return .unknown;

    return wayland_state_data.idle_state.load(.monotonic);
}

/// processEvents will process events subscribed to like InputIdleNotification
pub fn processEvents() error{RoundtripFailed}!void {
    if (!has_wayland_support) return;
    if (!wayland_state_data.initialized_dll) return;

    const owned_display = wayland_state_data.owned_display orelse return;
    if (owned_display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
}

fn handleGlobalListener(registry: *wl.Registry, event: wl.Registry.Event, notify_state: *WaylandState) void {
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
                seat.setListener(*WaylandState, handleSeatListener, notify_state);
                return;
            }
        },
        .global_remove => {}, // "THIS PAGE INTENTIONALLY LEFT BLANK."
    }
}

fn handleSeatListener(_: *wl.Seat, event: wl.Seat.Event, _: *WaylandState) void {
    switch (event) {
        .capabilities => {
            // std.debug.print("Seat capabilities\n  Pointer {}\n  Keyboard {}\n  Touch {}\n", .{
            //     data.capabilities.pointer,
            //     data.capabilities.keyboard,
            //     data.capabilities.touch,
            // });
        },
        .name => {},
    }
}

fn handleIdleListener(_: *IdleNotificationV1, event: IdleNotificationV1.Event, notify_state: *WaylandState) void {
    switch (event) {
        .idled => {
            notify_state.idle_state.store(.idle, .monotonic);
        },
        .resumed => {
            notify_state.idle_state.store(.resumed, .monotonic);
        },
    }
}

const WaylandState = @This();
