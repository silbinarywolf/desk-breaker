const builtin = @import("builtin");
const de = @import("de");
const App = @import("App.zig");
const std = @import("std");
const log = @import("std").log;
const debug = @import("std").debug;
const process = @import("std").process;

pub const de_options: de.Options = .{
    .application_type = App,
    .platform_type = .sdl_zig,
};

pub const main = de.main;

// comptime {
//     if (builtin.abi.isAndroid()) {
//         @export(&SDL_main, .{ .name = "SDL_main", .linkage = .strong });
//     }
// }

// const use_debug_allocator = !builtin.cpu.arch.isWasm() and switch (builtin.mode) {
//     .Debug => true,
//     .ReleaseSafe => !builtin.link_libc, // Not ideal, but the best we have for now.
//     .ReleaseFast, .ReleaseSmall => !builtin.link_libc and builtin.single_threaded, // Also not ideal.
// };

// var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

// /// This needs to be exported for Android builds
// fn SDL_main() callconv(.c) void {
//     if (!comptime builtin.abi.isAndroid()) {
//         @compileError("SDL_main should not be called outside of Android builds");
//     }
//     const gpa = if (use_debug_allocator)
//         debug_allocator.allocator()
//     else if (builtin.link_libc)
//         std.heap.c_allocator
//     else if (builtin.cpu.arch.isWasm())
//         std.heap.wasm_allocator
//     else if (!builtin.single_threaded)
//         std.heap.smp_allocator
//     else
//         comptime unreachable;

//     defer if (use_debug_allocator) {
//         _ = debug_allocator.deinit(); // Leaks do not affect return code.
//     };

//     const arena_backing_allocator = if (builtin.cpu.arch.isWasm()) gpa else std.heap.page_allocator;

//     var arena_allocator = std.heap.ArenaAllocator.init(arena_backing_allocator);
//     defer arena_allocator.deinit();

//     var threaded: std.Io.Threaded = .init(gpa, .{
//         .argv0 = .init(.{ .vector = undefined }),
//         .environ = .{ .block = undefined },
//     });
//     defer threaded.deinit();

//     main(process.Init{
//         .arena = &arena_allocator,
//         .gpa = gpa,
//         .environ_map = undefined,
//         .io = threaded.io(),
//         .minimal = .{ .args = undefined, .environ = undefined },
//         .preopens = undefined,
//     }) catch |err| {
//         log.err("{t}", .{err});
//         if (@errorReturnTrace()) |trace| {
//             debug.dumpErrorReturnTrace(trace);
//         }
//     };
// }
