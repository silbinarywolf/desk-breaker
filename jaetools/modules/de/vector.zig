const std = @import("std");

// NOTE(jae): 2026-06-09
// LSP is worse for generic types right now so lets just have the types exist manually
//
// pub fn Vector2(comptime T: type) type {
//     return struct {
//         x: T,
//         y: T,
//
//         pub const zero: Self = .{ .x = 0, .y = 0 };
//
//         /// convert vector to 32-bit float
//         pub fn float(vec: Self) Vector2f {
//             return .{
//                 .x = @floatFromInt(vec.x),
//                 .y = @floatFromInt(vec.y),
//             };
//         }
//
//         const mixin = Vector2Mixin(Self, T);
//
//         pub const init = mixin.init;
//         pub const addValue = mixin.addValue;
//
//         const Self = @This();
//     };
// }

fn Vector2Mixin(comptime Vector: type, comptime T: type) type {
    return struct {
        fn init(x: T, y: T) Vector {
            return .{ .x = x, .y = y };
        }

        /// Add single value to the given vector
        fn addValue(vec: *Vector, value: T) void {
            vec.x += value;
            vec.y += value;
        }
    };
}

/// 16-bit unsigned Vector with x and y fields
/// Range: 0 to 65535
pub const Vector2us = extern struct {
    x: u16,
    y: u16,

    pub const zero: Vector2us = .{ .x = 0, .y = 0 };

    /// convert vector from 16-bit unsigned integer to 32-bit float
    pub fn float(vec: Vector2us) Vector2f {
        return .{
            .x = @floatFromInt(vec.x),
            .y = @floatFromInt(vec.y),
        };
    }

    const mixin = Vector2Mixin(Vector2us, u16);

    pub const init = mixin.init;
    pub const addValue = mixin.addValue;
};

/// 16-bit signed Vector with x and y fields
/// Range: -32,768 to 32,767
pub const Vector2s = extern struct {
    x: i16,
    y: i16,

    pub const zero: Vector2s = .{ .x = 0, .y = 0 };

    /// convert vector from 16-bit signed integer to 32-bit float
    pub fn float(vec: Vector2s) Vector2f {
        return .{
            .x = @floatFromInt(vec.x),
            .y = @floatFromInt(vec.y),
        };
    }

    const mixin = Vector2Mixin(Vector2s, i16);

    pub const init = mixin.init;
    pub const addValue = mixin.addValue;
};

/// 24-bit signed Vector with x and y fields
/// Range: -8,388,608 to 8,388,607
pub const Vector2i = struct {
    x: i24,
    y: i24,

    pub const zero: Vector2i = .{ .x = 0, .y = 0 };

    /// convert vector from 24-bit signed integer to 32-bit float
    pub fn float(vec: Vector2i) Vector2f {
        return .{
            .x = vec.x,
            .y = vec.y,
        };
    }

    const mixin = Vector2Mixin(Vector2i, i24);

    pub const init = mixin.init;
    pub const addValue = mixin.addValue;
};

/// 32-bit floating-point Vector with x and y fields
pub const Vector2f = extern struct {
    x: f32,
    y: f32,

    pub const zero: Vector2f = .{ .x = 0, .y = 0 };

    /// convert vector from 32-bit float to 32-bit signed integer
    pub fn int(vec: Vector2f) Vector2i {
        return .{
            .x = @intFromFloat(vec.x),
            .y = @intFromFloat(vec.y),
        };
    }

    const mixin = Vector2Mixin(Vector2f, f32);

    pub const init = mixin.init;
    pub const addValue = mixin.addValue;
};

test {
    std.testing.refAllDecls(@This());
}
