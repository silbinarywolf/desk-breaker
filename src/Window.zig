const std = @import("std");
const builtin = @import("builtin");

const de = @import("de");
const sdl = de.sdl;

const log = std.log.scoped(.Window);
const assert = std.debug.assert;

pub const Options = de.Window.Options;

window: de.Window,
renderer: de.Renderer,
imgui: de.ImGuiContext,

pub fn init(
    self: *Window,
    options: Options,
) !void {
    self.* = .{
        .window = try de.Window.init(options),
        .renderer = undefined,
        .imgui = undefined,
    };
    self.renderer = try de.Renderer.init(&self.window);
    self.imgui = try de.ImGuiContext.init(&self.window, &self.renderer);
}

pub fn deinit(self: *Window) void {
    self.imgui.deinit();
    self.renderer.deinit();
    self.window.deinit();
    self.* = undefined;
}

pub const DisplayIndex = enum(u24) {
    primary = 0,
    _,

    pub fn toSdl(di: DisplayIndex) sdl.SDL_DisplayID {
        if (di == .primary) return sdl.SDL_GetPrimaryDisplay();
        const display_index: u31 = @intFromEnum(di);
        var display_count: c_int = undefined;
        const display_list_or_err = sdl.SDL_GetDisplays(&display_count);
        if (display_list_or_err == null) return sdl.SDL_GetPrimaryDisplay();

        defer sdl.SDL_free(display_list_or_err);
        if (display_count == 0) return sdl.SDL_GetPrimaryDisplay();

        const display_list = display_list_or_err[0..@intCast(display_count)];
        if (display_index < display_list.len) {
            // Use found display
            return display_list[display_index];
        }
        // If cannot find display by index, then use primary display
        return sdl.SDL_GetPrimaryDisplay();
    }
};

const Window = @This();
