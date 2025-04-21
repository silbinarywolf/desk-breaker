const std = @import("std");
const wuffs = @import("wuffs");
const sdl = @import("sdl");

const assert = std.debug.assert;
const log = std.log.scoped(.wuffs);

/// Based on the documented pixel format here
/// https://github.com/google/wuffs/blob/13617c4907fa9a139b88aad318f2146db3bbc508/doc/note/pixel-formats.md
pub const PixelFormat = packed struct(u32) {
    channel_0_depth: BitDepth,
    channel_1_depth: BitDepth,
    channel_2_depth: BitDepth,
    channel_3_depth: BitDepth,
    /// number of planes (minus 1), zero = interleaved
    number_of_planes: Plane,
    /// The number-of-planes (the previous field) will be 0, as the format is considered interleaved, but the 8-bit N-BGRA color data is stored in plane 3.
    palette_indexed: bool,
    /// floating point (instead of integer)
    floating_point: bool,
    endianness: Endian,
    _reserved1: u3 = 0,
    transparency: Transparency,
    _reserved2: u2 = 0,
    color_and_channel_order: ColorEncode,

    pub const BitDepth = enum(u4) {
        d0 = 0,
        d1 = 1,
        d2 = 2,
        d3 = 3,
        d4 = 4,
        d5 = 5,
        d6 = 6,
        d7 = 7,
        d8 = 8,
        d10 = 9,
        d12 = 10,
        d16 = 11,
        d24 = 12,
        d32 = 13,
        d48 = 14,
        d64 = 15,
    };

    pub const ColorEncode = enum(u4) {
        a = 0, // A (Alpha)
        y_or_ya = 2, // Y or YA (Gray, Alpha)
        yxxx = 3, // YXXX (Gray, 3 times X-padding)
        ycbcr_or_ycbcra = 4,
        ycbcrk = 5, // YCbCrK (Luma, Chroma-blue, Chroma-red, Black)
        ycocg_or_ycocga = 6, // YCoCg or YCoCgA (Luma, Chroma-orange, Chroma-green, Alpha)
        ycocgk = 7, // YCoCgK (Luma, Chroma-orange, Chroma-green, Black)
        bgr_or_bgra = 8, // BGR or BGRA (Blue, Green, Red, Alpha)
        bgrx = 9, // BGRX (Blue, Green, Red, X-padding)
        rgba_or_rgba = 10, // RGB or RGBA (Red, Green, Blue, Alpha)
        rgbx = 11, // RGBX (Red, Green, Blue, X-padding)
        cmy_or_cmya = 12, // CMY or CMYA (Cyan, Magenta, Yellow, Alpha)
        cmyk = 13, // CMYK (Cyan, Magenta, Yellow, Black)
        // From docs: all other values are reserved
    };

    pub const Endian = enum(u1) {
        little = 0,
        big = 1,
    };

    pub const Transparency = enum(u2) {
        /// no alpha channel, fully opaque
        no_alpha = 0,
        /// alpha channel, other channels are non-premultiplied
        alpha_non_premultiplied = 1,
        /// alpha channel, other channels are premultiplied
        alpha_premultiplied = 2,
        /// alpha channel, binary alpha
        alpha_binary_alpha = 3,

        comptime {
            assert(wuffs.WUFFS_BASE__PIXEL_ALPHA_TRANSPARENCY__OPAQUE == @intFromEnum(Transparency.no_alpha));
            assert(wuffs.WUFFS_BASE__PIXEL_ALPHA_TRANSPARENCY__NONPREMULTIPLIED_ALPHA == @intFromEnum(Transparency.alpha_non_premultiplied));
            assert(wuffs.WUFFS_BASE__PIXEL_ALPHA_TRANSPARENCY__PREMULTIPLIED_ALPHA == @intFromEnum(Transparency.alpha_premultiplied));
            assert(wuffs.WUFFS_BASE__PIXEL_ALPHA_TRANSPARENCY__BINARY_ALPHA == @intFromEnum(Transparency.alpha_binary_alpha));
        }
    };

    /// number of planes (minus 1), zero = interleaved
    pub const Plane = enum(u2) {
        interleaved = 0,
        p0 = 1,
        p1 = 2,
        p2 = 3,
    };

    /// Equivalent to WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL
    pub const rgba_non_premul: PixelFormat = .{
        .channel_0_depth = .d8,
        .channel_1_depth = .d8,
        .channel_2_depth = .d8,
        .channel_3_depth = .d8,
        .number_of_planes = .interleaved,
        .palette_indexed = false,
        .floating_point = false,
        .endianness = .little,
        .transparency = .alpha_non_premultiplied,
        .color_and_channel_order = .rgba_or_rgba,
    };

    /// Equivalent to WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL
    pub const bgra_non_premul: PixelFormat = .{
        .channel_0_depth = .d8,
        .channel_1_depth = .d8,
        .channel_2_depth = .d8,
        .channel_3_depth = .d8,
        .number_of_planes = .interleaved,
        .palette_indexed = false,
        .floating_point = false,
        .endianness = .little,
        .transparency = .alpha_non_premultiplied,
        .color_and_channel_order = .bgr_or_bgra,
    };

    comptime {
        assert(@as(u32, @bitCast(rgba_non_premul)) == @as(u32, @intCast(wuffs.WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL)));
        assert(@as(u32, @bitCast(bgra_non_premul)) == @as(u32, @intCast(wuffs.WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL)));
    }
};

