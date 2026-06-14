//! These are root options configured in "root.de_options" of Zig main

application_type: type,
renderer_type: RendererType = .default,
platform_type: PlatformType = .sdl_callback,

pub const default: RootOptions = .{
    .application_type = void,
};

pub const RendererType = enum {
    default,
    software,
};

pub const PlatformType = enum {
    sdl_callback,
    sdl_zig,

    // pub const default: PlatformType = .sdl_callback;
};

pub const current: RootOptions = if (@hasDecl(@import("root"), "de_options"))
    @import("root").de_options
else
    .default;

const App = current.application_type;

const RootOptions = @This();
