const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options.zig");
const Allocator = @import("std").mem.Allocator;
const Vector2i = @import("vector.zig").Vector2i;
const Vector2us = @import("vector.zig").Vector2us;

const sdl = @import("sdl");

const log = std.log.scoped(.Window);
const assert = std.debug.assert;

pub const Options = struct {
    title: [:0]const u8 = &[0:0]u8{},
    pos: ?Vector2i = null,
    size: Size = .default,
    resizeable: bool = false,
    /// SDL3: SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN defaults to true
    focusable: ?bool = null,
    borderless: bool = false,
    always_on_top: bool = false,
    /// Starts window with grabbed mouse focus
    mouse_grabbed: bool = false,
    icon: ?*sdl.SDL_Surface = null,
    // NOTE(jae): 2025-12-27
    // Attempt to have the *audacity* on my own computer to get a
    // a window to pop up in the right-bottom corner of the screen with Linux/Wayland (and fail)
    // (Tried to use Wayland Popup Windows to do this)
    // parent: ?*Window = null,
};

pub const Size = union(enum) {
    default: void,
    /// Take up as much screen as possible while accounting for taskbars (Windows/Linux), top menu bars / bottom application bar (Mac)
    maximized: void,
    /// Take up the entire screen
    windowed_fullscreen: void,
    /// Take up half of the screen (Try to account for 240p intervals (480p, 720p, 1080p, 4K))
    windowed_halfscreen: void,
    // windowed_scale: WindowedScale,
    pixels: Vector2us,
};

// const WindowedScale = struct {
//     aspect_ratio_width: u8,
//     aspect_ratio_height: u8,
//     reduced_by_multiplier: u8,
// };

internal: *sdl.SDL_Window,
properties: sdl.SDL_PropertiesID,

const InitWindowError = error{SdlFailed};

pub fn init(options: Options) InitWindowError!SdlWindow {
    const props = sdl.SDL_CreateProperties();
    if (props == 0) return error.SdlFailed;
    errdefer sdl.SDL_DestroyProperties(props);

    if (options.title.len > 0) if (!sdl.SDL_SetStringProperty(props, sdl.SDL_PROP_WINDOW_CREATE_TITLE_STRING, options.title)) return error.SdlFailed;
    if (options.resizeable) if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN, true)) return error.SdlFailed;
    if (options.focusable) |f| if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, f)) return error.SdlFailed;
    if (options.borderless) if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_BORDERLESS_BOOLEAN, true)) return error.SdlFailed;
    if (options.always_on_top) if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_ALWAYS_ON_TOP_BOOLEAN, true)) return error.SdlFailed;
    if (options.mouse_grabbed) if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_MOUSE_GRABBED_BOOLEAN, true)) return error.SdlFailed;
    if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true)) return error.SdlFailed;
    // NOTE(jae): 2025-12-27
    // Attempt to have the *audacity* on my own computer to get a
    // a window to pop up in the right-bottom corner of the screen with Linux/Wayland (and fail)
    // (Tried to use Wayland Popup Windows to do this)
    // if (options.parent) |parent| {
    //     if (!sdl.SDL_SetPointerProperty(props, sdl.SDL_PROP_WINDOW_CREATE_PARENT_POINTER, parent.window)) return error.SdlFailed;
    //     if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_CONSTRAIN_POPUP_BOOLEAN, false)) return error.SdlFailed;
    //     if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_TOOLTIP_BOOLEAN, true)) return error.SdlFailed;
    // }

    const display_id = sdl.SDL_GetPrimaryDisplay();
    if (display_id == 0) return error.SdlFailed;
    const main_scale = sdl.SDL_GetDisplayContentScale(display_id);
    if (main_scale == 0.0) return error.SdlFailed;
    // const pixel_density = sdl.SDL_GetWindowPixelDensity(window_id); // ie. MacOS Retina screens
    // if (pixel_density == 0.0) return error.SdlFailed;

    var window_pos: ?Vector2i = null;
    var window_size: ?Vector2us = null;
    switch (options.size) {
        .default, .maximized => {
            var rect: sdl.SDL_Rect = undefined;
            if (!sdl.SDL_GetDisplayUsableBounds(display_id, &rect)) return error.SdlFailed;
            if (rect.x != 0 or rect.y != 0) {
                window_pos = .{
                    .x = @intCast(rect.x),
                    .y = @intCast(rect.y),
                };
            }
            window_size = .{
                .x = @intCast(rect.w),
                .y = @intCast(rect.h),
            };
        },
        .windowed_fullscreen => {
            var rect: sdl.SDL_Rect = undefined;
            if (!sdl.SDL_GetDisplayBounds(display_id, &rect)) return error.SdlFailed;
            if (rect.x != 0 or rect.y != 0) {
                window_pos = .{
                    .x = @intCast(rect.x),
                    .y = @intCast(rect.y),
                };
            }
            window_size = .{
                .x = @intCast(rect.w),
                .y = @intCast(rect.h),
            };
        },
        .windowed_halfscreen => {
            var rect: sdl.SDL_Rect = undefined;
            if (!sdl.SDL_GetDisplayBounds(display_id, &rect)) return error.SdlFailed;
            if (rect.x != 0 or rect.y != 0) {
                window_pos = .{
                    .x = @intCast(rect.x),
                    .y = @intCast(rect.y),
                };
            }
            window_size = .{
                .x = @intCast(@divFloor(rect.w, 2)),
                .y = @intCast(@divFloor(rect.h, 2)),
            };
        },
        // TODO: Scale a window
        //
        // .windowed_scale => |ws| {
        //     var rect: sdl.SDL_Rect = undefined;
        //     if (!sdl.SDL_GetDisplayBounds(display_id, &rect)) return error.SdlFailed;
        //     if (rect.x != 0 or rect.y != 0) {
        //         window_pos = .{
        //             .x = @intCast(rect.x),
        //             .y = @intCast(rect.y),
        //         };
        //     }
        //     var new_window_size: Vector2us = .{
        //         .x = @intCast(@divFloor(rect.w, ws.reduced_by_multiplier)),
        //         .y = @intCast(@divFloor(rect.h, ws.reduced_by_multiplier)),
        //     };
        //     _ = &new_window_size;
        //     const undo_original_aspect_ratio: f32 = @as(f32, @floatFromInt(rect.h)) / @as(f32, @floatFromInt(rect.w));
        //     const new_aspect_ratio: f32 = (4 / 3);
        //     new_window_size.x = @intCast(new_window_size.x * undo_original_aspect_ratio * new_aspect_ratio);
        //     new_window_size.y = @intCast(new_window_size.y * undo_original_aspect_ratio * new_aspect_ratio);
        //     // new_window_size.x = @intCast(@as(f32, @floatFromInt(new_window_size.y)) * @as(f32, 4 / 3));
        //     // new_window_size.y = @intCast(@as(f32, @floatFromInt(new_window_size.x)) * @as(f32, 4 / 3));
        //     window_size = new_window_size;
        // },
        .pixels => |size| {
            window_size = .{
                .x = size.x,
                .y = size.y,
            };
        },
    }

    if (options.pos) |pos| {
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_X_NUMBER, pos.x)) return error.SdlFailed;
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_Y_NUMBER, pos.y)) return error.SdlFailed;
    } else if (window_pos) |pos| {
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_X_NUMBER, pos.x)) return error.SdlFailed;
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_Y_NUMBER, pos.y)) return error.SdlFailed;
    }
    if (window_size) |size| {
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, size.x)) return error.SdlFailed;
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, size.y)) return error.SdlFailed;
    }

    const window = sdl.SDL_CreateWindowWithProperties(props) orelse
        return error.SdlFailed;

    if (!builtin.abi.isAndroid()) {
        switch (builtin.os.tag) {
            .windows, .linux, .macos => {
                if (options.icon) |icon| {
                    if (!sdl.SDL_SetWindowIcon(window, icon))
                        return error.SdlFailed;
                }
            },
            // Definitely do nothing
            .freestanding, .emscripten, .other => {},
            // Assume other platforms aren't supported by default
            else => {},
        }
    }

    const r: SdlWindow = .{
        .internal = window,
        .properties = props,
    };
    return r;
}

