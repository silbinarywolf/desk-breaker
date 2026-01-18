const std = @import("std");
const wuffs = @import("wuffs");
const sdl = @import("sdl");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const log = std.log.scoped(.wuffs);

/// Wuffs image decoders will reject an image dimension (width or height) that is above 0xFF_FFFF = 16_777215 pixels,
/// even if the underlying image file format permits more.
///
/// This limit simplifies handling potential overflow. For example, width * bytes_per_pixel will not overflow an i32 and
/// width * height * bytes_per_pixel will not overflow an i64.
///
/// Similarly, converting a pixel width from integers to 26.6 fixed point units will not overflow an i32.
/// Source: https://github.com/google/wuffs/blob/43a6814dfe2764ee86637d7685cac006c72a23f9/doc/std/image-decoders.md
const max_dimension: u24 = 16_777215; // 0xFF_FFFF

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
    width: u24,
    height: u24,
    bits_per_pixel: u8,

    pub const empty: Header = .{
        .width = 0,
        .height = 0,
        .bits_per_pixel = 0,
    };
};

pub const DestinationHeader = struct {
    width: u24,
    height: u24,
    bits_per_pixel: u8,
    /// buffer_size expected for the decompressed buffer
    buffer_size: u32,

    pub fn calculate(expected_width: u24, expected_height: u24, destination_image_format: PixelFormat) error{ImageTooLarge}!DestinationHeader {
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
        if (destination_width > max_dimension or destination_height > max_dimension) {
            return error.ImageTooLarge;
        }
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
    allocator: Allocator,
    decoder: *wuffs.wuffs_png__decoder,
    stream: wuffs.wuffs_base__io_buffer,
    header: Header,

    pub fn init(allocator: Allocator) error{ DecoderInitializationFailed, OutOfMemory }!PngDecoder {
        // NOTE(jae): 2025-04-30
        // If I compiled the translate-c with "WUFFS_IMPLEMENTATION" then we can just get the size of the decode struct directly.
        // - 64-bit windows - PNG decoder sizeof: 44632, align: 8
        const decoder_size_of = wuffs.sizeof__wuffs_png__decoder();
        const png_decoder_alignment = std.mem.Alignment.@"16";
        const png_decoder_bytes = try allocator.alignedAlloc(u8, png_decoder_alignment, decoder_size_of);
        errdefer allocator.free(png_decoder_bytes);
        const decoder: *wuffs.wuffs_png__decoder = @ptrCast(png_decoder_bytes);

        if (hasStatus(wuffs.wuffs_png__decoder__initialize(
            decoder,
            decoder_size_of,
            wuffs.WUFFS_VERSION,
            wuffs.WUFFS_INITIALIZE__DEFAULT_OPTIONS,
        ))) |status| {
            log.err("decoder failed initialization: {s}", .{statusMessage(status)});
            return error.DecoderInitializationFailed;
        }

        return .{
            .allocator = allocator,
            .decoder = decoder,
            .stream = wuffs.wuffs_base__empty_io_buffer(),
            .header = .empty,
        };
    }

    pub fn setStream(self: *PngDecoder, data: []const u8) void {
        self.header = .empty;
        self.stream = wuffs.wuffs_base__make_io_buffer(
            wuffs.wuffs_base__make_slice_u8(@constCast(data.ptr), data.len),
            wuffs.wuffs_base__make_io_buffer_meta(data.len, 0, data.len, true),
        );
    }

    pub fn deinit(self: *PngDecoder) void {
        const decoder_size_of = wuffs.sizeof__wuffs_png__decoder();
        const mem: []u8 = @as([*c]u8, @ptrCast(self.decoder))[0..decoder_size_of];
        self.allocator.free(mem);
        self.* = undefined;
    }

    pub fn decodeHeader(self: *PngDecoder) error{ HeaderDecodeFailed, ImageTooLarge }!Header {
        if (self.header.width != 0 and self.header.height != 0) {
            // If already decoded header, return it
            return self.header;
        }
        if (self.stream.data.len == 0) {
            log.err("no stream configured", .{});
            return error.HeaderDecodeFailed;
        }

        var config: wuffs.wuffs_base__image_config = undefined;
        if (hasStatus(wuffs.wuffs_png__decoder__decode_image_config(
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
        if (width > max_dimension or height > max_dimension) {
            return error.ImageTooLarge;
        }
        const bits_per_pixel = wuffs.wuffs_base__pixel_format__bits_per_pixel(&pixel_format);

        self.header = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .bits_per_pixel = @intCast(bits_per_pixel),
        };
        return self.header;
    }

    const DecodeError = Allocator.Error || error{
        HeaderDecodeFailed,
        BufferInvalid,
        PixelBufferSetFromSliceFailed,
        ImageTooLarge,
        DecodeFrameConfigFailed,
        DecodeFrameFailed,
        DecodeTellMeMoreFailed,
        SetInterleavedFailed,
    };

    /// Decode PNG into the given buffer
    /// Source: https://github.com/google/wuffs/blob/43a6814dfe2764ee86637d7685cac006c72a23f9/doc/std/image-decoders-call-sequence.md
    pub fn decodeInto(self: *PngDecoder, destination_image_format: PixelFormat, destination_buffer: []u8) DecodeError!void {
        // ie. wuffs_png__decoder__decode_image_config()
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
        if (hasStatus(wuffs.wuffs_base__pixel_buffer__set_from_slice(
            &destination_pixel_buffer,
            &destination_pixel_config,
            wuffs.wuffs_base__make_slice_u8(destination_buffer.ptr, destination_buffer.len),
        ))) |status| {
            log.debug("destination pixel buffer set from slice failed: {s}", .{statusMessage(status)});
            return error.PixelBufferSetFromSliceFailed;
        }

        // Configure if interleaved
        // https://github.com/google/wuffs/blob/main/example/sdl-imageviewer/sdl-imageviewer.cc
        const destination_bits_per_pixel = wuffs.wuffs_base__pixel_format__bits_per_pixel(&wuffs.wuffs_base__pixel_config__pixel_format(&destination_pixel_config));
        if (hasStatus(wuffs.wuffs_base__pixel_buffer__set_interleaved(
            &destination_pixel_buffer,
            &destination_pixel_config,
            wuffs.wuffs_base__make_table_u8(
                destination_buffer.ptr,
                header.width * (destination_bits_per_pixel / 8), // width (in bytes)
                header.height,
                header.width * (destination_bits_per_pixel / 8), // bytes per line
            ),
            wuffs.wuffs_base__empty_slice_u8(),
        ))) |status| {
            log.debug("set interleaved failed: {s}", .{statusMessage(status)});
            return error.SetInterleavedFailed;
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

        const work_buffer_alignment = std.mem.Alignment.@"16";
        const work_buffer = try self.allocator.alignedAlloc(u8, work_buffer_alignment, work_buffer_length);
        defer self.allocator.free(work_buffer);

        // As per documentation, keep decoding frames until "end of data" is reached.
        //
        // - decode_image_config <- occurs earlier
        //
        // loop:
        // - DFC (decode_frame_config)
        // - DF (decode_frame)
        // Source: https://github.com/google/wuffs/blob/43a6814dfe2764ee86637d7685cac006c72a23f9/doc/std/image-decoders-call-sequence.md
        for (0..2) |i| {
            var frame_config: wuffs.wuffs_base__frame_config = undefined;
            if (hasStatus(wuffs.wuffs_png__decoder__decode_frame_config(self.decoder, &frame_config, &self.stream))) |status| {
                if (status.repr != null and status.repr[0] == '@') {
                    // if (status.repr == wuffs.wuffs_base__note__end_of_data) {
                    //     // As per documentation, "end of data" means no more frames to decode.
                    //     // "9. DFC (decode_frame_config) #N returning an "@end of data" status value.
                    //     // The final DFC call returns "@end of data" even if the animation loops."
                    //     // Source: https://github.com/google/wuffs/blob/43a6814dfe2764ee86637d7685cac006c72a23f9/doc/std/image-decoders-call-sequence.md
                    //     break;
                    // }

                    if (comptime builtin.object_format == .c) {
                        // NOTE(jae): 2026-01-16
                        // Hack for C output to avoid an error where Zig 0.15.2 can't access externed variables properly
                        // for the Playstation Portable SDK.
                        //
                        // Rely on the fact that "@base: end of data" is the only string that that starts with '@'
                        // and ends in " data"
                        //
                        // const base_note = "@base: end of data";
                        const status_text = std.mem.span(status.repr);
                        if (std.mem.endsWith(u8, status_text, " data")) {
                            break;
                        }
                    } else if (status.repr == wuffs.wuffs_base__note__end_of_data) {
                        // As per documentation, "end of data" means no more frames to decode.
                        // "9. DFC (decode_frame_config) #N returning an "@end of data" status value.
                        // The final DFC call returns "@end of data" even if the animation loops."
                        // Source: https://github.com/google/wuffs/blob/43a6814dfe2764ee86637d7685cac006c72a23f9/doc/std/image-decoders-call-sequence.md
                        break;
                    }
                }
                log.debug("decode frame config failed: {s}", .{statusMessage(status)});
                return error.DecodeFrameConfigFailed;
            }

            if (i != 0) {
                @panic("multiple frame decoding is not currently supported by Zig wrapper");
            }

            var frame_decode_options: wuffs.wuffs_base__decode_frame_options = .{};
            if (hasStatus(wuffs.wuffs_png__decoder__decode_frame(
                self.decoder,
                &destination_pixel_buffer,
                &self.stream,
                // NOTE(jae): 2025-04-30
                // GIF needs this: https://github.com/google/wuffs/blob/8ed5d1327bd9f5f2717d9f231f37208610f1f110/example/gifplayer/gifplayer.c#L440-L442
                wuffs.WUFFS_BASE__PIXEL_BLEND__SRC,
                wuffs.wuffs_base__make_slice_u8(work_buffer.ptr, work_buffer.len),
                &frame_decode_options,
            ))) |status| {
                log.debug("decode from failed: {s}, destination size: {}, work buffer size: {}", .{ statusMessage(status), destination_buffer.len, work_buffer.len });
                return error.DecodeFrameFailed;
            }
        }
    }
};

/// hasStatus returns the status if it's not in an OK state
///
/// we don't use "wuffs_base__status__is_error" because then we can't detect an "end of data" case when reading
/// multiple frames of data
fn hasStatus(status: wuffs.wuffs_base__status) ?wuffs.wuffs_base__status {
    if (wuffs.wuffs_base__status__is_ok(&status)) {
        return null;
    }
    return status;
}

fn statusMessage(status: wuffs.wuffs_base__status) [*c]const u8 {
    return wuffs.wuffs_base__status__message(&status);
}
