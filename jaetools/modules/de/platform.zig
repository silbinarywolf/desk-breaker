const build_options = @import("build_options.zig");

pub const Platform = if (build_options.has_sdl) @import("sdl/SdlPlatform.zig") else void;
pub const Window = if (build_options.has_sdl) @import("sdl/SdlWindow.zig") else void;
pub const Renderer = if (build_options.has_sdl) @import("sdl/SdlRenderer.zig") else void;
