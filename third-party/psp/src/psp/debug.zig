const std = @import("std");
const ge = @import("ge.zig");
const display = @import("display.zig");
const module = @import("module.zig");

const ScreenWidthPowOfTwo: comptime_int = 512; // std.math.ceilPowerOfTwoAssert(u32, display.ScreenWidth);

const Screen = struct {
    x: u32,
    y: u32,
    vram_base: [*]u32,

    var bg_col: u32 = 0x00000000;
    var fg_col: u32 = 0xFFFFFFFF;
    const back_col_enable = false;
    const msxFont = @embedFile("resources/msxfont2.bin");

    pub fn init(screen: *Screen) void {
        const vram_base = @as([*]u32, @ptrFromInt(0x40000000 | @intFromPtr(ge.sceGeEdramGetAddr())));
        screen.* = .{
            .x = 0,
            .y = 0,
            .vram_base = vram_base,
        };

        _ = display.sceDisplaySetMode(.lcd, display.ScreenWidth, display.ScreenHeight);
        _ = display.sceDisplaySetFrameBuf(vram_base, ScreenWidthPowOfTwo, .format8888, .nextvsync);

        screen.clear();
    }

    fn clear(screen: *Screen) void {
        const vram_base = screen.vram_base;
        // Clears the screen to the clear color (default is black)
        var i: usize = 0;
        while (i < ScreenWidthPowOfTwo * display.ScreenHeight) : (i += 1) {
            const ClearColor: u32 = 0xFF000000;
            vram_base[i] = ClearColor;
        }
    }

    fn print(screen: *Screen, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\n') {
                screen.y += 1;
                screen.x = 0;
            } else if (text[i] == '\t') {
                screen.x += 4;
            } else {
                putchar(@as(u32, screen.x) * 8, @as(u32, screen.y) * 8, screen.vram_base, text[i]);
                screen.x += 1;
            }

            if (screen.x > 60) {
                screen.x = 0;
                screen.y += 1;
                if (screen.y > 34) {
                    screen.y = 0;
                    // NOTE: Do not clear, just restart and write over self
                    // screen.clear();
                }
            }
        }
    }

    fn putchar(cx: u32, cy: u32, vram_base: [*]u32, ch: u8) void {
        const off: usize = cx + (cy * ScreenWidthPowOfTwo);

        var i: usize = 0;
        while (i < 8) : (i += 1) {
            var j: usize = 0;

            while (j < 8) : (j += 1) {
                const mask: u32 = 128;

                const idx: u32 = @as(u32, ch - 32) * 8 + i;
                const glyph: u8 = msxFont[idx];

                if ((glyph & (mask >> @as(@import("std").math.Log2Int(c_int), @intCast(j)))) != 0) {
                    vram_base[j + i * ScreenWidthPowOfTwo + off] = fg_col;
                } else if (back_col_enable) {
                    vram_base[j + i * ScreenWidthPowOfTwo + off] = bg_col;
                }
            }
        }
    }
};

/// panic is a custom panic handler for Zig
pub const panic = std.debug.FullPanic(zigPanic);

fn zigPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = first_trace_addr;

    var screen: Screen = undefined;
    screen.init();
    screen.print("!!! PSP HAS PANICKED !!!\n");
    screen.print("REASON: ");
    screen.print(msg);
    // //TODO: Stack Traces after STD.
    // //if (@errorReturnTrace()) |trace| {
    // //    std.debug.dumpStackTrace(trace.*);
    // //}
    screen.print("\nExiting in 10 seconds...");

    module.exitErr();
    while (true) {}
}
