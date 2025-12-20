const std = @import("std");
const builtin = @import("builtin");
const time = std.time;
const sdl = @import("sdl");
const imgui = @import("imgui");
const android = @import("android");
const psp = @import("psp");
const windows = @import("windows.zig");
const datetime = @import("datetime.zig");

const ProcessList = @import("ProcessList.zig");
const winregistry = @import("winregistry.zig");
const UserConfig = @import("UserConfig.zig");
const GlobalCAllocator = @import("GlobalCAllocator.zig");
const Duration = @import("Duration.zig");
const Window = @import("Window.zig");
const App = @import("App.zig");
const UserSettings = App.UserSettings;
const Timer = App.Timer;

const ScreenOverview = @import("ScreenOverview.zig");
const ScreenAddEditTimer = @import("ScreenAddEditTimer.zig");
const ScreenOptions = @import("ScreenOptions.zig");
const ScreenIncomingBreak = @import("ScreenIncomingBreak.zig");
const ScreenTakingBreak = @import("ScreenTakingBreak.zig");

const log = std.log.default;
const assert = std.debug.assert;

comptime {
    if (builtin.cpu.arch.isMIPS()) {
        asm (psp.module_info("Zig PSP App", 0, 1, 0));
    }
}

/// custom standard options for Android
pub const std_options: std.Options = if (builtin.abi.isAndroid())
    .{
        .logFn = android.logFn,
    }
else if (builtin.os.tag == .freestanding)
    .{
        .logFn = SDL_logFn,
    }
else
    .{};

/// SDL_logFn can be used for freestanding platforms
fn SDL_logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    var buf: [500]u8 = undefined;
    const line = std.fmt.bufPrintZ(&buf, prefix ++ format, args) catch l: {
        buf[buf.len - 3 ..][0..3].* = "...".*;
        break :l &buf;
    };
    sdl.SDL_Log(line[0..].ptr);
    _ = message_level;
}

// custom panic handler for Android
pub const panic = if (builtin.abi.isAndroid())
    android.panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

comptime {
    if (builtin.abi.isAndroid()) {
        @export(&SDL_main, .{ .name = "SDL_main", .linkage = .strong });
    } else if (builtin.os.tag == .freestanding) {
        // @export(&psp_main, .{ .name = "main", .linkage = .strong });
        // @export(&freestanding_start, .{ .name = "__start", .linkage = .strong });
    }
}

fn psp_main() callconv(.c) void {
    _ = std.start.callMain();
}

fn freestanding_start() callconv(.c) void {
    _ = std.start.callMain();
}

/// This needs to be exported for Android builds
fn SDL_main() callconv(.c) void {
    if (comptime builtin.abi.isAndroid()) {
        _ = std.start.callMain();
    } else {
        @compileError("SDL_main should not be called outside of Android builds");
    }
}

// NOTE(jae): 2025-04-13
// After testing on Emscripten and Android, seemingly not needed anymore.
// pub const os = if (builtin.os.tag == .emscripten and builtin.abi.isAndroid()) struct {
//     pub const heap = struct {
//         /// Force web browser to use c allocator with Emscripten
//         pub const page_allocator = std.heap.c_allocator;
//     };
// } else std.os;

const MousePos = struct {
    x: f32,
    y: f32,

    pub fn diff(self: MousePos, other: MousePos) MousePos {
        return .{
            .x = @abs(self.x - other.x),
            .y = @abs(self.y - other.y),
        };
    }
};

const has_debug_allocator = (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) and
    (builtin.cpu.arch != .wasm32 and builtin.cpu.arch != .wasm64 and builtin.os.tag != .freestanding);

var debug_allocator = if (has_debug_allocator)
    std.heap.DebugAllocator(.{
        // NOTE(jae): 2024-04-21
        // Safety is true for debug/releaseSafe builds
        // .safety = true,
        // Extra debugging options to avoid segfaults
        // .never_unmap = true,
        // .retain_metadata = true,
    }).init
else
    void;

var has_opened_from_tray = false;

var prev_mouse_pos: MousePos = .{ .x = 0, .y = 0 };

var global_c_allocator: *GlobalCAllocator = undefined;

