const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const Allocator = @import("std").mem.Allocator;
const assert = @import("std").debug.assert;

const log = @import("std").log.scoped(.image);

// const use_wuffs = false;
const default_pixel_format: Image.Format = .default; // TODO: Remove this line

/// If image is loaded from file, store the filename
/// TODO: Maybe remove if un-needed
filename: [:0]const u8,
surface: *sdl.SDL_Surface,
buffer: []u8,
width: u16,
height: u16,

pub const Format = enum {
    rgba32, // sdl.SDL_PIXELFORMAT_RGBA32 / WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL
    bgra32, // sdl.SDL_PIXELFORMAT_BGRA32 / WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL

    pub const default: Format = .rgba32;

    pub inline fn bytesPerPixel(pixel_format: Format) comptime_int {
        return switch (pixel_format) {
            .rgba32 => 4,
            .bgra32 => 4,
        };
    }

    inline fn pitch(pixel_format: Format, w: u16) u24 {
        return @as(u24, w) * @as(u24, pixel_format.bytesPerPixel());
    }

    pub inline fn toSdl(pixel_format: Format) sdl.SDL_PixelFormat {
        return switch (pixel_format) {
            .rgba32 => sdl.SDL_PIXELFORMAT_RGBA32, // little endian (SDL_PIXELFORMAT_RGBA32 == SDL_PIXELFORMAT_ABGR8888), big endian (SDL_PIXELFORMAT_RGBA32 == SDL_PIXELFORMAT_RGBA8888)
            .bgra32 => sdl.SDL_PIXELFORMAT_BGRA32, // little endian (SDL_PIXELFORMAT_BGRA32 == SDL_PIXELFORMAT_ARGB8888), big endian (SDL_PIXELFORMAT_BGRA32 == SDL_PIXELFORMAT_BGRA8888)
        };
    }
};

pub fn init(gpa: Allocator, width_: u16, height_: u16) !Image {
    const bytes_per_pixel = default_pixel_format.bytesPerPixel();
    const pixels_len = @as(u31, width_) * @as(u31, height_) * bytes_per_pixel;
    const pixels = try gpa.alloc(u8, pixels_len);
    errdefer gpa.free(pixels);
    // Clear the pixels to be transparent for rgba32
    @memset(pixels[0..], 0);
    return .{
        .filename = &[0:0]u8{},
        .surface = undefined,
        .buffer = pixels,
        .width = width_,
        .height = height_,
    };
}

pub fn loadPng(gpa: std.mem.Allocator, image_file: [:0]const u8) !Image {
    const surface = blk: {
        const io_stream = sdl.SDL_IOFromFile(image_file, "rb") orelse
            return error.SdlFailed;

        const temp_surface = @as(?*sdl.SDL_Surface, sdl.SDL_LoadPNG_IO(io_stream, true)) orelse
            return error.SdlFailed;
        defer sdl.SDL_DestroySurface(temp_surface);

        // NOTE(jae): 2026-05-20
        // Ensure format is RGBA for the getPixels() function so that when building a texture atlas that this
        // works as expected.
        const surface = @as(?*sdl.SDL_Surface, sdl.SDL_ConvertSurface(temp_surface, default_pixel_format.toSdl())) orelse
            return error.SdlFailed;
        break :blk surface;
    };

    return .{
        .filename = try gpa.dupeSentinel(u8, image_file, 0),
        .surface = surface,
        .buffer = &.{},
        .width = @intCast(surface.w),
        .height = @intCast(surface.h),
    };
}

pub fn loadPngFromBuffer(_: std.mem.Allocator, image_buffer: []const u8) !Image {
    // if (use_wuffs) {
    //     return loadPngWuffs(allocator, image_buffer);
    // }

    const surface = blk: {
        const io_stream = sdl.SDL_IOFromConstMem(image_buffer.ptr, image_buffer.len) orelse
            return error.SdlFailed;

        const temp_surface = @as(?*sdl.SDL_Surface, sdl.SDL_LoadPNG_IO(io_stream, true)) orelse
            return error.SdlFailed;
        defer sdl.SDL_DestroySurface(temp_surface);

        // NOTE(jae): 2026-05-20
        // Ensure format is RGBA for the getPixels() function so that when building a texture atlas that this
        // works as expected.
        const surface = @as(?*sdl.SDL_Surface, sdl.SDL_ConvertSurface(temp_surface, default_pixel_format.toSdl())) orelse
            return error.SdlFailed;
        break :blk surface;
    };

    return .{
        .filename = &[0:0]u8{},
        .surface = surface,
        .buffer = &.{},
        .width = @intCast(surface.w),
        .height = @intCast(surface.h),
    };
}

