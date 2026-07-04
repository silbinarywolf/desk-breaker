const builtin = @import("builtin");
const build_options = @import("../build_options.zig");
const Window = @import("SdlWindow.zig");
const Allocator = @import("std").mem.Allocator;
const SdlPlatform = @import("../platform.zig").Platform;

const sdl = @import("sdl");
const root_options = @import("../RootOptions.zig").current;

internal: *sdl.SDL_Renderer,

pub const InitRendererError = SdlPlatform.Error || Allocator.Error;

pub fn init(window: *Window) InitRendererError!SdlRenderer {
    const default_renderer: ?[*:0]const u8 = switch (root_options.renderer_type) {
        .default => null,
        .software => switch (builtin.os.tag) {
            // NOTE(Jae): 2025-01-23
            // SDL 3.2.0: Force hardware rendering. MacOs software rendering has an issue where
            // it seems to just... not clear the window. Cannot repro on Windows or Linux.
            .macos => null,
            // NOTE(jae): 2026-17-01
            // On other OSes, just use hardware rendering
            .freestanding => null,
            else => sdl.SDL_SOFTWARE_RENDERER,
        },
    };
    const renderer: *sdl.SDL_Renderer = sdl.SDL_CreateRenderer(window.internal, default_renderer) orelse
        return error.SdlFailed;
    errdefer sdl.SDL_DestroyRenderer(renderer);

    return .{
        .internal = renderer,
    };
}

pub fn deinit(r: *SdlRenderer) void {
    sdl.SDL_DestroyRenderer(r.internal);
}

const Vsync = union(enum) {
    disabled: void, // SDL_RENDERER_VSYNC_DISABLED
    /// 1 to synchronize present with every vertical refresh
    /// 2 to synchronize present with every second vertical refresh
    interval: u16,
    /// For late swap tearing (adaptive vsync)
    adaptive: void, // SDL_RENDERER_VSYNC_ADAPTIVE
};

pub fn setVsync(renderer: *SdlRenderer, vsync: Vsync) error{SdlFailed}!void {
    const value: c_int = switch (vsync) {
        .disabled => sdl.SDL_RENDERER_VSYNC_DISABLED,
        .adaptive => sdl.SDL_RENDERER_VSYNC_ADAPTIVE,
        .interval => |v| v,
    };
    if (!sdl.SDL_SetRenderVSync(renderer.internal, value)) return error.SdlFailed;
}

pub fn clearScreen(r: *SdlRenderer) error{SdlFailed}!void {
    const renderer = r.internal;
    if (!sdl.SDL_SetRenderDrawColor(renderer, 20, 20, 20, 0)) return error.SdlFailed;
    if (!sdl.SDL_RenderClear(renderer)) return error.SdlFailed;
}

pub fn render(r: *SdlRenderer) error{SdlFailed}!void {
    const renderer = r.internal;

    if (!sdl.SDL_RenderPresent(renderer)) return error.SdlFailed;
}

const SdlRenderer = @This();
