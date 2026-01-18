const std = @import("std");
const builtin = @import("builtin");
const time = std.time;
const mem = std.mem;

const assert = std.debug.assert;
const testing = std.testing;

const Lexer = @import("Lexer.zig");

nanoseconds: i64,

pub fn init(nanoseconds: i64) Duration {
    return .{ .nanoseconds = nanoseconds };
}

pub fn diff(self: Duration, time_elapsed_in_nanoseconds: u64) Duration {
    return .{
        .nanoseconds = self.nanoseconds - @as(i64, @intCast(time_elapsed_in_nanoseconds)),
    };
}

pub fn milliseconds(self: *const Duration) i64 {
    return self.nanoseconds / time.ns_per_ms;
}

pub fn writeString(self: *const Duration, writer: *std.io.AnyWriter) std.io.Writer.Error!void {
    if (self.nanoseconds < 1 * time.ns_per_s) {
        try std.fmt.format(writer, "0 seconds", .{});
        return;
    }
    var ns = self.nanoseconds;
    if (ns >= time.ns_per_day) {
        const days = @divFloor(ns, time.ns_per_day);
        ns -= days * time.ns_per_day;
        if (days == 1) {
            try std.fmt.format(writer, "{} day", .{days});
        } else {
            try std.fmt.format(writer, "{} days", .{days});
        }
    }
    if (ns >= time.ns_per_hour) {
        if (ns != self.nanoseconds) {
            try writer.writeByte(' ');
        }
        const hours = @divFloor(ns, time.ns_per_hour);
        ns -= hours * time.ns_per_hour;
        if (hours == 1) {
            try std.fmt.format(writer, "{} hour", .{hours});
        } else {
            try std.fmt.format(writer, "{} hours", .{hours});
        }
    }
    if (ns >= time.ns_per_min) {
        if (ns != self.nanoseconds) {
            try writer.writeByte(' ');
        }
        const minutes = @divFloor(ns, time.ns_per_min);
        ns -= minutes * time.ns_per_min;
        if (minutes == 1) {
            try std.fmt.format(writer, "{} minute", .{minutes});
        } else {
            try std.fmt.format(writer, "{} minutes", .{minutes});
        }
    }
    if (ns >= time.ns_per_s) {
        if (ns != self.nanoseconds) {
            try writer.writeByte(' ');
        }
        const seconds = @divFloor(ns, time.ns_per_s);
        ns -= seconds * time.ns_per_s;
        if (seconds == 1) {
            try std.fmt.format(writer, "{} second", .{seconds});
        } else {
            try std.fmt.format(writer, "{} seconds", .{seconds});
        }
    }
}

/// formatLong will format duration as "1 day 3 hours 58 minutes 1 second"
pub fn formatLong(self: Duration) FormatLongDuration {
    const formatter: FormatLongDuration = .{ .nanoseconds = self.nanoseconds };
    return formatter;
}

/// formatShort will format duration as "1d 3h 58m 1s"
pub fn formatShort(self: Duration) FormatShortDuration {
    const formatter: FormatShortDuration = .{ .nanoseconds = self.nanoseconds };
    return formatter;
}

/// Deprecated: Temporary until Zig 0.15+ is out
pub fn OldFormatter(Formatter: type) type {
    return struct {
        formatter: Formatter,

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            if (fmt.len == 0) std.fmt.invalidFmtError(fmt, self);
            if (!comptime std.mem.eql(u8, fmt, "f")) std.fmt.invalidFmtError(fmt, self);
            var any_writer = if (@hasDecl(@TypeOf(writer), "any")) writer.any() else writer;
            try self.formatter.format(&any_writer);
        }
    };
}

/// Format duration as "1 day 3 hours 58 minutes 1 second"
const FormatLongDuration = struct {
    nanoseconds: i64,

    pub inline fn format(self: FormatLongDuration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.nanoseconds < 1 * time.ns_per_s) {
            try writer.writeAll("0 seconds");
            return;
        }
        var ns = self.nanoseconds;
        if (ns >= time.ns_per_day) {
            const days = @divFloor(ns, time.ns_per_day);
            ns -= days * time.ns_per_day;
            if (days == 1) {
                try writer.print("{} day", .{days});
            } else {
                try writer.print("{} days", .{days});
            }
        }
        if (ns >= time.ns_per_hour) {
            if (ns != self.nanoseconds) {
                try writer.writeByte(' ');
            }
            const hours = @divFloor(ns, time.ns_per_hour);
            ns -= hours * time.ns_per_hour;
            if (hours == 1) {
                try writer.print("{} hour", .{hours});
            } else {
                try writer.print("{} hours", .{hours});
            }
        }
        if (ns >= time.ns_per_min) {
            if (ns != self.nanoseconds) {
                try writer.writeByte(' ');
            }
            const minutes = @divFloor(ns, time.ns_per_min);
            ns -= minutes * time.ns_per_min;
            if (minutes == 1) {
                try writer.print("{} minute", .{minutes});
            } else {
                try writer.print("{} minutes", .{minutes});
            }
        }
        if (ns >= time.ns_per_s) {
            if (ns != self.nanoseconds) {
                try writer.writeByte(' ');
            }
            const seconds = @divFloor(ns, time.ns_per_s);
            ns -= seconds * time.ns_per_s;
            if (seconds == 1) {
                try writer.print("{} second", .{seconds});
            } else {
                try writer.print("{} seconds", .{seconds});
            }
        }
    }
};

/// Format duration as "1d 3h 58m 1s"
const FormatShortDuration = struct {
    nanoseconds: i64,

    pub inline fn format(self: FormatShortDuration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.nanoseconds < 1 * time.ns_per_s) {
            // empty string
            return;
        }
        var ns = self.nanoseconds;
        if (ns >= time.ns_per_day) {
            const days = @divFloor(ns, time.ns_per_day);
            ns -= days * time.ns_per_day;
            try writer.print("{}d", .{days});
        }
        if (ns >= time.ns_per_hour) {
            if (ns != self.nanoseconds) {
                try writer.writeByte(' ');
            }
            const hours = @divFloor(ns, time.ns_per_hour);
            ns -= hours * time.ns_per_hour;
            try writer.print("{}h", .{hours});
        }
        if (ns >= time.ns_per_min) {
            if (ns != self.nanoseconds) {
                try writer.writeByte(' ');
            }
            const minutes = @divFloor(ns, time.ns_per_min);
            ns -= minutes * time.ns_per_min;
            try writer.print("{}m", .{minutes});
        }
        if (ns >= time.ns_per_s) {
            if (ns != self.nanoseconds) {
                try writer.writeByte(' ');
            }
            const seconds = @divFloor(ns, time.ns_per_s);
            ns -= seconds * time.ns_per_s;
            try writer.print("{}s", .{seconds});
        }
    }
};

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
        if (d.tag != .digit) {
            // if (true) @panic(@tagName(d.kind));
            return error.InvalidFormat;
        }
        const ident = l.next() orelse return error.InvalidFormat;
        if (ident.tag != .ident) {
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
        .nanoseconds = @intCast(nanoseconds),
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
    try jws.print("\"{f}\"", .{self.formatShort()});
}

const Duration = @This();

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