pub fn copyInto(dest_image: *Image, src_image: *const Image, src_xoffset: u16, src_yoffset: u16) !void {
    const pixel_format = default_pixel_format; // TODO: Store pixel format on Image if we support more than rgba
    const bytes_per_pixel: u31 = pixel_format.bytesPerPixel();
    comptime {
        if (pixel_format != .rgba32) @compileError("TODO: FIXME, support other types");
        if (bytes_per_pixel != 4) @compileError("TODO: FIXME, support other byte lengths than 4");
    }

    const dest_image_pixels: []u8 = dest_image.getPixels();
    const src_image_pixels: []const u8 = src_image.getPixels();
    // pitch (aka stride) = width * bytes per pixel
    const src_image_pitch: u31 = @as(u31, src_image.width) * bytes_per_pixel;
    const dest_image_width: u31 = dest_image.width;

    var row: u31 = 0;
    while (row < src_image.height) : (row += 1) {
        const tex_offset: u31 = (((@as(u31, src_yoffset) + row) * dest_image_width) + @as(u31, src_xoffset)) * bytes_per_pixel;
        const src_offset: u31 = row * src_image_pitch;
        // log.debug("row({})): dest offset: {}, src offset: {}, src stride or pitch: {} (w: {})", .{ row, tex_offset, src_offset, src_image_pitch, src_image.width });
        @memcpy(
            dest_image_pixels[tex_offset .. tex_offset + src_image_pitch],
            src_image_pixels[src_offset .. src_offset + src_image_pitch],
        );
    }
}

pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
    if (self.filename.len > 0)
        gpa.free(self.filename);
    // TODO(jae): Make this more robust, will depend on if I reintroduce Wuffs
    if (self.buffer.len > 0) {
        gpa.free(self.buffer);
    } else {
        sdl.SDL_DestroySurface(self.surface);
    }
    self.* = undefined;
}

pub fn getPixels(self: *const Image) []u8 {
    if (self.buffer.len > 0) {
        return self.buffer;
    }
    // NOTE(jae): 2026-05-20
    // If reading pixels directly it must currently be the same format as default
    assert(default_pixel_format.toSdl() == self.surface.format);

    // pitch = width * bytes_per_pixel
    const buffer_size_in_bytes: u32 = @as(u32, @intCast(self.surface.pitch)) * @as(u32, @intCast(self.surface.h));

    return @as([*c]u8, @ptrCast(self.surface.pixels.?))[0..buffer_size_in_bytes];
}

// fn loadPngWuffs(allocator: std.mem.Allocator, image_buffer: []const u8) !Image {
//     // NOTE(jae): 2025-04-19
//     // Not sure if this Wuffs format translates correctly endianness-wise so
//     // this might be completely incorrect on big-endian systems (ie. Nintendo Wii)
//     // Not sure what else uses big-endian these days.
//     const wuffs_pixel_format: wuffszig.PixelFormat = switch (default_pixel_format) {
//         .rgba32 => .rgba_non_premul,
//         .bgra32 => .bgra_non_premul,
//     };
//     const sdl_pixel_format = switch (default_pixel_format) {
//         .rgba32 => sdl.SDL_PIXELFORMAT_RGBA32, // little endian (SDL_PIXELFORMAT_RGBA32 == SDL_PIXELFORMAT_ABGR8888), big endian (SDL_PIXELFORMAT_RGBA32 == SDL_PIXELFORMAT_RGBA8888)
//         .bgra32 => sdl.SDL_PIXELFORMAT_BGRA32, // little endian (SDL_PIXELFORMAT_BGRA32 == SDL_PIXELFORMAT_ARGB8888), big endian (SDL_PIXELFORMAT_BGRA32 == SDL_PIXELFORMAT_BGRA8888)
//     };
//
//     var decoder = try wuffszig.PngDecoder.init(allocator);
//     defer decoder.deinit();
//     decoder.setStream(image_buffer);
//     const header = try decoder.decodeHeader();
//     const destination_info = try wuffszig.DestinationHeader.calculate(header.width, header.height, wuffs_pixel_format);
//
//     const destination_buffer = try allocator.alloc(u8, destination_info.buffer_size);
//     errdefer allocator.free(destination_buffer);
//     try decoder.decodeInto(wuffs_pixel_format, destination_buffer);
//
//     const destination_stride_or_pitch = destination_info.width * (destination_info.bits_per_pixel / 8);
//
//     const surface = sdl.SDL_CreateSurfaceFrom(
//         @intCast(destination_info.width),
//         @intCast(destination_info.height),
//         sdl_pixel_format,
//         destination_buffer.ptr,
//         @intCast(destination_stride_or_pitch),
//     ) orelse {
//         return error.SdlFailed;
//     };
//     errdefer sdl.SDL_DestroySurface(surface);
//
//     return .{
//         .surface = surface,
//         .buffer = destination_buffer,
//     };
// }

const Image = @This();
