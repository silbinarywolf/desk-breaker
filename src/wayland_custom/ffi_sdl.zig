//! Use "ffi_import" to use custom loaded FFI functions with dlopen()

const posix = @import("std").posix;
const wayland = @import("wayland");

pub const sdl = struct {
    pub const loadSymbols = sdl_client.SDL_WAYLAND_LoadSymbols();
};

pub const client = struct {
    const wl = wayland.client.wl;
    const Argument = wl.Argument;
    const Interface = wl.Interface;
    const list = wl.list;

    pub inline fn wl_display_connect(name: ?[*:0]const u8) ?*wl.Display {
        return sdl_client.WAYLAND_wl_display_connect(name);
    }

    pub inline fn wl_display_disconnect(display: *wl.Display) void {
        return sdl_client.WAYLAND_wl_display_disconnect(display);
    }

    pub inline fn wl_proxy_get_user_data(proxy: *wl.Proxy) ?*anyopaque {
        return sdl_client.WAYLAND_wl_proxy_get_user_data(proxy);
    }

    pub inline fn wl_proxy_destroy(proxy: *wl.Proxy) void {
        return sdl_client.WAYLAND_wl_proxy_destroy(proxy);
    }

    pub inline fn wl_proxy_get_version(proxy: *wl.Proxy) u32 {
        return sdl_client.WAYLAND_wl_proxy_get_version(proxy);
    }

    pub inline fn wl_proxy_marshal_array_flags(proxy: *wl.Proxy, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, args: ?[*]Argument) ?*wl.Proxy {
        return sdl_client.WAYLAND_wl_proxy_marshal_array_flags(proxy, opcode, interface, version, flags, args);
    }

    pub inline fn wl_display_roundtrip(display: *wl.Display) c_int {
        return sdl_client.WAYLAND_wl_display_roundtrip(display);
    }

    pub inline fn wl_proxy_add_dispatcher(proxy: *wl.Proxy, dispatcher: *const wl.Proxy.DispatcherFn, implementation: ?*const anyopaque, data: ?*anyopaque) c_int {
        // NOTE(jae): 2026-07-05
        // SDL3 does not expose this, at least not currently.
        // "undefined symbol: WAYLAND_wl_proxy_add_dispatcher"
        // return sdl_client.WAYLAND_wl_proxy_add_dispatcher(display);
        return lib_client.wl_proxy_add_dispatcher(proxy, dispatcher, implementation, data);
    }
};

const sdl_client = struct {
    const wl = wayland.client.wl;

    extern fn SDL_WAYLAND_LoadSymbols() callconv(.c) bool;

    extern var WAYLAND_wl_display_connect: *const fn (name: [*c]const u8) callconv(.c) ?*wl.Display;
    extern var WAYLAND_wl_display_disconnect: *const fn (display: *wl.Display) callconv(.c) void;

    extern var WAYLAND_wl_proxy_destroy: *const fn (proxy: *wl.Proxy) callconv(.c) void;
    extern var WAYLAND_wl_proxy_get_version: *const fn (proxy: *wl.Proxy) callconv(.c) u32;
    extern var WAYLAND_wl_proxy_marshal_array_flags: *const fn (proxy: *wl.Proxy, opcode: u32, interface: ?*const wl.Interface, version: u32, flags: u32, args: ?[*]wl.Argument) callconv(.c) ?*wl.Proxy;
    extern var WAYLAND_wl_proxy_get_user_data: *const fn (proxy: *wl.Proxy) callconv(.c) ?*anyopaque;

    // NOTE(jae): 2026-07-05
    // SDL3 does not expose this, at least not currently.
    // "undefined symbol: WAYLAND_wl_proxy_add_dispatcher"
    // extern var WAYLAND_wl_proxy_add_dispatcher: *const fn (
    //     proxy: *wl.Proxy,
    //     dispatcher: *const wl.Proxy.DispatcherFn,
    //     implementation: ?*const anyopaque,
    //     data: ?*anyopaque,
    // ) callconv(.c) c_int;

    extern var WAYLAND_wl_display_roundtrip: *const fn (display: *wl.Display) callconv(.c) c_int;
};

const lib_client = struct {
    const wl = wayland.client.wl;
    extern fn wl_proxy_add_dispatcher(
        proxy: *wl.Proxy,
        dispatcher: *const wl.Proxy.DispatcherFn,
        implementation: ?*const anyopaque,
        data: ?*anyopaque,
    ) callconv(.c) c_int;
};

const unused_client = struct {
    const wl = wayland.client.wl;
    const Argument = wl.Argument;
    const Interface = wl.Interface;
    const list = wl.list;

    extern fn wl_display_cancel_read(display: *wl.Display) void;
    extern fn wl_display_connect_to_fd(fd: c_int) ?*wl.Display;
    extern fn wl_display_create_queue(display: *wl.Display) ?*wl.EventQueue;

    extern fn wl_display_dispatch_pending(display: *wl.Display) c_int;
    extern fn wl_display_dispatch_queue_pending(display: *wl.Display, queue: *wl.EventQueue) c_int;
    extern fn wl_display_dispatch_queue(display: *wl.Display, queue: *wl.EventQueue) c_int;
    extern fn wl_display_dispatch(display: *wl.Display) c_int;
    extern fn wl_display_flush(display: *wl.Display) c_int;
    extern fn wl_display_get_error(display: *wl.Display) c_int;
    extern fn wl_display_get_fd(display: *wl.Display) c_int;
    extern fn wl_display_prepare_read_queue(display: *wl.Display, queue: *wl.EventQueue) c_int;
    extern fn wl_display_prepare_read(display: *wl.Display) c_int;
    extern fn wl_display_read_events(display: *wl.Display) c_int;
    extern fn wl_display_roundtrip_queue(display: *wl.Display, queue: *wl.EventQueue) c_int;
    extern fn wl_event_queue_destroy(queue: *wl.EventQueue) void;
    extern fn wl_proxy_create(factory: *wl.Proxy, interface: *const Interface) ?*wl.Proxy;
    extern fn wl_proxy_get_id(proxy: *wl.Proxy) u32;
    extern fn wl_proxy_set_queue(proxy: *wl.Proxy, queue: *wl.EventQueue) void;
};