/// app_global is stored here mostly for Emscripten to access app via emscripten_set_main_loop
var app_global: App = undefined;

pub fn unload() !void {}

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        // Check if application is already running
        // - Debug mode has its own unique ID so I can be running the release build and my own testing build simultaneously
        //
        // https://stackoverflow.com/a/14176581
        const unique_application_name = if (builtin.mode == .Debug)
            "da5cd5eb-0d82-476a-9280-af68ae22a64d"
        else
            "b15383a6-be9d-418b-9aa9-c1c462d93431";
        _ = windows.createMutex(null, false, unique_application_name) catch |err| switch (err) {
            error.AlreadyExists => {
                log.debug("application already running", .{});
                return;
            },
            else => {
                log.err("unexpected CreateMutex error: {}", .{err});
                return err;
            },
        };
    }

    // init app
    const app = &app_global;
    try start(app);

    if (builtin.os.tag == .freestanding) {
        @panic("TODO: Implement support for other platforms if using freestanding (like calling SDL functions only)");
    }

    // run update
    if (builtin.os.tag != .emscripten) {
        while (!app.has_quit) {
            try update(app);
        }
        try quit(app);
    } else {
        std.os.emscripten.emscripten_set_main_loop(struct {
            pub fn emscripten_loop() callconv(.c) void {
                if (app.has_quit) {
                    std.os.emscripten.emscripten_cancel_main_loop();
                    quit(app) catch |err| {
                        log.err("application quit had error: {}", .{err});
                        return;
                    };
                    log.debug("application quit", .{});
                    return;
                }
                update(app) catch |err| {
                    log.err("application has error: {}", .{err});
                    std.os.emscripten.emscripten_cancel_main_loop();
                };
            }
        }.emscripten_loop, 0, 0);
    }
}

pub fn start(app: *App) !void {
    const allocator = gpa: {
        if (has_debug_allocator) break :gpa debug_allocator.allocator();
        if (builtin.os.tag != .emscripten and (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64)) break :gpa std.heap.wasm_allocator;
        if (builtin.os.tag == .emscripten or (builtin.os.tag == .freestanding and builtin.link_libc)) break :gpa std.heap.c_allocator;
        break :gpa std.heap.smp_allocator;
    };

    // NOTE(jae): 2024-01-12
    // Plan is to use date data for daily data usage storage
    // - Main priority: Daily checklist
    // - Other things: Stats (active computer usage)
    // const date = try datetime.GetLocalDateTime();
    // std.debug.panic("local: {}, utc: {}", .{ date, datetime.GetUTCDateTime() });

    // Setup custom allocators for SDL and Imgui
    // - We can use the GeneralPurposeAllocator to catch memory leaks
    global_c_allocator = try GlobalCAllocator.init(allocator);
    errdefer global_c_allocator.deinit();

    // Load your settings
    var user_settings: *UserSettings = allocator.create(UserSettings) catch |err| {
        log.err("unable to allocate UserSettings: {}", .{err});
        return err;
    };
    errdefer allocator.destroy(user_settings);

    user_settings.* = UserConfig.load(allocator) catch |err| switch (err) {
        // If no file found, use default
        error.FileNotFound => UserSettings.default,
        else => {
            log.err("unable to load user config: {}", .{err});
            return err;
        },
    };
    errdefer user_settings.deinit(allocator);

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY)) {
        log.err("unable to initialize SDL: {s}", .{sdl.SDL_GetError()});
        return error.SDLInitializationFailed;
    }
    errdefer sdl.SDL_Quit();

    if (builtin.os.tag == .freestanding) {
        @panic("TODO: Implement support for other platforms if using freestanding (like calling SDL functions only)");
    }

    app.* = try App.init(allocator, user_settings);
    errdefer app.deinit();

    // setup main application window
    app.window = blk: {
        const main_app_window = try allocator.create(Window);
        main_app_window.* = try Window.init(.{
            .title = App.Name,
            .width = 680,
            .height = 480,
            .resizeable = true,
            .icon = app.icon.surface,
        });
        break :blk main_app_window;
    };

    // setup tray
    if (app.has_tray_support) {
        app.tray = sdl.SDL_CreateTray(app.icon.surface, App.Name) orelse blk: {
            const err = sdl.SDL_GetError();
            if (err != null) {
                log.err("unable to initialize SDL tray: {s}", .{err});
                return error.SDLInitializationFailed;
            }
            break :blk null;
        };
    }

    // initialize tray
    if (app.tray) |tray| {
        const tray_menu: *sdl.SDL_TrayMenu = sdl.SDL_CreateTrayMenu(tray) orelse {
            log.err("unable to initialize SDL tray menu: {s}", .{sdl.SDL_GetError()});
            return error.SDLInitializationFailed;
        };
        if (sdl.SDL_InsertTrayEntryAt(tray_menu, -1, "Open", sdl.SDL_TRAYENTRY_BUTTON)) |tray_entry| {
            sdl.SDL_SetTrayEntryCallback(tray_entry, struct {
                pub fn callback(_: ?*anyopaque, _: ?*sdl.SDL_TrayEntry) callconv(.c) void {
                    has_opened_from_tray = true;
                }
            }.callback, app);
        }
        if (sdl.SDL_InsertTrayEntryAt(tray_menu, -1, "Quit", sdl.SDL_TRAYENTRY_BUTTON)) |tray_entry| {
            sdl.SDL_SetTrayEntryCallback(tray_entry, struct {
                pub fn callback(app_ptr: ?*anyopaque, _: ?*sdl.SDL_TrayEntry) callconv(.c) void {
                    const app_in_tray: *App = @ptrCast(@alignCast(app_ptr));
                    app_in_tray.has_quit = true;
                }
            }.callback, app);
        }
    }

    // If using Wayland set that we have no global mouse support
    if (builtin.os.tag == .linux) {
        const video_driver_c = sdl.SDL_GetCurrentVideoDriver();
        if (video_driver_c != null) {
            const video_driver = std.mem.span(sdl.SDL_GetCurrentVideoDriver());
            if (std.mem.eql(u8, video_driver, "wayland")) {
                app.has_global_mouse_support = false;
            }
        }
    }
    if (!app.has_global_mouse_support) {
        app.is_user_active = true;
    }

    // Setup initial "previous mouse position"
    _ = sdl.SDL_GetGlobalMouseState(&prev_mouse_pos.x, &prev_mouse_pos.y);

    // DEBUG: Test break screen
    // state.user_settings.default_time_till_break = Duration.init(30 * time.ns_per_s);
    // state.user_settings.default_break_time = Duration.init(5 * time.ns_per_s);
}

