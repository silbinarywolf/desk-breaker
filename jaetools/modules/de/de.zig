const builtin = @import("builtin");
const process = @import("std").process;
const Allocator = @import("std").mem.Allocator;
const ArenaAllocator = @import("std").heap.ArenaAllocator;
const Io = @import("std").Io;
const SdlPlatform = @import("SdlPlatform.zig");
const build_options = @import("build_options.zig");
const dumpErrorReturnTrace = @import("std").debug.dumpErrorReturnTrace;

// Platform
pub const sdl = if (build_options.has_sdl) @import("sdl") else @compileError("cannot access de.sdl if use_sdl = false");
pub const Platform = SdlPlatform;
pub const Window = @import("SdlWindow.zig");
pub const Renderer = @import("SdlRenderer.zig");
pub const ImGuiContext = @import("ImGuiContext.zig");
pub const Image = @import("Image.zig");

// 3rd party libraries
pub const imgui = if (build_options.has_imgui) @import("imgui") else @compileError("cannot access de.imgui if use_imgui = false");

// Reusable libraries
const vector = @import("vector.zig");
pub const Vector2 = vector.Vector2;
pub const Vector2f = vector.Vector2f;
pub const Vector2i = vector.Vector2i;
pub const StaticRingBuffer = @import("StaticRingBuffer.zig").StaticRingBuffer;
pub const FrameTimer = @import("FrameTimer.zig");

const log = @import("std").log.scoped(.de);

pub const Options = @import("RootOptions.zig"); // MUST export for end-user app
const App = Options.current.application_type;

pub const main = switch (Options.current.platform_type) {
    .sdl_callback => sdl_callback_entry.main,
    .sdl_zig => sdl_zig_entry.main,
};

/// Initial main() startup information
var default_init: Startup = undefined;

var has_triggered_app_quit = false;

const AppMemory = struct {
    /// The user-code application struct, can be anything
    app: App,
    /// Platform-specific storage
    platform: Platform,
};

/// My own customized version of Zig std.process.Init
pub const Startup = struct {
    /// Environment variables.
    environ: process.Environ,
    /// Command line arguments.
    args: process.Args,
    /// A default-selected general purpose allocator for temporary heap
    /// allocations. Debug mode will set up leak checking if possible.
    /// Threadsafe.
    gpa: Allocator,
    /// An appropriate default Io implementation based on the target
    /// configuration. Debug mode will set up leak checking if possible.
    io: Io,
    /// Direct-access to the platform
    platform: *Platform,
};

/// Exit successfully at the end of the next loop
pub fn quit() error{Quit}!void {
    has_triggered_app_quit = true;
}

inline fn initPlatformAndAppAndCallOnStart() !*AppMemory {
    const gpa = default_init.gpa;

    const app_memory: *AppMemory = try gpa.create(AppMemory);
    errdefer gpa.destroy(app_memory);
    default_init.platform = &app_memory.platform;

    try App.init(default_init, &app_memory.app);
    return app_memory;
}

inline fn handleAppSdlEvent(app_memory: *AppMemory, event: *sdl.SDL_Event) !void {
    try App.onEvent(event, &app_memory.app);
}

inline fn handleAppLoop(app_memory: *AppMemory) !void {
    const platform = &app_memory.platform;
    AppLoop: while (true) {
        var event_it = platform.events();
        if (build_options.has_sdl) {
            while (event_it.next()) |ev| {
                try handleAppSdlEvent(app_memory, ev);
                if (has_triggered_app_quit) break :AppLoop;
            }
        } else {
            @compileError("Missing platform logic for configured app");
        }
        try handleAppIterate(app_memory);
        if (has_triggered_app_quit) break :AppLoop;
    }
}

inline fn handleAppIterate(app_memory: *AppMemory) !void {
    const app = &app_memory.app;
    try App.onIterate(app);

    // NOTE(jae): 2026-06-08
    // Moved handling to App-code
    // const frame_timer = &app_memory.frame_timer;
    // try frame_timer.beforeUpdate();
    // try frame_timer.callFixedAndVariableUpdate(app);
    // try App.onDraw(app);
    // frame_timer.delay();
}

inline fn handleAppQuit(app_memory: *AppMemory) !void {
    const app = &app_memory.app;
    try App.onQuit(app);
    app.deinit();
    app_memory.platform.deinit();
    default_init.gpa.destroy(app_memory);
}

