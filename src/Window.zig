const std = @import("std");
const builtin = @import("builtin");

const sdl = @import("sdl");
const imgui = @import("imgui");

const log = std.log.scoped(.Window);
const assert = std.debug.assert;

pub const Options = struct {
    title: [:0]const u8 = &[0:0]u8{},
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    resizeable: bool = false,
    focusable: bool = true,
    borderless: bool = false,
    always_on_top: bool = false,
    /// Starts window with grabbed mouse focus
    mouse_grabbed: bool = false,
    icon: ?*sdl.SDL_Surface = null,
};

window: *sdl.SDL_Window,
window_properties: u32,
renderer: *sdl.SDL_Renderer,
imgui_context: *imgui.ImGuiContext,
imgui_font_atlas: *imgui.ImFontAtlas,
imgui_new_frame: bool,

pub fn init(options: Options) !@This() {
    const props = sdl.SDL_CreateProperties();
    if (props == 0) {
        log.err("SDL_CreateProperties failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlFailed;
    }
    errdefer sdl.SDL_DestroyProperties(props);

    if (options.title.len > 0) {
        if (!sdl.SDL_SetStringProperty(props, sdl.SDL_PROP_WINDOW_CREATE_TITLE_STRING, options.title)) return error.SdlSetPropertyFailed;
    }
    if (options.resizeable) {
        if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN, true)) return error.SdlSetPropertyFailed;
    }
    if (!options.focusable) {
        // SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, defaults to true
        if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, false)) return error.SdlSetPropertyFailed;
    }
    if (options.borderless) {
        // SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, defaults to true
        if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_BORDERLESS_BOOLEAN, true)) return error.SdlSetPropertyFailed;
    }
    if (options.always_on_top) {
        if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_ALWAYS_ON_TOP_BOOLEAN, true)) return error.SdlSetPropertyFailed;
    }
    if (options.mouse_grabbed) {
        if (!sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_MOUSE_GRABBED_BOOLEAN, true)) return error.SdlSetPropertyFailed;
    }
    if (options.x) |x| {
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_X_NUMBER, x)) return error.SdlSetPropertyFailed;
    }
    if (options.y) |y| {
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_Y_NUMBER, y)) return error.SdlSetPropertyFailed;
    }
    if (options.width) |width| {
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, width)) return error.SdlSetPropertyFailed;
    }
    if (options.height) |height| {
        if (!sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, height)) return error.SdlSetPropertyFailed;
    }

    const window = sdl.SDL_CreateWindowWithProperties(props) orelse {
        log.err("SDL_CreateWindowWithProperties failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlFailed;
    };

    if (comptime builtin.os.tag != .emscripten and !builtin.abi.isAndroid()) {
        if (options.icon) |icon| {
            if (!sdl.SDL_SetWindowIcon(window, icon)) {
                log.err("unable to set window icon: {s}", .{sdl.SDL_GetError()});
                return error.SDLFailed;
            }
        }
    }

    // TODO(jae): 2024-08-20
    // Add option to use hardware accelerated instead.
    // Defaulting to software rendering so this can run without taxing games / GPU usage
    const default_renderer = switch (builtin.os.tag) {
        // NOTE(Jae): 2025-01-23
        // SDL 3.2.0: Force hardware rendering. MacOs software rendering has an issue where
        // it seems to just... not clear the window. Cannot repro on Windows or Linux.
        .macos => null,
        else => sdl.SDL_SOFTWARE_RENDERER,
    };
    const renderer: *sdl.SDL_Renderer = sdl.SDL_CreateRenderer(window, default_renderer) orelse {
        log.err("unable to create renderer: {s}", .{sdl.SDL_GetError()});
        return error.SDLFailed;
    };
    errdefer sdl.SDL_DestroyRenderer(renderer);

    // Reset to previous context after setup
    const previous_imgui_context = imgui.igGetCurrentContext();
    defer {
        if (previous_imgui_context) |prev_imgui_context| {
            imgui.igSetCurrentContext(prev_imgui_context);
        }
    }

    // NOTE(jae): 2024-11-07
    // Using embedded font data that isn't owned by the atlas
    var font_config = &imgui.ImFontConfig_ImFontConfig()[0];
    defer imgui.ImFontConfig_destroy(font_config);
    font_config.FontDataOwnedByAtlas = false;

    // NOTE(jae): 2024-06-11
    // Each context needs its own font atlas or issues occur with rendering
    const font_data = @embedFile("resources/fonts/Lato-Regular.ttf");
    const imgui_font_atlas: *imgui.ImFontAtlas = imgui.ImFontAtlas_ImFontAtlas();
    errdefer imgui.ImFontAtlas_destroy(imgui_font_atlas);
    _ = imgui.ImFontAtlas_AddFontFromMemoryTTF(
        imgui_font_atlas,
        @constCast(@ptrCast(font_data[0..].ptr)),
        font_data.len,
        28,
        font_config,
        null,
    );

    const imgui_context = imgui.igCreateContext(imgui_font_atlas) orelse {
        log.err("unable to create imgui context: {s}", .{sdl.SDL_GetError()});
        return error.ImguiFailed;
    };
    errdefer imgui.igDestroyContext(imgui_context);

    // NOTE(jae): This call is needed for multiple windows, ie. creation of the second window
    imgui.igSetCurrentContext(imgui_context);

    const imgui_io = &imgui.igGetIO()[0];
    imgui_io.IniFilename = null; // disable imgui.ini
    imgui_io.IniSavingRate = -1; // disable imgui.ini

    _ = imgui.ImGui_ImplSDL3_InitForSDLRenderer(@ptrCast(window), @ptrCast(renderer));
    errdefer imgui.ImGui_ImplSDL3_Shutdown();

    _ = imgui.ImGui_ImplSDLRenderer3_Init(@ptrCast(renderer));
    errdefer imgui.ImGui_ImplSDLRenderer3_Shutdown();

    // setup new frame (so things won't crash if we create a window after eventing)
    imgui.ImGui_ImplSDLRenderer3_NewFrame();
    imgui.ImGui_ImplSDL3_NewFrame();
    imgui.igNewFrame();

    // TODO(jae): 2024-11-07
    // Figure out how to force mouse onto break window
    // if (force_focus) {
    //     const oldActivateWhenRaised = sdl.SDL_GetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED);
    //     const oldActivateWhenShown = sdl.SDL_GetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN);
    //     const oldForceRaiseWindow = sdl.SDL_GetHint(sdl.SDL_HINT_FORCE_RAISEWINDOW);
    //     _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED, "1");
    //     _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "1");
    //     _ = sdl.SDL_SetHint(sdl.SDL_HINT_FORCE_RAISEWINDOW, "1");
    //
    //     _ = sdl.SDL_HideWindow(window);
    //     _ = sdl.SDL_ShowWindow(window);
    //
    //     defer {
    //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED, oldActivateWhenRaised);
    //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, oldActivateWhenShown);
    //         _ = sdl.SDL_SetHint(sdl.SDL_HINT_FORCE_RAISEWINDOW, oldForceRaiseWindow);
    //     }
    // }

    return .{
        .window = window,
        .window_properties = props,
        .renderer = renderer,
        .imgui_context = imgui_context,
        .imgui_font_atlas = imgui_font_atlas,
        // True if we called "igNewFrame"
        .imgui_new_frame = true,
    };
}

