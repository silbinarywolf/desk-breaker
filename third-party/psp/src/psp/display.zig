pub const ScreenWidth = 480;
pub const ScreenHeight = 272;

pub const DisplayMode = enum(c_int) {
    /// Max 480x272 at 59.94005995Hz
    lcd = 0,
    /// Vesa Vga, Max 640x480 at 59.94047618Hz
    vesa1a = 0x1A,
    /// Max 640x480 at 59.94005995Hz
    vga = 0x60,
};

/// Framebuffer pixel formats
pub const PixelFormat = enum(c_int) {
    /// 16-bit RGB 5:6:5
    format565 = 0,
    /// 16-bit RGBA 5:5:5:1
    format5551 = 1,
    /// 16-bit RGBA 4:4:4:4
    format4444 = 2,
    /// 32-bit RGBA 8:8:8:8
    format8888 = 3,
};

pub const SetBufSync = enum(c_int) {
    /// Buffer change effective next hsync
    nexthsync = 0,
    /// Buffer change effective next vsync
    nextvsync = 1,
};

/// Set display mode
///
///
/// int mode = PSP_DISPLAY_MODE_LCD;
/// int width = 480;
/// int height = 272;
/// sceDisplaySetMode(mode, width, height);
///
/// return when error, a negative value is returned.
pub extern fn sceDisplaySetMode(mode: DisplayMode, width: i32, height: i32) callconv(.c) i32;

/// Display set framebuf
/// topaddr - address of start of framebuffer (sceGeEdramGetAddr)
/// bufferwidth - buffer width (must be power of 2)
/// pixelformat - One of ::PspDisplayPixelFormats.
/// sync - One of ::PspDisplaySetBufSync
/// Returns 0 on success
pub extern fn sceDisplaySetFrameBuf(topaddr: ?*anyopaque, buffer_width_as_power_of_two: i32, pixelformat: PixelFormat, sync: SetBufSync) callconv(.c) i32;
