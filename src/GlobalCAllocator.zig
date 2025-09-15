//! Setup allocation functions for third-party C libraries like SDL, ImGui, etc

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const imgui = @import("imgui");
const assert = std.debug.assert;

const log = std.log.scoped(.GlobalCAllocator);

var global_c_allocator: ?GlobalCAllocator = null;

/// Should be used anywhere global_c_allocator is modified
var global_c_allocator_mutex: std.Thread.Mutex = .{};

const debug_log_allocs = false;

const default_alignment_size = 16;
const default_alignment = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14) default_alignment_size else std.mem.Alignment.@"16";

allocator: std.mem.Allocator,
allocations: std.AutoHashMap(usize, usize),

pub fn init(allocator: std.mem.Allocator) error{SdlSetMemoryFunctionsFailed}!*@This() {
    assert(global_c_allocator == null);

    // Init
    global_c_allocator = .{
        .allocator = allocator,
        .allocations = std.AutoHashMap(usize, usize).init(allocator),
    };
    const self = &global_c_allocator.?;

    // Setup
    if (!sdl.SDL_SetMemoryFunctions(sdlMalloc, sdlCalloc, sdlRealloc, sdlFree)) {
        return error.SdlSetMemoryFunctionsFailed;
    }
    imgui.igSetAllocatorFunctions(imguiMalloc, imguiFree, self);

    return self;
}

pub fn deinit(self: *@This()) void {
    global_c_allocator_mutex.lock();
    defer global_c_allocator_mutex.unlock();

    assert(global_c_allocator != null);

    const sdl_allocationms = sdl.SDL_GetNumAllocations();
    const remaining_alloc_count = self.allocations.count();
    if (remaining_alloc_count > 0) {
        log.debug("c_allocations count: {}, SDL allocations: {}", .{ remaining_alloc_count, sdl_allocationms });
    }
    self.allocations.deinit();

    self.allocator = undefined;
    self.allocations = undefined;

    global_c_allocator = null;
}

pub inline fn malloc(self: *@This(), size: usize) ?*anyopaque {
    if (debug_log_allocs) log.debug("malloc: start", .{});
    defer if (debug_log_allocs) log.debug("malloc: end", .{});

    const mem = self.allocator.alignedAlloc(
        u8,
        default_alignment,
        size,
    ) catch @panic("c_allocator: out of memory");

    self.allocations.put(@intFromPtr(mem.ptr), size) catch @panic("c_allocator: out of memory");

    return mem.ptr;
}

pub inline fn calloc(self: *@This(), elements: usize, size_of_each: usize) ?*anyopaque {
    if (debug_log_allocs) log.debug("calloc: start (elements: {}, size of each: {})", .{ elements, size_of_each });
    defer if (debug_log_allocs) log.debug("calloc: end", .{});

    // calloc takes elements + size
    const size = elements * size_of_each;

    const mem = self.allocator.alignedAlloc(
        u8,
        default_alignment,
        size,
    ) catch @panic("c_allocator: out of memory");

    // calloc zeroes out after allocation
    @memset(mem[0..size], 0);

    self.allocations.put(@intFromPtr(mem.ptr), size) catch @panic("c_allocator: out of memory");

    return mem.ptr;
}

pub inline fn realloc(self: *@This(), ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (debug_log_allocs) log.debug("realloc: start", .{});
    defer if (debug_log_allocs) log.debug("realloc: end", .{});

    const old_size = if (ptr != null) self.allocations.get(@intFromPtr(ptr.?)).? else 0;
    const old_mem = if (old_size > 0)
        @as([*]align(default_alignment_size) u8, @ptrCast(@alignCast(ptr)))[0..old_size]
    else
        @as([*]align(default_alignment_size) u8, undefined)[0..0];

    const new_mem = self.allocator.realloc(old_mem, size) catch @panic("c_allocator: out of memory");

    if (ptr != null) {
        const removed = self.allocations.remove(@intFromPtr(ptr.?));
        assert(removed);
    }

    self.allocations.put(@intFromPtr(new_mem.ptr), size) catch @panic("c_allocator: out of memory");

    return new_mem.ptr;
}

pub inline fn free(self: *@This(), maybe_ptr: ?*anyopaque) void {
    const ptr = maybe_ptr orelse return;

    if (debug_log_allocs) log.debug("free: start {?}", .{maybe_ptr});
    defer if (debug_log_allocs) log.debug("free: end {?}", .{maybe_ptr});

    const size = self.allocations.fetchRemove(@intFromPtr(ptr)).?.value;
    const mem = @as([*]align(default_alignment_size) u8, @ptrCast(@alignCast(ptr)))[0..size];

    self.allocator.free(mem);
}

fn sdlMalloc(size: usize) callconv(.c) ?*anyopaque {
    global_c_allocator_mutex.lock();
    defer global_c_allocator_mutex.unlock();

    const self = &global_c_allocator.?;
    return self.malloc(size);
}

fn sdlCalloc(elements: usize, size_of_each: usize) callconv(.c) ?*anyopaque {
    global_c_allocator_mutex.lock();
    defer global_c_allocator_mutex.unlock();

    const self = &global_c_allocator.?;
    return self.calloc(elements, size_of_each);
}

fn sdlRealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    global_c_allocator_mutex.lock();
    defer global_c_allocator_mutex.unlock();

    const self = &global_c_allocator.?;
    return self.realloc(ptr, size);
}

fn sdlFree(ptr: ?*anyopaque) callconv(.c) void {
    global_c_allocator_mutex.lock();
    defer global_c_allocator_mutex.unlock();

    const self = &global_c_allocator.?;
    return self.free(ptr);
}

fn imguiMalloc(size: usize, user_context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self: *GlobalCAllocator = @ptrCast(@alignCast(user_context));
    global_c_allocator_mutex.lock();
    defer global_c_allocator_mutex.unlock();
    return self.malloc(size);
}

fn imguiFree(ptr: ?*anyopaque, user_context: ?*anyopaque) callconv(.c) void {
    const self: *GlobalCAllocator = @ptrCast(@alignCast(user_context));
    global_c_allocator_mutex.lock();
    defer global_c_allocator_mutex.unlock();
    return self.free(ptr);
}

const GlobalCAllocator = @This();

// fn stbiRealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
//     return cRealloc(ptr, size);
// }

// extern var stbiFreePtr: ?*const fn (maybe_ptr: ?*anyopaque) callconv(.c) void;

// extern var stbttFreePtr: ?*const fn (maybe_ptr: ?*anyopaque) callconv(.c) void;

// fn stbiFree(maybe_ptr: ?*anyopaque) callconv(.c) void {
//     cFree(maybe_ptr);
// }

// fn stbttFree(maybe_ptr: ?*anyopaque) callconv(.c) void {
//     cFree(maybe_ptr);
// }

// fn stbttMalloc(size: usize) callconv(.c) ?*anyopaque {
//     return cMalloc(size);
// }

// fn stbiMalloc(size: usize) callconv(.c) ?*anyopaque {
//     return cMalloc(size);
// }

// extern var stbiReallocPtr: ?*const fn (ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
