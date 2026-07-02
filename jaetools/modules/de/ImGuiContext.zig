const build_options = @import("build_options.zig");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const imgui = if (build_options.has_imgui) @import("imgui") else void;
const sdl = if (build_options.has_sdl) @import("sdl") else void;
const assert = @import("std").debug.assert;
const Window = platform.Window;
const de_options = @import("RootOptions.zig").current;
const Renderer = platform.Renderer;

const log = @import("std").log.scoped(.imgui);

context: *imgui.ImGuiContext,
renderer: *Renderer,
new_frames_count: u16,

pub const Error = error{
    ImguiCreateContextFailed,
    ImguiWindowGetScaleFailed,
    ImguiSdlInitRendererFailed,
    ImguiSdlRendererFailed,
    ImguiCreateFontConfigFailed,
    ImguiGetIOFromContextPointerFailed,
};

pub const Options = struct {
    main_scale: f32,
};

pub fn init(window: *Window, renderer: *Renderer) Error!ImGuiContext {
    // Reset to previous context after setup
    const previous_imgui_context = imgui.igGetCurrentContext();
    defer if (previous_imgui_context) |prev_imgui_context| {
        imgui.igSetCurrentContext(prev_imgui_context);
    };

    const imgui_context = imgui.igCreateContext(null) orelse
        return error.ImguiCreateContextFailed;
    errdefer imgui.igDestroyContext(imgui_context);

    // NOTE(jae): This call is needed for multiple windows, ie. creation of the second window
    if (previous_imgui_context != null) {
        imgui.igSetCurrentContext(imgui_context);
    }

    const main_scale = window.getDisplayScale() catch |err| switch (err) {
        error.SdlFailed => return error.ImguiWindowGetScaleFailed,
    };
    const style = &imgui.igGetStyle()[0];
    imgui.ImGuiStyle_ScaleAllSizes(style, main_scale); // Bake a fixed style scale. (until we have a solution for dynamic style scaling, changing this requires resetting Style + calling this again)
    style.FontScaleDpi = main_scale; // Set initial font scale. (using io.ConfigDpiScaleFonts=true makes this unnecessary. We leave both here for documentation purpose)

    const imgui_io = @as(?*imgui.ImGuiIO, imgui.igGetIO_ContextPtr(imgui_context)) orelse
        return error.ImguiGetIOFromContextPointerFailed;
    imgui_io.IniFilename = null; // disable imgui.ini
    imgui_io.IniSavingRate = -1; // disable imgui.ini
    imgui_io.ConfigFlags |= imgui.ImGuiConfigFlags_NavEnableKeyboard; // Enable Keyboard Controls
    imgui_io.ConfigFlags |= imgui.ImGuiConfigFlags_NavEnableGamepad; // Enable Gamepad Controls
    // imgui_io.ConfigFlags |= imgui.ImGuiConfigFlags_DockingEnable; // Enable Docking
    imgui_io.Fonts[0].FontLoader = imgui.ImGuiFreeType_GetFontLoader();

    // NOTE(jae): 2024-11-07
    // Using embedded font data that isn't owned by the atlas
    const use_font = "assets/Lato-Regular.ttf"; // "resources/fonts/Lato-Regular.ttf"
    if (use_font.len > 0) {
        const font_config = @as(?*imgui.ImFontConfig, imgui.ImFontConfig_ImFontConfig()) orelse
            return error.ImguiCreateFontConfigFailed;
        defer imgui.ImFontConfig_destroy(font_config);

        const font_data = @embedFile(use_font);
        font_config.FontData = @ptrCast(@constCast(font_data[0..].ptr));
        font_config.FontDataSize = font_data.len;
        font_config.FontDataOwnedByAtlas = false;
        font_config.SizePixels = de_options.imgui.default_font_size;

        const font = imgui.ImFontAtlas_AddFont(imgui_io.Fonts, font_config);
        imgui.igPushFont(font, 0.0);
    }

    // Alternate GPU backend, ie. https://github.com/ocornut/imgui/blob/master/examples/example_sdl3_sdlgpu3/main.cpp
    // - ImGui_ImplSDL3_InitForSDLGPU(window);
    // - ImGui_ImplSDLGPU3_Init(&init_info);

    if (!imgui.ImGui_ImplSDL3_InitForSDLRenderer(@ptrCast(window.internal), @ptrCast(renderer.internal)))
        return error.ImguiSdlInitRendererFailed;
    errdefer imgui.ImGui_ImplSDL3_Shutdown();

    if (!imgui.ImGui_ImplSDLRenderer3_Init(@ptrCast(renderer.internal)))
        return error.ImguiSdlRendererFailed;
    errdefer imgui.ImGui_ImplSDLRenderer3_Shutdown();

    var context: ImGuiContext = .{
        .context = imgui_context,
        .renderer = renderer,
        .new_frames_count = 0,
    };
    if (previous_imgui_context != null) {
        context.newFrame();
    }
    return context;
}

