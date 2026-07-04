//! These are root options configured in "root.de_options" of Zig main

application_type: type,
/// ie. "My Cool App 2: The Sqweequel"
application_name: [:0]const u8,
/// ie. 1.0.0beta5" or a git hash, or whatever makes sense
application_version: [:0]const u8,
/// ie. "com.example.mycoolapp2"
application_identifier: [:0]const u8,
window_constraint: WindowConstraint,
renderer_type: RendererType = .default,
platform_type: PlatformType = .sdl_callback,
imgui: ImGuiOptions = .{},

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

pub const WindowConstraint = enum(u1) {
    /// For games and applications that only create 1 window for the lifetime
    /// of the application
    single_window,
    /// For applications that need control over multiple window creation.
    /// Force use of XWayland/X11 backend for Linux operating systems.
    multiple_window,
};

pub const ImGuiOptions = struct {
    default_font_size: u16 = 24,
};

/// Alias for @import("root").de_options, if they are set.
pub const current: RootOptions = if (@hasDecl(@import("root"), "de_options"))
    @import("root").de_options
else
    .default;

const App = current.application_type;

const RootOptions = @This();