pub fn quit(app: *App) error{MemoryLeak}!void {
    app.deinit();
    sdl.SDL_Quit();
    global_c_allocator.deinit();
    if (has_debug_allocator) {
        if (debug_allocator.deinit() == .leak) {
            log.err("application has memory leak", .{});
            return error.MemoryLeak;
        }
    }
}

var frames_without_app_input: u16 = 0;

pub fn update(app: *App) !void {
    {
        const allocator = app.allocator;
        _ = app.temp_allocator.reset(.retain_capacity);

        const current_frame_time = sdl.SDL_GetPerformanceCounter();

        // Handle tray logic
        if (has_opened_from_tray) {
            has_opened_from_tray = false;

            if (app.window) |app_window| {
                _ = sdl.SDL_RestoreWindow(app_window.window);
            } else {
                // If no app window exists, create it
                app.window = blk: {
                    const app_window = try allocator.create(Window);
                    app_window.* = try Window.init(.{
                        .title = App.Name,
                        .width = 680,
                        .height = 480,
                        .resizeable = true,
                        .icon = app.icon.surface,
                    });
                    break :blk app_window;
                };
                frames_without_app_input = 0;
            }
        }
        if (app.minimize_to_tray) {
            app.minimize_to_tray = false;
            if (app.window) |app_window| {
                app_window.deinit();
                allocator.destroy(app_window);
                app.window = null;
            }
        }

        // Event polling
        {
            // Threshold to have responsive event polling based on:
            // - Wait N frames before we do WaitEvent so that the initial rendering sets things up nicely
            // - Wait N frames after keyboard presses for responsiveness
            const FrameWithoutInputThreshold: u16 = 250;
            if (frames_without_app_input < FrameWithoutInputThreshold) {
                frames_without_app_input += 1;
            }
            // If below threshold, poll events, otherwise wait with timeout then collect subsequent events
            // with a poll
            var is_polling_events = frames_without_app_input < FrameWithoutInputThreshold;
            while (true) {
                var sdl_event: sdl.SDL_Event = undefined;
                // Get next event
                {
                    const ev_res = evblk: {
                        const is_main_window_minimized_or_occluded = blk: {
                            const app_window = app.window orelse break :blk false;
                            const window_flags = sdl.SDL_GetWindowFlags(app_window.window);
                            break :blk (window_flags & sdl.SDL_WINDOW_MINIMIZED != 0) or
                                (window_flags & sdl.SDL_WINDOW_OCCLUDED != 0);
                        };

                        // log.debug("frames_without_app_input: {}, is minimized or occluded: {}", .{ frames_without_app_input, is_main_window_minimized_or_occluded });
                        if (is_polling_events) {
                            // Poll events and be responsive
                            break :evblk sdl.SDL_PollEvent(&sdl_event);
                        }

                        // If minimized, increase the wait event delay to be even more power-saving
                        const is_powersaving_mode = is_main_window_minimized_or_occluded and
                            app.popup_windows.items.len == 0 and
                            app.taking_break_windows.items.len == 0;
                        if (is_powersaving_mode) {
                            if (app.time_till_next_timer_complete()) |timer| {
                                const safe_delay_in_ms: u64 = 5000;
                                const safe_delay = app.user_settings.incoming_break_or_default().nanoseconds + (safe_delay_in_ms * time.ns_per_ms);
                                if (timer.time_till_next_break.nanoseconds >= safe_delay) {
                                    // 5000ms timeout so we can at least occassionally detect global mouse position
                                    break :evblk sdl.SDL_WaitEventTimeout(&sdl_event, safe_delay_in_ms);
                                }
                            }
                        }

                        // This either blocks until {N}ms passed or we get an event
                        // Conserves CPU. Opted for 500ms so it definitely refreshes every second
                        // for the live update on the home screen.
                        //
                        // We also need the timeout so that it eventually reads global mouse position
                        // outside of this loop to detect activity.
                        break :evblk sdl.SDL_WaitEventTimeout(&sdl_event, 500);
                    };
                    if (!ev_res) {
                        break;
                    }
                    // If we received one event, start polling
                    is_polling_events = true;
                }

                // process events
                {
                    if (app.window) |window| {
                        imgui.igSetCurrentContext(window.imgui_context);
                        _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(&sdl_event));
                    }
                    for (app.popup_windows.items) |*window| {
                        imgui.igSetCurrentContext(window.imgui_context);
                        _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(&sdl_event));
                    }
                    for (app.taking_break_windows.items) |*window| {
                        imgui.igSetCurrentContext(window.imgui_context);
                        _ = imgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(&sdl_event));
                    }
                }

                switch (sdl_event.type) {
                    sdl.SDL_EVENT_QUIT => {
                        // If triggered quit, close entire app
                        app.has_quit = true;
                        break;
                    },
                    sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                        const event = sdl_event.window;
                        if (app.window) |app_window| {
                            if (event.windowID == sdl.SDL_GetWindowID(app_window.window)) {
                                app.has_quit = true;
                                // TODO: Add ability to configure when/how we minimize to system tray
                                // If closed the main app window and has no system tray, close entire app
                                // if (app.tray == null) {
                                //     app.has_quit = true;
                                // } else {
                                //     app.minimize_to_tray = true;
                                // }
                                break;
                            }
                        }
                    },
                    sdl.SDL_EVENT_MOUSE_MOTION => {
                        frames_without_app_input = 0;
                    },
                    sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                        const event = sdl_event.button;
                        if (event.down) {
                            frames_without_app_input = 0;
                        }
                    },
                    sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                        const event = sdl_event.button;
                        if (!event.down) {
                            frames_without_app_input = 0;
                        }
                        switch (event.button) {
                            sdl.SDL_BUTTON_LEFT => {
                                // event.state == sdl.SDL_RELEASED
                                if (!event.down) {
                                    if (app.break_mode.held_down_timer != null) {
                                        app.break_mode.held_down_timer = null;
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    sdl.SDL_EVENT_KEY_UP => {
                        const event = sdl_event.key;
                        if (event.down) {
                            frames_without_app_input = 0;
                        }
                        switch (event.key) {
                            sdl.SDLK_ESCAPE => {
                                // event.state == sdl.SDL_RELEASED
                                if (!event.down) {
                                    // If released reset the held down timer
                                    if (app.break_mode.held_down_timer == null) {
                                        app.break_mode.held_down_timer = try time.Timer.start();
                                    }
                                }
                                app.break_mode.esc_or_exit_presses += 1;
                            },
                            else => {},
                        }
                    },
                    sdl.SDL_EVENT_WINDOW_RESTORED => {
                        frames_without_app_input = 0;
                    },
                    else => {},
                }
            }
        }

        // Set new ImGui Frame *after* event polling, otherwise you get rare instances of sticky buttons / interactivity
        // (as per example code: https://github.com/ocornut/imgui/blob/master/examples/example_sdl2_sdlrenderer2/main.cpp)
        {
            for (app.popup_windows.items) |*window| {
                window.imguiNewFrame();
            }
            for (app.taking_break_windows.items) |*window| {
                window.imguiNewFrame();
            }
            if (app.window) |app_window| {
                app_window.imguiNewFrame();
            }
        }

        // Check process list every N seconds
        if (ProcessList.is_supported and
            app.process_check_timer.read() >= 5 * time.ns_per_s)
        {
            // Reset timer
            app.process_check_timer.reset();

            // Check each process
            var pl = try ProcessList.open();
            defer pl.close();
            const has_process_running_that_should_halt_activity_timer = procblk: {
                while (try pl.next()) |entry| {
                    const filepath = entry.exe_filepath;

                    // Debug process name
                    log.info("process: {s}", .{entry.exe_filepath});

                    // By default disallow any application launched from the Steam directory
                    //
                    // This pattern covers both the default folder and additional folders
                    // - Default:               C:/Steam/steamapps/common/Expedition 33
                    // - Custom Additional HDD: D:/SteamLibrary/steamapps/common/Among Us
                    if (std.mem.indexOfPos(u8, filepath, 0, "/steamapps/common/") != null) {
                        // Current app matches a Steam application
                        var has_match = true;

                        // Steam has tools as well, so we have a whitelist to allow various tools/servers/etc
                        const steamapps_allow_contains_list = [_][]const u8{
                            // Source SDK
                            "/steamapps/common/SourceSDK",
                            // VR
                            "/steamapps/common/SteamVR",
                            "/steamapps/common/OVR Toolkit",
                            "/steamapps/common/OVR_AdvancedSettings",
                            // Game Engine / Tools
                            "/steamapps/common/gamemaker_studio",
                            "/steamapps/common/Substance 3D Designer 2022",
                            // Dedicated Servers
                            "/steamapps/common/PalServer",
                            // - /steamapps/common/Project Zomboid Dedicated Server
                            // - /steamapps/common/Source 2007 Dedicated Server
                            // - /steamapps/common/Left 4 Dead 2 Dedicated Server
                            // - /steamapps/common/Age of Chivalry Dedicated Server
                            " Dedicated Server",
                            // Dedicated Servers
                            // - steamapps/common/SatisfactoryDedicatedServer
                            "DedicatedServer",
                            // Chivalry Dedicated Servers
                            // - steamapps/common/chivalry_ded_server
                            // - steamapps/common/chivalry_dw_ded_server
                            "_ded_server",
                            // Game Modding
                            "/steamapps/common/Automation_SDK",
                            "/steamapps/common/RustSDK",
                            "/steamapps/common/Project Zomboid Modding Tools",
                            "/left 4 dead 2/bin/", // ie. /bin/hammer.exe, /bin/hlfaceposer.exe, root directory of "left 4 dead 2" has the actual exe
                            // Games (UI heavy, interruption won't cause game over states)
                            "/steamapps/common/Automation",
                        };
                        for (steamapps_allow_contains_list) |allow_contains| {
                            has_match = has_match and std.mem.indexOfPos(u8, filepath, 0, allow_contains) == null;
                        }
                        if (has_match) {
                            break :procblk true;
                        }
                    }

                    // Check Minecraft Launcher games
                    {
                        var has_match = false;
                        const minecraft_launcher_disallow_contains_list = [_][]const u8{
                            "/Minecraft", // Java Edition, from main launcher: C:/Program Files/WindowsApps/Microsoft.4297127D64EC6_2.5.2.0_x64__8wekyb3d8bbwe/Minecraft.exe
                            "/Minecraft.Windows", // Bedrock Edition, from main launcher: C:/Program Files/WindowsApps/MICROSOFT.MINECRAFTUWP_1.21.13101.0_x64__8wekyb3d8bbwe/Minecraft.Windows.exe
                        };
                        for (minecraft_launcher_disallow_contains_list) |allow_contains| {
                            has_match = has_match and std.mem.indexOfPos(u8, filepath, 0, allow_contains) == null;
                        }
                        if (has_match) {
                            // Exclude processes like the Minecraft Launcher itself
                            const minecraft_launcher_allow_contains_list = [_][]const u8{
                                "/Minecraft Launcher/Content",
                            };
                            for (minecraft_launcher_allow_contains_list) |allow_contains| {
                                has_match = has_match and std.mem.indexOfPos(u8, filepath, 0, allow_contains) == null;
                            }
                            if (has_match) {
                                break :procblk true;
                            }
                        }
                    }

                    // Check misc applications
                    {
                        const disallow_contains_list_os = if (comptime builtin.os.tag == .linux and !builtin.abi.isAndroid())
                            [_][]const u8{
                                // "/Dolphin" // Excluded on Linux by default as it has a File Explorer called Dolphin
                            }
                        else
                            [_][]const u8{
                                "/Dolphin", // Don't exclude on Linux by default as it has a File Explorer called Dolphin
                            };
                        const disallow_contains_list = [_][]const u8{
                            // Emulation
                            "/retroarch",
                            "/duckstation-", // ie. duckstation-qt-x64-ReleaseLTCG.exe
                            "/ePSXe",
                            "/pcsxr",
                            "/mednafen",
                            "/fceux",
                            "/mGBA",
                            "/mupen64plus",
                            "/bsnes",
                            "/snes9x",
                            "/VisualBoyAdvance",
                            "/Cemu",
                            "/shadPS4", // ie. shadPS4QtLauncher.exe
                            "/Ryujinx",
                            "/xemu",
                            "/xenia",
                            // Games
                            "/soh", // Ship of Harkinian
                            "/BarkleyV120",
                            "/AgosClient",
                            "/Bubsy3d",
                            "/starsector", // Untested, may not work due to running under Java. Can be installed anywhere, "starsector.exe"
                        } ++ disallow_contains_list_os;

                        var has_match = false;
                        for (disallow_contains_list) |disallow_contains| {
                            has_match = has_match or std.mem.indexOfPos(u8, filepath, 0, disallow_contains) != null;
                        }
                        if (has_match) {
                            break :procblk true;
                        }
                    }
                }
                break :procblk false;
            };
            if (has_process_running_that_should_halt_activity_timer) {
                if (!app.is_game_active) {
                    app.is_game_active = true;
                }
            } else {
                if (app.is_game_active) {
                    if (app.user_settings.settings.is_activity_break_enabled) {
                        const time_till_next_break = app.user_settings.time_till_break_or_default().diff(app.activity_timer.read());
                        // TODO: Make activity timer give 2 minute interval instead of just resetting if below 2 mins
                        if (time_till_next_break.nanoseconds <= 120 * time.ns_per_s) {
                            app.activity_timer.reset();
                            app.snooze_activity_break_timer = null;
                        }
                    }
                    app.is_game_active = false;
                }
            }
        }

        // Detect activity and handle timers to pop-up break window
        {
            // Detect global mouse movement
            var curr_mouse_pos: MousePos = undefined;
            _ = sdl.SDL_GetGlobalMouseState(&curr_mouse_pos.x, &curr_mouse_pos.y);
            defer prev_mouse_pos = curr_mouse_pos;
            const diff = curr_mouse_pos.diff(prev_mouse_pos);
            if (diff.x >= 5 and
                diff.y >= 5)
            {
                app.time_since_last_input = try std.time.Timer.start();
                app.is_user_active = true;
            }

            // Only make inactive if we have global mouse support
            if (app.has_global_mouse_support) {
                if (app.mode == .regular) {
                    // Track time using computer
                    if (app.time_since_last_input) |*time_since_last_input| {
                        // TODO: Make inactivity time a variable
                        const inactivity_duration = 5 * std.time.ns_per_min;
                        if (time_since_last_input.read() > inactivity_duration) {
                            app.is_user_active = false;
                            app.activity_timer.reset();
                        }
                    } else {
                        app.activity_timer.reset();
                        app.is_user_active = false;
                    }
                }
            }

            // Detect when to change mode
            switch (app.mode) {
                .regular, .incoming_break => {
                    if (app.time_till_next_timer_complete()) |next_timer| {
                        if (next_timer.time_till_next_break.nanoseconds <= 0) {
                            const computer_was_in_sleep_mode = blk: {
                                // If it's an activity timer or sleep timer and the difference in time
                                // is over N seconds in the past, assume the computer was in sleep mode for a long
                                // period of time and ignore the break logic.
                                if (next_timer.id == .activity_timer or next_timer.id == .snooze_timer) {
                                    if (next_timer.time_till_next_break.nanoseconds <= -180 * time.ns_per_s) {
                                        break :blk true;
                                    }
                                }
                                break :blk false;
                            };
                            if (!computer_was_in_sleep_mode) {
                                try app.change_mode(.taking_break);
                            } else {
                                app.activity_timer.reset();
                                app.snooze_activity_break_timer = null;
                            }
                        } else if (next_timer.time_till_next_break.nanoseconds <= app.user_settings.incoming_break_or_default().nanoseconds) {
                            try app.change_mode(.incoming_break);
                        } else {
                            // If cancelled timer in main window
                            if (app.mode == .incoming_break) {
                                try app.change_mode(.regular);
                            }
                        }
                    } else {
                        if (app.mode == .incoming_break) {
                            // If we somehow got in this buggy state and there is no next break
                            // then switch to regular mode
                            try app.change_mode(.regular);
                        }
                    }
                },
                .taking_break => {
                    const time_active_in_ns = app.break_mode.timer.read();
                    const time_till_break_over = app.break_mode.duration.diff(time_active_in_ns);
                    if (time_till_break_over.nanoseconds <= 0) {
                        app.snooze_times_in_a_row = 0;
                        try app.change_mode(.regular);
                    }
                },
            }
        }

        // Main application window
        if (app.window) |app_window| appwindowblk: {
            imgui.igSetCurrentContext(app_window.imgui_context);

            const viewport = @as(?*imgui.ImGuiViewport, imgui.igGetMainViewport()) orelse {
                break :appwindowblk; // If no viewport skip
            };
            const viewport_pos = viewport.Pos;
            const viewport_size = viewport.Size;

            imgui.igSetNextWindowPos(viewport_pos, imgui.ImGuiCond_None, .{});
            imgui.igSetNextWindowSize(viewport_size, imgui.ImGuiCond_None);
            if (!imgui.igBegin("###mainwindow", null, App.ImGuiDefaultWindowFlags)) {
                break :appwindowblk;
            }
            defer imgui.igEnd();

            // Heading
            {
                const uiHeadingButton = struct {
                    pub fn uiHeadingButton(label: [:0]const u8, is_selected: bool) bool {
                        if (is_selected) {
                            const activeColor = imgui.igGetStyleColorVec4(imgui.ImGuiCol_ButtonActive)[0];
                            imgui.igPushStyleColor_Vec4(imgui.ImGuiCol_Button, activeColor);
                            imgui.igPushStyleColor_Vec4(imgui.ImGuiCol_ButtonHovered, activeColor);
                        }
                        const r = imgui.igButton(label, .{});
                        if (is_selected) {
                            imgui.igPopStyleColor(2);
                        }
                        imgui.igSameLine(0, 4);
                        return r;
                    }
                }.uiHeadingButton;

                var maybe_next_ui_screen: ?App.Screen = null;

                if (uiHeadingButton("Overview", app.ui.screen == .overview)) {
                    maybe_next_ui_screen = .overview;
                }

                const has_selected_add_or_edit_timer = app.ui.screen == .timer;
                const add_edit_timer: [:0]const u8 = if (!has_selected_add_or_edit_timer or app.ui.timer.id == -1)
                    "Add Timer"
                else
                    "Edit Timer";
                if (uiHeadingButton(add_edit_timer, has_selected_add_or_edit_timer)) {
                    maybe_next_ui_screen = .timer;
                }
                if (uiHeadingButton("Options", app.ui.screen == .options)) {
                    maybe_next_ui_screen = .options;
                }
                if (uiHeadingButton("Take a break", false)) {
                    try app.change_mode(.taking_break);
                }
                if (app.tray) |_| {
                    if (uiHeadingButton("Minimize to tray", false)) {
                        app.minimize_to_tray = true;
                    }
                }
                imgui.igNewLine();
                imgui.igSeparatorEx(imgui.ImGuiSeparatorFlags_Horizontal, 2);
                if (maybe_next_ui_screen) |next_ui_screen| uiblk: {
                    // do nothing if same
                    if (app.ui.screen == next_ui_screen) {
                        break :uiblk;
                    }
                    switch (next_ui_screen) {
                        .overview => {
                            // no state to reset
                        },
                        .timer => {
                            ScreenAddEditTimer.open(app);
                        },
                        .options => {
                            try ScreenOptions.open(app);
                        },
                    }
                    app.ui.screen = next_ui_screen;
                }
            }

            switch (app.ui.screen) {
                .overview => {
                    try ScreenOverview.render(app);
                },
                .timer => {
                    try ScreenAddEditTimer.render(app);
                },
                .options => {
                    try ScreenOptions.render(app);
                },
            }
        }

        // Render Incoming break popup(s)
        try ScreenIncomingBreak.render(app);

        // Taking break windows
        try ScreenTakingBreak.render(app);

        // NOTE(jae): 2024-07-28
        // May want to disable this logic if using vsync
        const total_frame_time = sdl.SDL_GetPerformanceCounter() - current_frame_time;
        const total_frame_time_in_ms = 1000.0 * (@as(f64, @floatFromInt(total_frame_time)) / @as(f64, @floatFromInt(sdl.SDL_GetPerformanceFrequency())));
        const tick_rate: u64 = 60; // assume 60 FPS always
        const tick_rate_in_ms: f64 = 1000 / tick_rate;
        const time_to_delay_for = @floor(tick_rate_in_ms - total_frame_time_in_ms);
        if (time_to_delay_for >= 1) {
            const delay = @as(u32, @intFromFloat(time_to_delay_for));
            // std.debug.print("delay amount: {}, tick rate in ms: 0.{d}\n", .{ delay, @as(u64, @intFromFloat(total_frame_time_in_ms * 100)) });
            sdl.SDL_Delay(delay);
        }

        // Render
        const renderWindow = struct {
            pub fn renderWindow(window: *Window) void {
                const renderer = window.renderer;

                // Setup ImGui Context + Render Scale
                assert(window.imgui_new_frame);
                imgui.igSetCurrentContext(window.imgui_context);
                imgui.igRender();
                const io = &imgui.igGetIO_ContextPtr(imgui.igGetCurrentContext())[0];
                _ = sdl.SDL_SetRenderScale(renderer, io.DisplayFramebufferScale.x, io.DisplayFramebufferScale.y);

                // Clear screen
                _ = sdl.SDL_SetRenderDrawColor(renderer, 20, 20, 20, 0);
                _ = sdl.SDL_RenderClear(renderer);

                // Render ImGui Draw Calls
                imgui.ImGui_ImplSDLRenderer3_RenderDrawData(@ptrCast(imgui.igGetDrawData()), @ptrCast(window.renderer));
                window.imgui_new_frame = false;

                if (!sdl.SDL_RenderPresent(renderer)) {
                    // TODO: Handle not rendering?
                    @panic("SDL_RenderPresent failed for main application window");
                }
            }
        }.renderWindow;

        // Render app window
        if (app.window) |app_window| {
            renderWindow(app_window);
        }
        for (app.popup_windows.items) |*incoming_break_window| {
            renderWindow(incoming_break_window);
        }
        for (app.taking_break_windows.items) |*taking_break_window| {
            renderWindow(taking_break_window);
        }
    }
}
