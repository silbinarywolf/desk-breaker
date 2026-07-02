const builtin = @import("builtin");
const process = @import("std").process;
const Allocator = @import("std").mem.Allocator;
const ArenaAllocator = @import("std").heap.ArenaAllocator;
const CLibraryAllocator = @import("CLibraryAllocator.zig");
const Io = @import("std").Io;
const platform = @import("platform.zig");
const build_options = @import("build_options.zig");
const dumpErrorReturnTrace = @import("std").debug.dumpErrorReturnTrace;
const bufPrint = @import("std").fmt.bufPrint;

// Platform
pub const sdl = if (build_options.has_sdl) @import("sdl") else @compileError("cannot access de.sdl if use_sdl = false");
pub const Startup = @import("Startup.zig");
pub const Platform = platform.Platform;
pub const Window = platform.Window;
pub const Renderer = platform.Renderer;
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

const LogLevel = @import("std").log.Level;

pub const Options = @import("RootOptions.zig"); // MUST export for end-user app
const App = Options.current.application_type;

pub const main = if (build_options.has_sdl and sdl.ZIG_SDL_MAIN_USE_CALLBACKS == 1)
    void
else switch (Options.current.platform_type) {
    .sdl_callback => sdl_callback_entry.main,
    .sdl_zig => sdl_zig_entry.main,
};

/// Provide logFn for use `std_options: std.Options = .{ .logFn =  }`
pub const logFn: fn (comptime message_level: LogLevel, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void =
    if (builtin.abi.isAndroid() or builtin.os.tag == .emscripten or builtin.os.tag == .freestanding)
        SDL_logFn
    else
        @import("std").log.defaultLog;

/// Initial main() startup information
var default_init: Startup = undefined;

/// Setup initial application memory
var default_app_memory: AppMemory = undefined;

var has_triggered_app_quit = false;

const AppMemory = struct {
    /// The user-code application struct, can be anything
    app: App,
    /// Change the default C allocator for C-libraries
    global_c_allocator: CLibraryAllocator,
    /// Platform-specific storage
    platform: Platform,
};

/// Exit successfully at the end of the next loop
pub fn quit() error{Quit}!void {
    has_triggered_app_quit = true;
}

inline fn initPlatformAndAppAndCallOnStart() !*AppMemory {
    const gpa = default_init.gpa;
    const io = default_init.io;

    const app_memory: *AppMemory = &default_app_memory;
    app_memory.* = .{
        .app = undefined,
        .platform = .uninitialized,
        .global_c_allocator = undefined,
    };
    default_init.platform = &app_memory.platform;

    // Setup global c allocator
    try app_memory.global_c_allocator.init(gpa, io);

    try App.onInit(default_init, &app_memory.app);
    return app_memory;
}

inline fn handleAppSdlEvent(app_memory: *AppMemory, event: *sdl.SDL_Event) !void {
    try App.onEvent(event, &app_memory.app);
}

inline fn handleAppLoop(app_memory: *AppMemory) !void {
    AppLoop: while (true) {
        var event_it = app_memory.platform.events();
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
    _ = app;
    // try App.onQuit(app);
    // app.deinit();
    // app_memory.platform.deinitNoError();
    // app_memory.global_c_allocator.deinit();
    // default_init.gpa.destroy(app_memory);
    // default_init.deinit();
}

comptime {
    if (sdl.ZIG_SDL_MAIN_USE_CALLBACKS == 1) {
        @export(&sdl_callback_entry.sdlInitCallback, .{ .name = "SDL_AppInit", .linkage = .strong });
        @export(&sdl_callback_entry.sdlIterateCallback, .{ .name = "SDL_AppIterate", .linkage = .strong });
        @export(&sdl_callback_entry.sdlEventCallback, .{ .name = "SDL_AppEvent", .linkage = .strong });
        @export(&sdl_callback_entry.sdlQuitCallback, .{ .name = "SDL_AppQuit", .linkage = .strong });
    }
}

const sdl_callback_entry = struct {
    const sdlGetError = @import("sdl/SdlPlatform.zig").sdlGetError;

    fn main(init: process.Init.Minimal) !u8 {
        if (comptime sdl.ZIG_SDL_MAIN_USE_CALLBACKS == 1)
            @compileError("Should not call main() when ZIG_SDL_MAIN_USE_CALLBACKS = 1");

        // NOTE(jae): 2026-05-05
        // If need custom setup for another platform, look at callMain() in lib/std/start.zig
        default_init.init(init);
        errdefer default_init.deinit();

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
        if (sdl.ZIG_SDL_MAIN_USE_CALLBACKS == 1) {
            _ = argc;
            _ = argv;
            default_init.initNoArg();
        }

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
        @import("sdl/SdlPlatform.zig").logUnhandledError(err);
        switch (builtin.os.tag) {
            .freestanding, .other => {},
            else => if (@errorReturnTrace()) |trace| dumpErrorReturnTrace(trace),
        }
        return sdl.SDL_APP_FAILURE;
    }
};

const sdl_zig_entry = struct {
    fn main(init: process.Init.Minimal) !void {
        // NOTE(jae): 2026-05-05
        // If need custom setup for another platform, look at callMain() in lib/std/start.zig
        default_init.init(init);
        errdefer default_init.deinit();

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

/// SDL_logFn can be used for platforms with non-standard logging styles
fn SDL_logFn(
    comptime message_level: LogLevel,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = comptime message_level.asText() ++ if (scope != .default) "(" ++ @tagName(scope) ++ "): " else "";
    const full_format = prefix ++ format ++ "\x00";
    var buf: [full_format.len + 512 + 1]u8 = undefined;
    const line = bufPrint(&buf, full_format, args) catch l: {
        buf[buf.len - 3 - 1 ..][0..4].* = "...\x00".*;
        break :l &buf;
    };
    sdl.SDL_Log(line[0..].ptr);
}
