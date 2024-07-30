const std = @import("std");
const builtin = @import("builtin");
const time = std.time;
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;

const Lexer = @import("lexer.zig").Lexer;

pub const Duration = struct {
    nanoseconds: u64,

    pub fn init(nanoseconds: u64) Duration {
        return .{ .nanoseconds = nanoseconds };
    }

    pub fn diff(self: Duration, time_elapsed_in_nanoseconds: u64) Duration {
        if (self.nanoseconds <= time_elapsed_in_nanoseconds) {
            return .{ .nanoseconds = 0 };
        }
        return .{
            .nanoseconds = self.nanoseconds - time_elapsed_in_nanoseconds,
        };
    }

    pub fn format(
        self: Duration,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len == 0) std.fmt.invalidFmtError(fmt, self);
        if (comptime std.mem.eql(u8, fmt, "s")) {
            if (self.nanoseconds < 1 * time.ns_per_s) {
                try std.fmt.format(out_stream, "0 seconds", .{});
                return;
            }
            var ns = self.nanoseconds;
            if (ns >= time.ns_per_day) {
                const days = @divFloor(ns, time.ns_per_day);
                ns -= days * time.ns_per_day;
                if (days == 1) {
                    try std.fmt.format(out_stream, "{} day", .{days});
                } else {
                    try std.fmt.format(out_stream, "{} days", .{days});
                }
            }
            if (ns >= time.ns_per_hour) {
                if (ns != self.nanoseconds) {
                    try out_stream.writeByte(' ');
                }
                const hours = @divFloor(ns, time.ns_per_hour);
                ns -= hours * time.ns_per_hour;
                if (hours == 1) {
                    try std.fmt.format(out_stream, "{} hour", .{hours});
                } else {
                    try std.fmt.format(out_stream, "{} hours", .{hours});
                }
            }
            if (ns >= time.ns_per_min) {
                if (ns != self.nanoseconds) {
                    try out_stream.writeByte(' ');
                }
                const minutes = @divFloor(ns, time.ns_per_min);
                ns -= minutes * time.ns_per_min;
                if (minutes == 1) {
                    try std.fmt.format(out_stream, "{} minute", .{minutes});
                } else {
                    try std.fmt.format(out_stream, "{} minutes", .{minutes});
                }
            }
            if (ns >= time.ns_per_s) {
                if (ns != self.nanoseconds) {
                    try out_stream.writeByte(' ');
                }
                const seconds = @divFloor(ns, time.ns_per_s);
                ns -= seconds * time.ns_per_s;
                if (seconds == 1) {
                    try std.fmt.format(out_stream, "{} second", .{seconds});
                } else {
                    try std.fmt.format(out_stream, "{} seconds", .{seconds});
                }
            }
            return;
        }
        // sh stands for shorthand lmao
        if (comptime std.mem.eql(u8, fmt, "sh")) {
            if (self.nanoseconds < 1 * time.ns_per_s) {
                // empty string
                return;
            }
            var ns = self.nanoseconds;
            if (ns >= time.ns_per_day) {
                const days = @divFloor(ns, time.ns_per_day);
                ns -= days * time.ns_per_day;
                try std.fmt.format(out_stream, "{}d", .{days});
            }
            if (ns >= time.ns_per_hour) {
                if (ns != self.nanoseconds) {
                    try out_stream.writeByte(' ');
                }
                const hours = @divFloor(ns, time.ns_per_hour);
                ns -= hours * time.ns_per_hour;
                try std.fmt.format(out_stream, "{}h", .{hours});
            }
            if (ns >= time.ns_per_min) {
                if (ns != self.nanoseconds) {
                    try out_stream.writeByte(' ');
                }
                const minutes = @divFloor(ns, time.ns_per_min);
                ns -= minutes * time.ns_per_min;
                try std.fmt.format(out_stream, "{}m", .{minutes});
            }
            if (ns >= time.ns_per_s) {
                if (ns != self.nanoseconds) {
                    try out_stream.writeByte(' ');
                }
                const seconds = @divFloor(ns, time.ns_per_s);
                ns -= seconds * time.ns_per_s;
                try std.fmt.format(out_stream, "{}s", .{seconds});
            }
            return;
        }
        return std.fmt.invalidFmtError(fmt, self);
    }

    pub fn parseOptionalString(str: []const u8) error{InvalidFormat}!?Duration {
        if (str.len == 0) {
            return null;
        }
        // TODO: if string of whitespace, should also be null
        return try parseString(str);
    }

    /// ie.
    /// - 1h 30m 40s
    pub fn parseString(str: []const u8) error{InvalidFormat}!Duration {
        var l = Lexer.init(str) catch |err| switch (err) {
            error.InvalidUtf8 => return error.InvalidFormat,
        };

        var nanoseconds: u64 = 0;

        // Loop through parsing of "1h 30m 20s" up to 25 times max
        var i: u16 = 0;
        const limit: u16 = 25;
        while (i < limit) : (i += 1) {
            const d = l.next() orelse {
                if (i > 0) {
                    // exit loop if no more tokens here
                    break;
                }
                return error.InvalidFormat;
            };
            if (d.kind != .digit) {
                // if (true) @panic(@tagName(d.kind));
                return error.InvalidFormat;
            }
            const ident = l.next() orelse return error.InvalidFormat;
            if (ident.kind != .ident) {
                return error.InvalidFormat;
            }
            const digits_str = l.slice(d);
            const ident_str = l.slice(ident);
            // if (true) std.debug.print("i: {}, digit: {s}, ident: {s}\n", .{ i, digits_str, ident_str });
            const digits = std.fmt.parseInt(u64, digits_str, 10) catch return error.InvalidFormat;
            if (std.mem.eql(u8, "d", ident_str)) {
                nanoseconds += digits * time.ns_per_day;
            } else if (std.mem.eql(u8, "h", ident_str)) {
                nanoseconds += digits * time.ns_per_hour;
            } else if (std.mem.eql(u8, "m", ident_str)) {
                nanoseconds += digits * time.ns_per_min;
            } else if (std.mem.eql(u8, "s", ident_str)) {
                nanoseconds += digits * time.ns_per_s;
            } else {
                return error.InvalidFormat;
            }
        }
        if (l.next() != null) {
            return error.InvalidFormat;
        }
        return .{
            .nanoseconds = nanoseconds,
        };
    }

    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !@This() {
        const tok = try source.next();
        if (.string != tok) return error.UnexpectedToken;
        return parseString(tok.string) catch error.InvalidCharacter;
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
        if (source != .string) return error.UnexpectedToken;
        return parseString(source.string) catch error.InvalidCharacter;
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.print("\"{sh}\"", .{self});
    }
};

