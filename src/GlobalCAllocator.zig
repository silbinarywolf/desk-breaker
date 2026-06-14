//! Setup allocation functions for third-party C libraries like SDL, ImGui, etc

// comptime {
//     _ = @import("GlobalCppAllocator.zig");
// }

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const imgui = @import("imgui");
const assert = std.debug.assert;

const log = std.log.scoped(.GlobalCAllocator);

const use_sdl_mutex = builtin.os.tag == .freestanding or builtin.object_format == .c;

var _instance_data: GlobalCAllocator = .{
    .io = undefined,
    .mu = .init,
    .allocator = undefined,
    .allocations = .empty,
};
var instance: ?*GlobalCAllocator = null;

const debug_log_allocs = false;

/// malloc uses the largest alignment of the hardware platform, which on at most 64-bit platforms is 16 bytes
pub const default_alignment = std.mem.Alignment.@"16";

io: std.Io,
mu: if (use_sdl_mutex) SdlMutex else std.Io.Mutex,
allocator: std.mem.Allocator,
allocations: std.AutoHashMap(*anyopaque, usize).Unmanaged,
contexts: AllocatorContextList = .{},

const AllocatorContextList = struct {
    sdl: AllocatorContext = .empty,
    imgui: AllocatorContext = .empty,
    cpp: AllocatorContext = .empty,
};

const AllocatorContext = struct {
    current_memory_usage: usize,
    // largest_memory_usage: usize,

    const empty: AllocatorContext = .{
        .current_memory_usage = 0,
        // .largest_memory_usage = 0,
    };
};

pub fn init(allocator: std.mem.Allocator, io: std.Io) error{SdlFailed}!*GlobalCAllocator {
    assert(instance == null);

    // Init
    _instance_data = .{
        .io = io,
        .mu = .init,
        .allocator = allocator,
        .allocations = .empty,
        .contexts = .{},
    };
    if (use_sdl_mutex) {
        try _instance_data.mu.create();
    }
    instance = &_instance_data;

    // Use self logic
    const self = instance.?;

    // Setup SDL memory allocator
    // - Do not use custom allocator on platforms that use SDL_CreateMutex as it uses the SDL allocator
    if (!use_sdl_mutex) {
        if (!sdl.SDL_SetMemoryFunctions(sdlMalloc, sdlCalloc, sdlRealloc, sdlFree)) {
            return error.SdlFailed;
        }
        imgui.igSetAllocatorFunctions(imguiMalloc, imguiFree, self);
    }

    return self;
}

pub inline fn getInstance() *GlobalCAllocator {
    return instance.?;
}

pub fn deinit(self: *GlobalCAllocator) void {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);

    const sdl_allocations = sdl.SDL_GetNumAllocations();
    const remaining_alloc_count = self.allocations.count();
    if (remaining_alloc_count > 0) {
        log.debug("c_allocations count: {}, SDL allocations: {}", .{ remaining_alloc_count, sdl_allocations });
    }

    self.allocations.deinit(self.allocator);
    self.allocator = undefined;
    self.allocations = undefined;
    instance = null;
}

/// WARNING: Must have unlocked mutex before calling this
inline fn putEntry(self: *GlobalCAllocator, context: *AllocatorContext, mem: [*]align(default_alignment.toByteUnits()) u8, size: usize) void {
    self.allocations.put(self.allocator, @ptrCast(mem), size) catch
        @panic("c_allocator: out of memory");
    context.current_memory_usage += size;
}

/// WARNING: Must have unlocked mutex before calling this
inline fn handleStatsForRemovedEntry(self: *GlobalCAllocator, context: *AllocatorContext, ptr: *anyopaque, old_size: usize) void {
    _ = self;
    _ = ptr;
    context.current_memory_usage -= old_size;
}

pub fn malloc(self: *GlobalCAllocator, context: *AllocatorContext, size: usize) ?*anyopaque {
    if (debug_log_allocs) log.debug("malloc: start", .{});
    defer if (debug_log_allocs) log.debug("malloc: end", .{});

    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);

    const mem = self.allocator.alignedAlloc(
        u8,
        default_alignment,
        size,
    ) catch @panic("c_allocator: out of memory");

    self.putEntry(context, mem.ptr, size);

    return mem.ptr;
}