pub fn deinit(context: *ImGuiContext) void {
    const previous_imgui_context = imgui.igGetCurrentContext();
    defer if (previous_imgui_context) |prev_imgui_context| {
        imgui.igSetCurrentContext(prev_imgui_context);
    };
    imgui.igSetCurrentContext(context.context);
    if (context.new_frames_count > 0) {
        // ImGui asserts in Debug mode if you try to deinitialize mid-frame
        // due to the ImGuiFontAtlas being locked
        imgui.igEndFrame();
    }
    imgui.ImGui_ImplSDLRenderer3_Shutdown();
    imgui.ImGui_ImplSDL3_Shutdown();
    imgui.igDestroyContext(context.context);
    context.* = undefined;
}

pub fn newFrame(context: *ImGuiContext) void {
    // if (builtin.mode == .Debug and context.new_frames_count > 0) {
    //     @panic("Was ImGuiContext.render() called in the draw event?");
    // }
    // assert(context.new_frames_count == 0);

    // Swap context
    const previous_imgui_context = imgui.igGetCurrentContext();
    defer if (previous_imgui_context) |prev_imgui_context| {
        imgui.igSetCurrentContext(prev_imgui_context);
    };
    imgui.igSetCurrentContext(context.context);

    // setup new frame (so things won't crash if we create a window after eventing)
    imgui.ImGui_ImplSDLRenderer3_NewFrame();
    imgui.ImGui_ImplSDL3_NewFrame();
    imgui.igNewFrame();

    context.new_frames_count = 1;
}

/// From "ImGui_ImplSDL3_ProcessEvent" docs:
///
/// You can read the io.WantCaptureMouse, io.WantCaptureKeyboard flags to tell if dear imgui wants to use your inputs.
///
/// - When io.WantCaptureMouse is true, do not dispatch mouse input data to your main application, or clear/overwrite your copy of the mouse data.
/// - When io.WantCaptureKeyboard is true, do not dispatch keyboard input data to your main application, or clear/overwrite your copy of the keyboard data.
///
/// Generally you may always pass all inputs to dear imgui, and hide them from your application based on those two flags.
pub fn processSdlEvent(context: *ImGuiContext, sdl_event: *const sdl.SDL_Event) void {
    // Swap context
    const previous_context = imgui.igGetCurrentContext();
    defer if (previous_context) |imgui_context| {
        imgui.igSetCurrentContext(imgui_context);
    };
    imgui.igSetCurrentContext(context.context);

    // Handle event
    _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(sdl_event));
}

/// Get Io to read variables like "WantCaptureKeyboard"
pub inline fn io(context: *ImGuiContext) *const imgui.ImGuiIO {
    const r: *imgui.ImGuiIO = imgui.igGetIO_ContextPtr(context.context) orelse unreachable;
    return r;
}

/// Deprecated: Use io() instead
pub inline fn wantCaptureKeyboard(context: *ImGuiContext) bool {
    return context.io().WantCaptureKeyboard;
}

pub inline fn render(context: *ImGuiContext) !void {
    return try context.renderSdl(context.renderer.internal);
}

fn renderSdl(context: *ImGuiContext, renderer: *sdl.SDL_Renderer) error{SdlFailed}!void {
    assert(context.new_frames_count > 0);

    // Swap context
    const previous_imgui_context = imgui.igGetCurrentContext();
    defer if (previous_imgui_context) |prev_imgui_context| {
        imgui.igSetCurrentContext(prev_imgui_context);
    };
    imgui.igSetCurrentContext(context.context);

    // Do render
    imgui.igRender();
    const imgui_io = context.io();

    // SDL-specific code
    var old_scale_x: f32 = undefined;
    var old_scale_y: f32 = undefined;
    if (!sdl.SDL_GetRenderScale(renderer, &old_scale_x, &old_scale_y))
        return error.SdlFailed;
    defer _ = sdl.SDL_SetRenderScale(renderer, old_scale_x, old_scale_y);
    if (!sdl.SDL_SetRenderScale(renderer, imgui_io.DisplayFramebufferScale.x, imgui_io.DisplayFramebufferScale.y))
        return error.SdlFailed;
    imgui.ImGui_ImplSDLRenderer3_RenderDrawData(@ptrCast(imgui.igGetDrawData()), @ptrCast(renderer));
}

const ImGuiContext = @This();
