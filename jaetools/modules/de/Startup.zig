///! My own customized version of Zig std.process.Init
const process = @import("std").process;
const Allocator = @import("std").mem.Allocator;
const Io = @import("std").Io;
const Platform = @import("de.zig").Platform;
const builtin = @import("builtin");
const heap = @import("std").heap;

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

const empty_minimal: process.Init.Minimal = .{
    .args = .{ .vector = &[0][*:0]const u8{} },
    .environ = .empty,
};

const use_debug_allocator = !builtin.cpu.arch.isWasm() and switch (builtin.mode) {
    .Debug => true,
    .ReleaseSafe => !builtin.link_libc, // Not ideal, but the best we have for now.
    .ReleaseFast, .ReleaseSmall => !builtin.link_libc and builtin.single_threaded, // Also not ideal.
};

var debug_allocator: heap.DebugAllocator(.{}) = .init;

var threaded: Io.Threaded = undefined;

pub inline fn initNoArg(s: *Startup) void {
    return s.init(.{
        .args = .{ .vector = &[0][*:0]const u8{} },
        .environ = .empty,
    });
}

pub fn init(s: *Startup, minimal: process.Init.Minimal) void {
    const gpa = if (use_debug_allocator)
        debug_allocator.allocator()
    else if (builtin.link_libc)
        heap.c_allocator
    else if (builtin.cpu.arch.isWasm())
        heap.wasm_allocator
    else if (!builtin.single_threaded)
        heap.smp_allocator
    else
        comptime unreachable;

    errdefer if (use_debug_allocator) {
        _ = debug_allocator.deinit(); // Leaks do not affect return code.
    };

    // NOTE(jae): 2026-06-29
    // Don't bother for this
    //
    // const arena_backing_allocator = if (builtin.cpu.arch.isWasm()) gpa else std.heap.page_allocator;
    // var arena_allocator = std.heap.ArenaAllocator.init(arena_backing_allocator);
    // errdefer arena_allocator.deinit();

    threaded = .init(gpa, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    errdefer threaded.deinit();

    s.* = .{
        .args = minimal.args,
        .environ = minimal.environ,
        .gpa = gpa,
        .io = threaded.io(),
        // Initialize later in lifecycle
        .platform = undefined,
    };
}

pub fn deinit(_: *Startup) void {
    threaded.deinit();
    if (use_debug_allocator) {
        _ = debug_allocator.deinit(); // Leaks do not affect return code.
    }
}

const Startup = @This();