pub fn deinit(self: *Window) void {
    {
        const previous_imgui_context = imgui.igGetCurrentContext();
        defer {
            if (previous_imgui_context) |prev_imgui_context| {
                imgui.igSetCurrentContext(prev_imgui_context);
            }
        }
        imgui.igSetCurrentContext(self.imgui_context);
        if (self.imgui_new_frame) {
            // ImGui asserts in Debug mode if you try to deinitialize mid-frame
            // due to the ImGuiFontAtlas being locked
            imgui.igEndFrame();
        }
        imgui.ImGui_ImplSDLRenderer3_Shutdown();
        imgui.ImGui_ImplSDL3_Shutdown();
    }
    imgui.igDestroyContext(self.imgui_context);
    imgui.ImFontAtlas_destroy(self.imgui_font_atlas);
    sdl.SDL_DestroyRenderer(self.renderer);
    sdl.SDL_DestroyWindow(self.window);
    sdl.SDL_DestroyProperties(self.window_properties);
    self.* = undefined;
}

pub fn imguiNewFrame(window: *Window) void {
    if (window.imgui_new_frame) {
        // if we didn't call end frame last frame, do it now
        imgui.igEndFrame();
    }

    imgui.igSetCurrentContext(window.imgui_context);
    imgui.ImGui_ImplSDLRenderer3_NewFrame();
    imgui.ImGui_ImplSDL3_NewFrame();
    imgui.igNewFrame();
    window.imgui_new_frame = true;
}

pub fn imguiRender(window: *Window) void {
    assert(window.imgui_new_frame);
    imgui.igSetCurrentContext(window.imgui_context);
    imgui.igRender();
    imgui.ImGui_ImplSDLRenderer3_RenderDrawData(@ptrCast(imgui.igGetDrawData()), @ptrCast(window.renderer));
    window.imgui_new_frame = false;
}

pub fn getDisplayUsableBoundsFromIndex(display_index: u32) ?sdl.SDL_Rect {
    var display: sdl.SDL_Rect = undefined;
    if (!sdl.SDL_GetDisplayUsableBounds(getDisplayIdFromIndex(display_index), &display)) {
        return null;
    }
    return display;
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

const Window = @This();
