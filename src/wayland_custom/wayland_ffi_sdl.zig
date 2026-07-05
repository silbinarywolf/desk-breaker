//! Using sdl.SDL_LoadLibrary, load "wayland-client" as a DLL to get support for idle-notify
//! without linking against wayland-client.

const posix = @import("std").posix;
const wayland = @import("wayland");
const sdl = @import("sdl");

pub const Error = error{
    WaylandClientNotFound,
    WaylandClientFunctionNotFound,
};

var wayland_client: WaylandClient = undefined;

/// Load wayland-client as a DLL
pub fn load() Error!void {
    const wayland_dyn = DynLib.open("libwayland-client.so.0") catch return error.WaylandClientNotFound;
    errdefer wayland_dyn.close();
    wayland_client = try loadWaylandClient(wayland_dyn);
}

fn loadWaylandClient(so: *DynLib) error{WaylandClientFunctionNotFound}!WaylandClient {
    return .{
        .handle = so,
        .wl_display_connect = so.lookup(types.wl_display_connect, "wl_display_connect") orelse
            return error.WaylandClientFunctionNotFound,
        .wl_display_disconnect = so.lookup(types.wl_display_disconnect, "wl_display_disconnect") orelse
            return error.WaylandClientFunctionNotFound,
        .wl_display_roundtrip = so.lookup(types.wl_display_roundtrip, "wl_display_roundtrip") orelse
            return error.WaylandClientFunctionNotFound,
        .wl_proxy_get_user_data = so.lookup(types.wl_proxy_get_user_data, "wl_proxy_get_user_data") orelse
            return error.WaylandClientFunctionNotFound,
        .wl_proxy_destroy = so.lookup(types.wl_proxy_destroy, "wl_proxy_destroy") orelse
            return error.WaylandClientFunctionNotFound,
        .wl_proxy_get_version = so.lookup(types.wl_proxy_get_version, "wl_proxy_get_version") orelse
            return error.WaylandClientFunctionNotFound,
        .wl_proxy_marshal_array_flags = so.lookup(types.wl_proxy_marshal_array_flags, "wl_proxy_marshal_array_flags") orelse
            return error.WaylandClientFunctionNotFound,
        .wl_proxy_add_dispatcher = so.lookup(types.wl_proxy_add_dispatcher, "wl_proxy_add_dispatcher") orelse
            return error.WaylandClientFunctionNotFound,
    };
}

const WaylandClient = struct {
    handle: *DynLib,
    wl_display_connect: types.wl_display_connect,
    wl_display_disconnect: types.wl_display_disconnect,
    wl_display_roundtrip: types.wl_display_roundtrip,
    wl_proxy_get_user_data: types.wl_proxy_get_user_data,
    wl_proxy_destroy: types.wl_proxy_destroy,
    wl_proxy_get_version: types.wl_proxy_get_version,
    wl_proxy_marshal_array_flags: types.wl_proxy_marshal_array_flags,
    wl_proxy_add_dispatcher: types.wl_proxy_add_dispatcher,
};

const DynLib = opaque {
    fn open(name: [:0]const u8) error{FileNotFound}!*DynLib {
        const so_handle = sdl.SDL_LoadObject(name) orelse return error.FileNotFound;
        return @ptrCast(so_handle);
    }

    fn close(self: *DynLib) void {
        const shared_lib: *sdl.SDL_SharedObject = @ptrCast(self);
        sdl.SDL_UnloadObject(shared_lib);
    }

    fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        const shared_lib: *sdl.SDL_SharedObject = @ptrCast(self);
        const untyped_func_ptr = sdl.SDL_LoadFunction(shared_lib, name) orelse return null;
        return @ptrCast(untyped_func_ptr);
    }
};

pub const client = struct {
    const wl = wayland.client.wl;
    const Argument = wl.Argument;
    const Interface = wl.Interface;
    const list = wl.list;

    pub inline fn wl_display_connect(name: ?[*:0]const u8) ?*wl.Display {
        return wayland_client.wl_display_connect(name);
    }

    pub inline fn wl_display_disconnect(display: *wl.Display) void {
        return wayland_client.wl_display_disconnect(display);
    }

    pub inline fn wl_display_roundtrip(display: *wl.Display) c_int {
        return wayland_client.wl_display_roundtrip(display);
    }

    pub inline fn wl_proxy_get_user_data(proxy: *wl.Proxy) ?*anyopaque {
        return wayland_client.wl_proxy_get_user_data(proxy);
    }

    pub inline fn wl_proxy_destroy(proxy: *wl.Proxy) void {
        return wayland_client.wl_proxy_destroy(proxy);
    }

    pub inline fn wl_proxy_get_version(proxy: *wl.Proxy) u32 {
        return wayland_client.wl_proxy_get_version(proxy);
    }

    pub inline fn wl_proxy_marshal_array_flags(proxy: *wl.Proxy, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, args: ?[*]Argument) ?*wl.Proxy {
        return wayland_client.wl_proxy_marshal_array_flags(proxy, opcode, interface, version, flags, args);
    }

    pub inline fn wl_proxy_add_dispatcher(proxy: *wl.Proxy, dispatcher: *const wl.Proxy.DispatcherFn, implementation: ?*const anyopaque, data: ?*anyopaque) c_int {
        // NOTE(jae): 2026-07-05
        // SDL3 does not expose this, at least not currently.
        // "undefined symbol: WAYLAND_wl_proxy_add_dispatcher"
        // return sdl_client.WAYLAND_wl_proxy_add_dispatcher(display);
        return wayland_client.wl_proxy_add_dispatcher(proxy, dispatcher, implementation, data);
    }
};

const types = struct {
    const wl = wayland.client.wl;
    const wl_display_connect = *const fn (name: [*c]const u8) callconv(.c) ?*wl.Display;
    const wl_display_disconnect = *const fn (display: *wl.Display) callconv(.c) void;

    const wl_proxy_destroy = *const fn (proxy: *wl.Proxy) callconv(.c) void;
    const wl_proxy_get_version = *const fn (proxy: *wl.Proxy) callconv(.c) u32;
    const wl_proxy_marshal_array_flags = *const fn (proxy: *wl.Proxy, opcode: u32, interface: ?*const wl.Interface, version: u32, flags: u32, args: ?[*]wl.Argument) callconv(.c) ?*wl.Proxy;
    const wl_proxy_get_user_data = *const fn (proxy: *wl.Proxy) callconv(.c) ?*anyopaque;
    const wl_proxy_add_dispatcher = *const fn (
        proxy: *wl.Proxy,
        dispatcher: *const wl.Proxy.DispatcherFn,
        implementation: ?*const anyopaque,
        data: ?*anyopaque,
    ) callconv(.c) c_int;

    const wl_display_roundtrip = *const fn (display: *wl.Display) callconv(.c) c_int;
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