pub const Header = struct {
    width: u31,
    height: u31,
    bits_per_pixel: u8,

    pub const empty: Header = .{
        .width = 0,
        .height = 0,
        .bits_per_pixel = 0,
    };
};

pub const DestinationHeader = struct {
    width: u31,
    height: u31,
    bits_per_pixel: u8,
    /// buffer_size expected for the decompressed buffer
    buffer_size: u32,

    pub fn calculate(expected_width: u32, expected_height: u32, destination_image_format: PixelFormat) error{ImageTooLarge}!DestinationHeader {
        var destination_pixel_config: wuffs.wuffs_base__pixel_config = undefined;
        wuffs.wuffs_base__pixel_config__set(
            &destination_pixel_config,
            @bitCast(destination_image_format),
            wuffs.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
            expected_width,
            expected_height,
        );
        const destination_buffer_size = wuffs.wuffs_base__pixel_config__pixbuf_len(&destination_pixel_config);
        if (destination_buffer_size > std.math.maxInt(u31)) {
            return error.ImageTooLarge;
        }
        const destination_width = wuffs.wuffs_base__pixel_config__width(&destination_pixel_config);
        const destination_height = wuffs.wuffs_base__pixel_config__height(&destination_pixel_config);
        const destination_bits_per_pixel = wuffs.wuffs_base__pixel_format__bits_per_pixel(&wuffs.wuffs_base__pixel_config__pixel_format(&destination_pixel_config));

        return .{
            .width = @intCast(destination_width),
            .height = @intCast(destination_height),
            .bits_per_pixel = @intCast(destination_bits_per_pixel),
            .buffer_size = @intCast(destination_buffer_size),
        };
    }
};