fn calloc(self: *GlobalCAllocator, context: *AllocatorContext, elements: usize, size_of_each: usize) ?*anyopaque {
    if (debug_log_allocs) log.debug("calloc: start (elements: {}, size of each: {})", .{ elements, size_of_each });
    defer if (debug_log_allocs) log.debug("calloc: end", .{});

    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);

    // calloc takes elements + size
    const size = elements * size_of_each;

    const mem = self.allocator.alignedAlloc(
        u8,
        default_alignment,
        size,
    ) catch @panic("c_allocator: out of memory");

    // calloc zeroes out after allocation
    @memset(mem[0..], 0);

    self.putEntry(context, mem.ptr, size);

    return mem.ptr;
}

fn realloc(self: *GlobalCAllocator, context: *AllocatorContext, optional_ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (debug_log_allocs) log.debug("realloc: start", .{});
    defer if (debug_log_allocs) log.debug("realloc: end", .{});

    const ptr: *anyopaque = optional_ptr orelse {
        // If null pointer given, do a regular allocation
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        const mem = self.allocator.alignedAlloc(u8, default_alignment, size) catch @panic("c_allocator: out of memory");
        self.putEntry(context, mem.ptr, size);
        return mem.ptr;
    };

    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    const old_size: usize = self.allocations.get(ptr) orelse unreachable;
    const old_mem = @as([*]align(default_alignment.toByteUnits()) u8, @ptrCast(@alignCast(ptr)))[0..old_size];
    const new_mem = self.allocator.realloc(old_mem, size) catch @panic("c_allocator: out of memory");

    // remove entry
    const removed = self.allocations.remove(ptr);
    assert(removed);
    self.handleStatsForRemovedEntry(context, ptr, old_size);

    // Add new entry
    self.putEntry(context, new_mem.ptr, size);
    return new_mem.ptr;
}

pub fn free(self: *GlobalCAllocator, context: *AllocatorContext, maybe_ptr: ?*anyopaque) void {
    const ptr = maybe_ptr orelse return;

    if (debug_log_allocs) log.debug("free: start {?}", .{maybe_ptr});
    defer if (debug_log_allocs) log.debug("free: end {?}", .{maybe_ptr});

    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);

    const size = self.allocations.fetchRemove(@ptrCast(ptr)).?.value;
    const mem = @as([*]align(default_alignment.toByteUnits()) u8, @ptrCast(@alignCast(ptr)))[0..size];

    self.allocator.free(mem);
    self.handleStatsForRemovedEntry(context, ptr, size);
}

fn sdlMalloc(size: usize) callconv(.c) ?*anyopaque {
    const self = instance.?;
    return self.malloc(&self.contexts.sdl, size);
}

fn sdlCalloc(elements: usize, size_of_each: usize) callconv(.c) ?*anyopaque {
    const self = instance.?;
    return self.calloc(&self.contexts.sdl, elements, size_of_each);
}

fn sdlRealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const self = instance.?;
    return self.realloc(&self.contexts.sdl, ptr, size);
}

fn sdlFree(ptr: ?*anyopaque) callconv(.c) void {
    const self = instance.?;
    return self.free(&self.contexts.sdl, ptr);
}

fn imguiMalloc(size: usize, user_context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self: *GlobalCAllocator = @ptrCast(@alignCast(user_context.?));
    return self.malloc(&self.contexts.imgui, size);
}

fn imguiFree(ptr: ?*anyopaque, user_context: ?*anyopaque) callconv(.c) void {
    const self: *GlobalCAllocator = @ptrCast(@alignCast(user_context.?));
    return self.free(&self.contexts.imgui, ptr);
}

const SdlMutex = struct {
    impl: *sdl.SDL_Mutex,

    pub const init = .{
        .impl = undefined,
    };

    fn create(mu: *SdlMutex) error{SdlFailed}!void {
        const sdl_mutex = sdl.SDL_CreateMutex() orelse return error.SdlFailed;
        mu.* = .{ .impl = sdl_mutex };
    }

    inline fn lockUncancelable(mu: *SdlMutex, _: std.Io) void {
        sdl.SDL_LockMutex(mu.impl);
    }

    inline fn unlock(mu: *SdlMutex, _: std.Io) void {
        sdl.SDL_UnlockMutex(mu.impl);
    }
};

const GlobalCAllocator = @This();
