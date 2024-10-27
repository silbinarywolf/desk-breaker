const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const zigimg = @import("zigimg");

const native_endian = @import("builtin").target.cpu.arch.endian();

const Image = struct {
    surface: *sdl.SDL_Surface,
    image: zigimg.ImageUnmanaged,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        sdl.SDL_DestroySurface(self.surface);
        self.image.deinit(allocator);
        // self.* = undefined;
    }
};

pub fn load_from_surface_from_buffer(allocator: std.mem.Allocator, image_buffer: []const u8) !Image {
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(image_buffer) };
    var img = try zigimg.png.PNG.readImage(allocator, &stream_source);
    errdefer img.deinit(allocator);
    const surface = try sdlSurfaceFromImage(img);
    return .{
        .surface = surface,
        .image = img,
    };
}

pub fn load_from_buffer(renderer: *sdl.SDL_Renderer, temp_allocator: std.mem.Allocator, image_buffer: []const u8) !*sdl.SDL_Texture {
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(image_buffer) };
    return load_from_source(renderer, temp_allocator, &stream_source);
}

pub fn load_from_source(renderer: *sdl.SDL_Renderer, temp_allocator: std.mem.Allocator, stream: *std.io.StreamSource) !*sdl.SDL_Texture {
    var img = try zigimg.png.PNG.readImage(temp_allocator, stream);
    defer img.deinit(temp_allocator);

    const texture = try sdlTextureFromImage(renderer, img);
    return texture;
}

const PixelMask = struct {
    red: u32,
    green: u32,
    blue: u32,
    alpha: u32,

    /// construct a pixelmask given the colorstorage.
    /// *Attention*: right now only works for 24-bit RGB, BGR and 32-bit RGBA,BGRA
    pub fn fromPixelStorage(storage: zigimg.color.PixelStorage) !PixelMask {
        switch (native_endian) {
            .little => {
                switch (storage) {
                    .bgra32 => return .{
                        .red = 0x00ff0000,
                        .green = 0x0000ff00,
                        .blue = 0x000000ff,
                        .alpha = 0xff000000,
                    },
                    .rgba32 => return .{
                        .red = 0x000000ff,
                        .green = 0x0000ff00,
                        .blue = 0x00ff0000,
                        .alpha = 0xff000000,
                    },
                    .bgr24 => return .{
                        .red = 0xff0000,
                        .green = 0x00ff00,
                        .blue = 0x0000ff,
                        .alpha = 0,
                    },
                    .rgb24 => return .{
                        .red = 0x0000ff,
                        .green = 0x00ff00,
                        .blue = 0xff0000,
                        .alpha = 0,
                    },
                    else => return error.InvalidColorStorage,
                }
            },
            .big => {
                switch (storage) {
                    .rgb24 => return .{
                        .red = 0xff0000,
                        .green = 0x00ff00,
                        .blue = 0x0000ff,
                        .alpha = 0,
                    },
                    .rgba32 => return .{
                        .red = 0xff000000,
                        .green = 0x00ff0000,
                        .blue = 0x0000ff00,
                        .alpha = 0x0000ff,
                    },

                    .bgr24 => return .{
                        .red = 0x0000ff,
                        .green = 0x00ff00,
                        .blue = 0xff0000,
                        .alpha = 0,
                    },
                    .bgra32 => return .{
                        .red = 0x0000ff00,
                        .green = 0x00ff0000,
                        .blue = 0x00ff0000,
                        .alpha = 0xff000000,
                    },
                    else => return error.InvalidColorStorage,
                }
            },
        }
    }
};

const PixelInfo = struct {
    /// bits per pixel
    bits: c_int,
    /// the pitch (see SDL docs, this is the width of the image times the size per pixel in byte)
    pitch: c_int,
    /// the pixelmask for the (A)RGB storage
    pixelmask: PixelMask,

    pub fn from(image: zigimg.ImageUnmanaged) !PixelInfo {
        const Sizes = struct { bits: c_int, pitch: c_int };
        const sizes: Sizes = switch (image.pixels) {
            .bgra32 => Sizes{ .bits = 32, .pitch = 4 * @as(c_int, @intCast(image.width)) },
            .rgba32 => Sizes{ .bits = 32, .pitch = 4 * @as(c_int, @intCast(image.width)) },
            .rgb24 => Sizes{ .bits = 24, .pitch = 3 * @as(c_int, @intCast(image.width)) },
            .bgr24 => Sizes{ .bits = 24, .pitch = 3 * @as(c_int, @intCast(image.width)) },
            else => return error.InvalidColorStorage,
        };
        const pixelmask = try PixelMask.fromPixelStorage(image.pixels);
        return .{ .bits = @as(c_int, @intCast(sizes.bits)), .pitch = @as(c_int, @intCast(sizes.pitch)), .pixelmask = pixelmask };
    }
};

fn sdlSurfaceFromImage(image: zigimg.ImageUnmanaged) error{ InvalidColorStorage, CreateRgbSurface }!*sdl.SDL_Surface {
    const pixel_info = try PixelInfo.from(image);
    const data: *anyopaque = blk: {
        switch (image.pixels) {
            .bgr24 => |bgr24| break :blk @as(*anyopaque, @ptrCast(bgr24.ptr)),
            .bgra32 => |bgra32| break :blk @as(*anyopaque, @ptrCast(bgra32.ptr)),
            .rgba32 => |rgba32| break :blk @as(*anyopaque, @ptrCast(rgba32.ptr)),
            .rgb24 => |rgb24| break :blk @as(*anyopaque, @ptrCast(rgb24.ptr)),
            else => return error.InvalidColorStorage,
        }
    };

    const surface_ptr = sdl.SDL_CreateSurfaceFrom(@as(c_int, @intCast(image.width)), @as(c_int, @intCast(image.height)), sdl.SDL_GetPixelFormatForMasks(pixel_info.bits, pixel_info.pixelmask.red, pixel_info.pixelmask.green, pixel_info.pixelmask.blue, pixel_info.pixelmask.alpha), data, pixel_info.pitch);
    if (surface_ptr == null) {
        return error.CreateRgbSurface;
    }
    errdefer sdl.SDL_DestroySurface(surface_ptr);
    return surface_ptr;
}

fn sdlTextureFromImage(renderer: *sdl.SDL_Renderer, image: zigimg.ImageUnmanaged) !*sdl.SDL_Texture {
    const surface_ptr = try sdlSurfaceFromImage(image);
    defer sdl.SDL_DestroySurface(surface_ptr);

    const texture_ptr = sdl.SDL_CreateTextureFromSurface(renderer, surface_ptr) orelse {
        return error.FailedToCreateTexture;
    };
    return texture_ptr;
}

pub const PaletteExtractorProcessor = struct {
    palette: []zigimg.color.Rgba32 = undefined,
    processed: bool = false,

    pub fn processor(self: *PaletteExtractorProcessor) zigimg.png.ReaderProcessor {
        return zigimg.png.ReaderProcessor.init(
            zigimg.png.Chunks.PLTE.id,
            self,
            null,
            processPalette,
            null,
        );
    }

    pub fn processPalette(self: *PaletteExtractorProcessor, data: *zigimg.png.PaletteProcessData) zigimg.Image.ReadError!void {
        self.processed = true;
        self.palette = data.palette;
    }
};