pub const PngDecoder = struct {
    allocator: std.mem.Allocator,
    decoder: *wuffs.wuffs_png__decoder,
    stream: wuffs.wuffs_base__io_buffer,
    header: Header,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) error{ DecoderInitializationFailed, OutOfMemory }!PngDecoder {
        const decoder_size_of = wuffs.sizeof__wuffs_png__decoder();
        const png_decoder_bytes: []u8 = try allocator.alignedAlloc(u8, 16, decoder_size_of);
        errdefer allocator.free(png_decoder_bytes);
        const decoder: *wuffs.wuffs_png__decoder = @ptrCast(png_decoder_bytes);

        if (isError(wuffs.wuffs_png__decoder__initialize(
            decoder,
            decoder_size_of,
            wuffs.WUFFS_VERSION,
            wuffs.WUFFS_INITIALIZE__DEFAULT_OPTIONS,
        ))) |status| {
            log.err("decoder failed initialization: {s}", .{statusMessage(status)});
            return error.DecoderInitializationFailed;
        }

        const stream: wuffs.wuffs_base__io_buffer = wuffs.wuffs_base__make_io_buffer(
            wuffs.wuffs_base__make_slice_u8(@constCast(data.ptr), data.len),
            wuffs.wuffs_base__make_io_buffer_meta(data.len, 0, data.len, true),
        );

        return .{
            .allocator = allocator,
            .decoder = decoder,
            .stream = stream,
            .header = .empty,
        };
    }

    pub fn deinit(self: *PngDecoder) void {
        const decoder_size_of = wuffs.sizeof__wuffs_png__decoder();
        const mem: []u8 = @as([*c]u8, @ptrCast(self.decoder))[0..decoder_size_of];
        self.allocator.free(mem);
        self.* = undefined;
    }

    pub fn decodeHeader(self: *PngDecoder) error{HeaderDecodeFailed}!Header {
        if (self.header.width != 0 and self.header.height != 0) {
            return self.header;
        }

        var config: wuffs.wuffs_base__image_config = undefined;
        if (isError(wuffs.wuffs_png__decoder__decode_image_config(
            self.decoder,
            &config,
            &self.stream,
        ))) |status| {
            log.debug("decode image config failed: {s}", .{statusMessage(status)});
            return error.HeaderDecodeFailed;
        }

        const pixel_format = wuffs.wuffs_base__pixel_config__pixel_format(&config.pixcfg);
        const width = wuffs.wuffs_base__pixel_config__width(&config.pixcfg);
        const height = wuffs.wuffs_base__pixel_config__height(&config.pixcfg);
        const bits_per_pixel = wuffs.wuffs_base__pixel_format__bits_per_pixel(&pixel_format);

        self.header = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .bits_per_pixel = @intCast(bits_per_pixel),
        };
        return self.header;
    }

    const DecodeError = error{
        OutOfMemory,
        HeaderDecodeFailed,
        BufferInvalid,
        PixelBufferSetFromSliceFailed,
        ImageTooLarge,
        DecodeFrameFailed,
        SetInterleavedFailed,
    };

    pub fn decodeInto(self: *PngDecoder, destination_image_format: PixelFormat, destination_buffer: []u8) DecodeError!void {
        const header = try self.decodeHeader();

        var destination_pixel_config: wuffs.wuffs_base__pixel_config = undefined;
        wuffs.wuffs_base__pixel_config__set(
            &destination_pixel_config,
            @bitCast(destination_image_format),
            wuffs.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
            header.width,
            header.height,
        );
        const destination_buffer_size = wuffs.wuffs_base__pixel_config__pixbuf_len(&destination_pixel_config);
        const destination_max_buffer_size = std.math.maxInt(u31);
        if (destination_buffer_size > destination_max_buffer_size) {
            log.debug("destination buffer {} exceeds max image size {}", .{ destination_buffer_size, destination_max_buffer_size });
            return error.ImageTooLarge;
        }
        if (destination_buffer_size != destination_buffer.len) {
            log.debug("destination buffer expecting {} bytes but got {}", .{ destination_buffer_size, destination_buffer.len });
            return error.BufferInvalid;
        }

        // Configure the destination
        var destination_pixel_buffer: wuffs.wuffs_base__pixel_buffer = undefined;
        if (isError(wuffs.wuffs_base__pixel_buffer__set_from_slice(
            &destination_pixel_buffer,
            &destination_pixel_config,
            wuffs.wuffs_base__make_slice_u8(destination_buffer.ptr, destination_buffer.len),
        ))) |status| {
            log.debug("destination pixel buffer set from slice failed: {s}", .{statusMessage(status)});
            return error.PixelBufferSetFromSliceFailed;
        }

        // Configure decoding

        // Configure the work buffer.
        const work_buffer_length: u32 = blk: {
            // NOTE(jae): 2025-04-13
            // We want "work_buffer_length" to always fit into "usize" so it'll work on 32-bit systems so we validate
            // this will fit in 32-bits
            const max_incl = wuffs.wuffs_png__decoder__workbuf_len(self.decoder).max_incl;
            const max_work_buffer_slice_size = 256 * 1024 * 1024; // 256 megabytes
            if (max_incl > max_work_buffer_slice_size) {
                log.debug("work buffer {} exceeds maximum size {}", .{ max_incl, max_work_buffer_slice_size });
                return error.ImageTooLarge;
            }
            break :blk @as(u32, @intCast(max_incl));
        };

        const work_buffer = try self.allocator.alignedAlloc(u8, 16, work_buffer_length);
        defer self.allocator.free(work_buffer);

        var frameDecodeOptions: wuffs.wuffs_base__decode_frame_options = .{};
        if (isError(wuffs.wuffs_png__decoder__decode_frame(
            self.decoder,
            &destination_pixel_buffer,
            &self.stream,
            wuffs.WUFFS_BASE__PIXEL_BLEND__SRC,
            wuffs.wuffs_base__make_slice_u8(work_buffer.ptr, work_buffer.len),
            &frameDecodeOptions,
        ))) |status| {
            log.debug("decode from failed: {s}, destination size: {}, work buffer size: {}", .{ statusMessage(status), destination_buffer.len, work_buffer.len });
            return error.DecodeFrameFailed;
        }

        // https://github.com/google/wuffs/blob/main/example/sdl-imageviewer/sdl-imageviewer.cc
        const destination_width = wuffs.wuffs_base__pixel_config__width(&destination_pixel_config);
        const destination_height = wuffs.wuffs_base__pixel_config__height(&destination_pixel_config);
        const destination_bits_per_pixel = wuffs.wuffs_base__pixel_format__bits_per_pixel(&wuffs.wuffs_base__pixel_config__pixel_format(&destination_pixel_config));
        const destination_stride_or_pitch = destination_width * (destination_bits_per_pixel / 8);
        if (isError(wuffs.wuffs_base__pixel_buffer__set_interleaved(
            &destination_pixel_buffer,
            &destination_pixel_config,
            wuffs.wuffs_base__make_table_u8(
                destination_buffer.ptr,
                destination_width * (destination_bits_per_pixel / 8),
                destination_height,
                destination_stride_or_pitch,
            ),
            wuffs.wuffs_base__empty_slice_u8(),
        ))) |status| {
            log.debug("set interleaved failed: {s}", .{statusMessage(status)});
            return error.SetInterleavedFailed;
        }
    }
};

fn isError(status: wuffs.wuffs_base__status) ?wuffs.wuffs_base__status {
    if (wuffs.wuffs_base__status__is_error(&status)) {
        return status;
    }
    return null;
}

fn statusMessage(status: wuffs.wuffs_base__status) [*c]const u8 {
    return wuffs.wuffs_base__status__message(&status);
}
