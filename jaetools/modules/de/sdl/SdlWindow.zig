const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("../build_options.zig");
const Allocator = @import("std").mem.Allocator;
const vector = @import("../vector.zig");
const Vector2i = vector.Vector2i;
const Vector2us = vector.Vector2us;
const de_options = @import("../RootOptions.zig").current;

const sdl = @import("sdl");

const log = std.log.scoped(.Window);
const assert = std.debug.assert;

/// unstable identifier that can change when a monitor is connected or disconnected
pub const DisplayId = enum(u32) {
    _,

    pub inline fn fromSdl(sdl_display_id: sdl.SDL_DisplayID) DisplayId {
        return @enumFromInt(sdl_display_id);
    }

    fn toSdl(display_id: DisplayId) sdl.SDL_DisplayID {
        return @intFromEnum(display_id);
    }
};

pub const Position = switch (de_options.window_constraint) {
    // Cannot update window position for single window applications
    .single_window => union(enum) {
        default: void,
    },
    // Allow choosing position of window for multiple window applications
    .multiple_window => union(enum) {
        default: void,
        bottom_right: void,
        // NOTE(jae): 2026-07-01
        // Consider supporting window of specific size
        // pixels: Vector2i,
    },
};

pub const Options = struct {
    title: [:0]const u8 = &[0:0]u8{},
    pos: Position = .default,
    size: Size,
    resizeable: bool = false,
    /// SDL3: SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN defaults to true
    focusable: ?bool = null,
    borderless: bool = false,
    always_on_top: bool = false,
    /// Starts window with grabbed mouse focus
    mouse_grabbed: bool = false,
    icon: ?*sdl.SDL_Surface = null,
    /// If not set, default to primary monitor
    display: ?DisplayId = null,
    // NOTE(jae): 2025-12-27
    // Attempt to have the *audacity* on my own computer to get a
    // a window to pop up in the right-bottom corner of the screen with Linux/Wayland (and fail)
    // (Tried to use Wayland Popup Windows to do this)
    // parent: ?*Window = null,
};

pub const Size = union(enum) {
    /// For Applications: Take up as much screen as possible while accounting for taskbars (Windows/Linux),
    /// top menu bars / bottom application bar (Mac)
    maximized: void,
    /// For Games: Take up the entire screen (including taskbars, etc)
    windowed_fullscreen: void,
    /// Take up N divided of the screen
    /// ie. screen_width / 4, screen_height / 4
    windowed_divided_by: f32,
    pixels: Vector2us,

    /// For Games or Applications: Take up half of the screen
    pub const windowed_halfscreen: Size = .{ .windowed_divided_by = 2 };
};

internal: *sdl.SDL_Window,
size: Size,
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

    const display_id = if (options.display) |display_id| display_id.toSdl() else sdl.SDL_GetPrimaryDisplay();
    if (display_id == 0) return error.SdlFailed;
    const main_scale = sdl.SDL_GetDisplayContentScale(display_id);
    if (main_scale == 0.0) return error.SdlFailed;
    // const pixel_density = sdl.SDL_GetWindowPixelDensity(window_id); // ie. MacOS Retina screens
    // if (pixel_density == 0.0) return error.SdlFailed;

    const window_size = try computeSizeFromDisplay(display_id, options.size);
    if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, window_size.x)) return error.SdlFailed;
    if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, window_size.y)) return error.SdlFailed;

    switch (de_options.window_constraint) {
        .single_window => {},
        .multiple_window => {
            const display_pos_and_size = try computeDisplayBoundsFromSize(display_id, options.size);
            const maybe_position: ?Vector2i = posblk: {
                switch (options.pos) {
                    .default => {
                        if (display_pos_and_size.x != 0 or display_pos_and_size.y != 0) {
                            break :posblk .{
                                .x = @intCast(display_pos_and_size.x),
                                .y = @intCast(display_pos_and_size.y),
                            };
                        }
                        break :posblk null;
                    },
                    .bottom_right => {
                        break :posblk Vector2i{
                            .x = display_pos_and_size.x + display_pos_and_size.w - window_size.x,
                            .y = display_pos_and_size.y + display_pos_and_size.h - window_size.y,
                        };
                    },
                }
            };
            if (maybe_position) |window_position| {
                if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_X_NUMBER, window_position.x)) return error.SdlFailed;
                if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_Y_NUMBER, window_position.y)) return error.SdlFailed;
            }
        },
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
        .size = options.size,
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
    x: i32,
    y: i32,
    w: u31,
    h: u31,

    fn fromSdl(rect: sdl.SDL_Rect) Rect {
        return .{
            .x = @intCast(rect.x),
            .y = @intCast(rect.y),
            .w = @intCast(rect.w),
            .h = @intCast(rect.h),
        };
    }
};

