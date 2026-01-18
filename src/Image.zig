const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const wuffszig = @import("wuffszig.zig");

const native_endian = builtin.target.cpu.arch.endian();

surface: *sdl.SDL_Surface,
buffer: []const u8,

pub const Format = enum {
    rgba32, // sdl.SDL_PIXELFORMAT_RGBA32 / WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL
    bgra32, // sdl.SDL_PIXELFORMAT_BGRA32 / WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL
};

pub fn loadPng(allocator: std.mem.Allocator, image_buffer: []const u8) !Image {
    const PixelFormat: Image.Format = .rgba32;
    // NOTE(jae): 2025-04-19
    // Not sure if this Wuffs format translates correctly endianness-wise so
    // this might be completely incorrect on big-endian systems (ie. Nintendo Wii)
    // Not sure what else uses big-endian these days.
    const wuffs_pixel_format: wuffszig.PixelFormat = switch (PixelFormat) {
        .rgba32 => .rgba_non_premul,
        .bgra32 => .bgra_non_premul,
    };
    const sdl_pixel_format = switch (PixelFormat) {
        .rgba32 => sdl.SDL_PIXELFORMAT_RGBA32, // little endian (SDL_PIXELFORMAT_RGBA32 == SDL_PIXELFORMAT_ABGR8888), big endian (SDL_PIXELFORMAT_RGBA32 == SDL_PIXELFORMAT_RGBA8888)
        .bgra32 => sdl.SDL_PIXELFORMAT_BGRA32, // little endian (SDL_PIXELFORMAT_BGRA32 == SDL_PIXELFORMAT_ARGB8888), big endian (SDL_PIXELFORMAT_BGRA32 == SDL_PIXELFORMAT_BGRA8888)
    };

    var decoder = try wuffszig.PngDecoder.init(allocator);
    defer decoder.deinit();
    decoder.setStream(image_buffer);
    const header = try decoder.decodeHeader();
    const destination_info = try wuffszig.DestinationHeader.calculate(header.width, header.height, wuffs_pixel_format);

    const destination_buffer = try allocator.alloc(u8, destination_info.buffer_size);
    errdefer allocator.free(destination_buffer);
    try decoder.decodeInto(wuffs_pixel_format, destination_buffer);

    const destination_stride_or_pitch = destination_info.width * (destination_info.bits_per_pixel / 8);

    const surface = sdl.SDL_CreateSurfaceFrom(
        @intCast(destination_info.width),
        @intCast(destination_info.height),
        sdl_pixel_format,
        destination_buffer.ptr,
        @intCast(destination_stride_or_pitch),
    ) orelse {
        return error.SdlFailed;
    };
    errdefer sdl.SDL_DestroySurface(surface);

    return .{
        .surface = surface,
        .buffer = destination_buffer,
    };
}

pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
    sdl.SDL_DestroySurface(self.surface);
    allocator.free(self.buffer);
    // self.image.deinit(allocator);
    // self.* = undefined;
}

const Image = @This();