const sdl_callback_entry = struct {
    const sdlGetError = SdlPlatform.sdlGetError;

    fn main(init: process.Init) !u8 {
        // NOTE(jae): 2026-05-05
        // If need custom setup for another platform, look at callMain() in lib/std/start.zig
        default_init = .{
            .environ = init.minimal.environ,
            .args = init.minimal.args,
            .gpa = init.gpa,
            .io = init.io,
            .platform = undefined,
        };
        const result_code = sdl.SDL_RunApp(0, null, sdlMainCallback, null);
        if (result_code != 0) {
            // From docs:
            // - Returns the return value from mainFunction: 0 on success, otherwise failure
            // - SDL_GetError() *might* have more information on the failure.
            if (sdlGetError()) |sdl_error_message| {
                log.err("SDL_RunApp error(code={}): {s}", .{ result_code, sdl_error_message });
            }
            if (result_code != 1) {
                // NOTE(jae): 2026-05-08:
                // If result code isn't the expected '1' as I've observed on Linux, print it.
                log.err("SDL_RunApp error(code={})", .{result_code});
                return @intCast(result_code);
            }
            return 1;
        }
        return @intCast(result_code);
    }

    fn sdlMainCallback(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
        return @intCast(sdl.SDL_EnterAppMainCallbacks(
            argc,
            argv,
            sdlInitCallback,
            sdlIterateCallback,
            sdlEventCallback,
            sdlQuitCallback,
        ));
    }

    fn sdlInitCallback(appstate: [*c]?*anyopaque, argc: c_int, argv: [*c][*c]u8) callconv(.c) sdl.SDL_AppResult {
        if (comptime App == void) {
            @compileError("Must configure 'de_options.application_type'");
        }
        _ = argc;
        _ = argv;

        const app_memory = initPlatformAndAppAndCallOnStart() catch |err|
            return sdlCatchUnhandledError(err);
        appstate.* = app_memory;
        return sdl.SDL_APP_CONTINUE;
    }

    fn sdlIterateCallback(appstate: ?*anyopaque) callconv(.c) sdl.SDL_AppResult {
        const app_memory: *AppMemory = @ptrCast(@alignCast(appstate));
        handleAppIterate(app_memory) catch |err|
            return sdlCatchUnhandledError(err);
        if (has_triggered_app_quit)
            return sdl.SDL_APP_SUCCESS;
        return sdl.SDL_APP_CONTINUE;
    }

    fn sdlEventCallback(appstate: ?*anyopaque, ev: [*c]sdl.SDL_Event) callconv(.c) sdl.SDL_AppResult {
        const event: *sdl.SDL_Event = ev.?;
        const app_memory: *AppMemory = @ptrCast(@alignCast(appstate));
        handleAppSdlEvent(app_memory, event) catch |err|
            return sdlCatchUnhandledError(err);
        if (has_triggered_app_quit)
            return sdl.SDL_APP_SUCCESS;
        return sdl.SDL_APP_CONTINUE;
    }

    fn sdlQuitCallback(appstate: ?*anyopaque, _: sdl.SDL_AppResult) callconv(.c) void {
        const app_memory: *AppMemory = @as(?*AppMemory, @ptrCast(@alignCast(appstate))) orelse
            // If error occurs in "sdlIterateCallback" then there won't be a quit pointer
            return;
        handleAppQuit(app_memory) catch |err| return sdlCatchUnhandledError(err);
    }

    inline fn sdlCatchUnhandledError(err: anyerror) sdl.SDL_AppResult {
        SdlPlatform.logUnhandledError(err);
        switch (builtin.os.tag) {
            .freestanding, .other => {},
            else => if (@errorReturnTrace()) |trace| dumpErrorReturnTrace(trace),
        }
        return sdl.SDL_APP_FAILURE;
    }
};

const sdl_zig_entry = struct {
    fn main(init: process.Init) !void {
        // NOTE(jae): 2026-05-05
        // If need custom setup for another platform, look at callMain() in lib/std/start.zig
        default_init = .{
            .environ = init.minimal.environ,
            .args = init.minimal.args,
            .gpa = init.gpa,
            .io = init.io,
            .platform = undefined,
        };
        const app_memory = initPlatformAndAppAndCallOnStart() catch |err| {
            Platform.logUnhandledError(err);
            return err;
        };
        handleAppLoop(app_memory) catch |err| {
            Platform.logUnhandledError(err);
            return err;
        };
        handleAppQuit(app_memory) catch |err| {
            Platform.logUnhandledError(err);
            return err;
        };
    }
};