pub fn deinit(window: *SdlWindow) void {
    sdl.SDL_DestroyWindow(window.internal);
    sdl.SDL_DestroyProperties(window.properties);
    window.* = undefined;
}

pub const Rect = struct {
    x: i24,
    y: i24,
    w: u31,
    h: u31,
};

/// This is a combination of the window pixel density and the display content scale, and is the expected scale for displaying content in this window.
/// For example, if a 3840x2160 window had a display scale of 2.0, the user expects the content to take twice as many pixels and be the same physical size as if it
/// were being displayed in a 1920x1080 window with a display scale of 1.0.
///
/// Conceptually this value corresponds to the scale display setting, and is updated when that setting is changed,
/// or the window moves to a display with a different scale setting.
pub fn getScale(window: *SdlWindow) error{SdlFailed}!f32 {
    const scale = sdl.SDL_GetWindowDisplayScale(window.internal);
    if (scale == 0.0) return error.SdlFailed;
    return scale;
}

pub fn getDisplayUsableBoundsFromIndex(display_index: u32) ?Rect {
    var display: sdl.SDL_Rect = undefined;
    if (!sdl.SDL_GetDisplayUsableBounds(getDisplayIdFromIndex(display_index), &display)) {
        return null;
    }
    return .{ .x = @intCast(display.x), .y = @intCast(display.y), .w = @intCast(display.w), .h = @intCast(display.h) };
}

fn getDisplayIdFromIndex(display_index: u32) sdl.SDL_DisplayID {
    var display_count: c_int = undefined;
    const display_list_or_err = sdl.SDL_GetDisplays(&display_count);
    if (display_list_or_err == null) {
        return 0;
    }
    defer sdl.SDL_free(display_list_or_err);
    if (display_count == 0) {
        return 0;
    }
    const display_list = display_list_or_err[0..@intCast(display_count)];
    if (display_index < display_list.len) {
        // Use found display
        return display_list[display_index];
    }
    // If cannot find display by index, use first item
    return display_list[0];
}

const SdlWindow = @This();