fn computeDisplayBoundsFromSize(display_id: sdl.SDL_DisplayID, window_size_option: Size) error{SdlFailed}!Rect {
    return switch (window_size_option) {
        // Measure entire screen if we're fullscreen or scaling down by N
        .windowed_fullscreen,
        .windowed_divided_by,
        .pixels,
        => try sdlGetDisplayBounds(display_id),
        // Take into account taskbars, etc
        .maximized => try sdlGetDisplayUsableBounds(display_id),
    };
}

fn computeSizeFromDisplay(display_id: sdl.SDL_DisplayID, window_size_option: Size) error{SdlFailed}!Vector2i {
    // Mimick behaviour of SDL_GetWindowDisplayScale() before window creation
    const display_scale = blk: {
        const content_scale = sdl.SDL_GetDisplayContentScale(display_id);
        if (content_scale == 0.0) return error.SdlFailed;
        const display_mode = @as(?*const sdl.SDL_DisplayMode, sdl.SDL_GetCurrentDisplayMode(display_id)) orelse
            return error.SdlFailed;
        break :blk content_scale * display_mode.pixel_density;
    };

    switch (window_size_option) {
        .maximized, .windowed_fullscreen => {
            const display_pos_and_size = try computeDisplayBoundsFromSize(display_id, window_size_option);
            return .{
                .x = display_pos_and_size.w,
                .y = display_pos_and_size.h,
            };
        },
        .pixels => |size| {
            return .{
                .x = @intFromFloat(@floor(@as(f32, @floatFromInt(size.x)) * display_scale)),
                .y = @intFromFloat(@floor(@as(f32, @floatFromInt(size.y)) * display_scale)),
            };
        },
        .windowed_divided_by => |divide_by_scale| {
            const display_pos_and_size = try computeDisplayBoundsFromSize(display_id, window_size_option);
            return .{
                .x = @intFromFloat(@floor(@as(f32, @floatFromInt(display_pos_and_size.w)) * display_scale / divide_by_scale)),
                .y = @intFromFloat(@floor(@as(f32, @floatFromInt(display_pos_and_size.h)) * display_scale / divide_by_scale)),
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
    }
}

/// This is a combination of the window pixel density and the display content scale, and is the expected scale for displaying content in this window.
/// For example, if a 3840x2160 window had a display scale of 2.0, the user expects the content to take twice as many pixels and be the same physical size as if it
/// were being displayed in a 1920x1080 window with a display scale of 1.0.
///
/// Conceptually this value corresponds to the scale display setting, and is updated when that setting is changed,
/// or the window moves to a display with a different scale setting.
pub fn getDisplayScale(window: *SdlWindow) error{SdlFailed}!f32 {
    // display_scale = pixel_density * content_scale;
    const scale = sdl.SDL_GetWindowDisplayScale(window.internal);
    if (scale == 0.0) return error.SdlFailed;
    return scale;
}

fn sdlGetDisplayBounds(display_id: sdl.SDL_DisplayID) error{SdlFailed}!Rect {
    var display_pos_and_size: sdl.SDL_Rect = undefined;
    if (!sdl.SDL_GetDisplayBounds(display_id, &display_pos_and_size)) return error.SdlFailed;
    return Rect.fromSdl(display_pos_and_size);
}

/// This is the same area as SDL_GetDisplayBounds() reports, but with portions reserved by the system removed.
/// For example, on Apple's macOS, this subtracts the area occupied by the menu bar and dock.
///
/// Setting a window to be fullscreen generally bypasses these unusable areas, so these are good guidelines for the maximum space
/// available to a non-fullscreen window.
fn sdlGetDisplayUsableBounds(display_id: sdl.SDL_DisplayID) error{SdlFailed}!Rect {
    var display_pos_and_size: sdl.SDL_Rect = undefined;
    if (!sdl.SDL_GetDisplayUsableBounds(display_id, &display_pos_and_size)) return error.SdlFailed;
    return Rect.fromSdl(display_pos_and_size);
}

const SdlWindow = @This();