/// Alarm is a calendar timestamp, in seconds, relative to UTC 1970-01-01.
/// We store time in seconds as this
const Alarm = struct {
    /// seconds is signed because it is possible to have a date that is
    /// before the epoch 1970-01-01
    seconds: i64,

    // pub fn parseString(str: []const u8) void {
    //     var i: u32 = 0;
    //     while (i < str.len) {
    //         const c = str[i];
    //         if (std.ascii.isWhitespace(c)) {
    //             continue;
    //         }
    //         if (std.ascii.isDigit(c)) {
    //             while (i < str.len) {
    //                 const c = str[i];
    //             }
    //         }
    //     }
    // }
};

test "parse and format duration" {
    const TestCase = struct {
        given: []const u8,
        expected: []const u8,
    };
    const allocator = testing.allocator;
    const test_cases = [_]TestCase{
        .{
            .given = "2d 4h 18m 7s",
            .expected = "2 days 4 hours 18 minutes 7 seconds",
        },
        .{
            .given = "1h 30m 10s",
            .expected = "1 hour 30 minutes 10 seconds",
        },
        .{
            .given = "40m 1s",
            .expected = "40 minutes 1 second",
        },
        .{
            .given = "36s",
            .expected = "36 seconds",
        },
        .{
            .given = "0s",
            .expected = "0 seconds",
        },
    };
    for (test_cases) |test_case| {
        // parse with spaces - "1h 30m 17s"
        {
            const d = try Duration.parseString(test_case.given);
            const str = try std.fmt.allocPrint(allocator, "{s}", .{d});
            defer allocator.free(str);
            try testing.expectEqualSlices(u8, test_case.expected, str);
        }

        // parse without spaces - "1h30m17s"
        {
            const given_no_spaces = try std.mem.replaceOwned(u8, allocator, test_case.given, " ", "");
            defer allocator.free(given_no_spaces);
            const d = try Duration.parseString(given_no_spaces);
            const str = try std.fmt.allocPrint(allocator, "{s}", .{d});
            defer allocator.free(str);
            try testing.expectEqualSlices(u8, test_case.expected, str);
        }
    }
}
