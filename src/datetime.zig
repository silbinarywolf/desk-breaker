const std = @import("std");
const builtin = @import("builtin");

const posix = struct {
    /// Although not defined by the C standard,
    /// this is almost always an integral value holding the number of seconds (not counting leap seconds)
    /// since 00:00, Jan 1 1970 UTC, corresponding to POSIX time.
    const time_t = std.posix.time_t;

    const tm = extern struct {
        /// seconds after the minute [0-60]
        /// - normally in the range 0 to 59, but can be up to 60 to allow for leap seconds
        tm_sec: c_int,
        /// minutes after the hour [0-59]
        tm_min: c_int,
        /// hours since midnight [0-23]
        tm_hour: c_int,
        /// day of the month [1-31]
        /// In many implementations, including glibc, a 0 in tm_mday is interpreted as meaning the last day of the preceding month.
        tm_mday: c_int,
        tm_mon: c_int, // months since January [0-11]
        tm_year: c_int, // years since 1900
        tm_wday: c_int, // days since Sunday [0-6]
        tm_yday: c_int, // days since January 1 [0-365]
        tm_isdst: c_int, // Daylight Savings Time flag

        // The glibc version of struct tm has these additional fields

        /// offset from UTC in seconds
        /// ie. 39600
        tm_gmtoff: c_long,

        /// timezone abbreviation
        /// ie. 'AEDT' or 'AEST' for Melbourne/Sydney Australia
        tm_zone: [*c]const u8,
    };

    /// For portable code tzset(3) should be called before localtime_r().
    /// https://linux.die.net/man/3/localtime_r
    pub extern fn tzset() void;

    /// Converts given time since epoch (a time_t value pointed to by timer) into calendar time, expressed in local time, in the struct tm format.
    ///
    /// POSIX requires that localtime and localtime_r set errno to EOVERFLOW if it fails because the argument is too large.
    /// The implementation of localtime_s in Microsoft CRT is incompatible with the C standard since it has reversed parameter order and returns errno_t.
    ///
    /// For portable code tzset(3) should be called before localtime_r().
    ///
    /// https://linux.die.net/man/3/localtime_r
    pub extern fn localtime_r(time: *const time_t, tm: *tm) ?*tm;
};

const windows = struct {
    const WORD = std.os.windows.WORD;
    const LONG = std.os.windows.LONG;
    const WCHAR = std.os.windows.WCHAR;
    const DWORD = std.os.windows.DWORD;
    const WINAPI = std.os.windows.WINAPI;

    /// https://learn.microsoft.com/en-us/windows/win32/api/minwinbase/ns-minwinbase-systemtime
    const SYSTEMTIME = extern struct {
        wYear: WORD,
        // 1 = January, 12 = December
        wMonth: WORD,
        /// 0 = Sunday, 1 = Monday, 6 = Saturday
        wDayOfWeek: WORD,
        /// The day of the month. The valid values for this member are 1 through 31.
        wDay: WORD,
        /// The hour. The valid values for this member are 0 through 23.
        wHour: WORD,
        /// The minute. The valid values for this member are 0 through 59.
        wMinute: WORD,
        /// The second. The valid values for this member are 0 through 59.
        wSecond: WORD,
        /// The millisecond. The valid values for this member are 0 through 999.
        wMilliseconds: WORD,
    };

    /// Minimum supported client: Windows 2000 Professional [desktop apps | UWP apps]
    /// https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getlocaltime
    pub extern "kernel32" fn GetLocalTime(out: *SYSTEMTIME) callconv(WINAPI) void;

    /// https://learn.microsoft.com/en-us/windows/win32/api/timezoneapi/ns-timezoneapi-time_zone_information
    const TIME_ZONE_INFORMATION = extern struct {
        /// The current bias for local time translation on this computer, in minutes. The bias is the difference, in minutes,
        /// between Coordinated Universal Time (UTC) and local time.
        ///
        /// All translations between UTC and local time are based on the following formula:
        /// - UTC = local time + bias
        Bias: LONG,
        StandardName: [32]WCHAR,
        StandardDate: SYSTEMTIME,
        StandardBias: LONG,
        DaylightName: [32]WCHAR,
        DaylightDate: SYSTEMTIME,
        DaylightBias: LONG,
    };

    /// Returned if the function fails for other reasons, such as an out of memory error
    const TIME_ZONE_ID_INVALID: DWORD = 0xffffffff;

    /// Daylight saving time is not used in the current time zone, because there are no transition dates or automatic adjustment for daylight saving time is disabled.
    const TIME_ZONE_ID_UNKNOWN: DWORD = 0;

    /// The system is operating in the range covered by the StandardDate member of the TIME_ZONE_INFORMATION structure.
    const TIME_ZONE_ID_STANDARD: DWORD = 1;

    /// The system is operating in the range covered by the DaylightDate member of the TIME_ZONE_INFORMATION structure.
    const TIME_ZONE_ID_DAYLIGHT: DWORD = 2;

    /// Minimum supported client: Windows 2000 Professional [desktop apps | UWP apps]
    /// https://learn.microsoft.com/en-us/windows/win32/api/timezoneapi/nf-timezoneapi-gettimezoneinformation
    ///
    /// If the function succeeds, it returns one of the following values.
    /// TIME_ZONE_ID_UNKNOWN  - 0 - Daylight saving time is not used in the current time zone, because there are no transition dates or automatic adjustment for daylight saving time is disabled.
    /// TIME_ZONE_ID_STANDARD - 1 - The system is operating in the range covered by the StandardDate member of the TIME_ZONE_INFORMATION structure.
    /// TIME_ZONE_ID_DAYLIGHT - 2 - The system is operating in the range covered by the DaylightDate member of the TIME_ZONE_INFORMATION structure.
    ///
    /// If the function fails for other reasons, such as an out of memory error, it returns TIME_ZONE_ID_INVALID.
    /// To get extended error information, call GetLastError.
    pub extern "kernel32" fn GetTimeZoneInformation(lpTimeZoneInformation: *TIME_ZONE_INFORMATION) callconv(WINAPI) DWORD;
};

const DateTime = struct {
    /// days into the month, 1 to 31
    day: u5,
    /// month into the year, 1 = january, 12 = december
    month: u4,
    /// year, 2024
    year: u16,
    /// hours, 0-23
    hour: u5,
    /// minute, 0-59
    minute: u6,
    /// seconds, 0-59
    second: u6,
    /// returns in seconds the offset from UTC this date is using
    utc_offset_in_seconds: i32,
};

pub fn GetLocalDateTime() !DateTime {
    switch (builtin.os.tag) {
        .windows => {
            const utcOffset = try windowsGetLocalUTCOffset();
            var systemTime: windows.SYSTEMTIME = undefined;
            windows.GetLocalTime(&systemTime);
            return .{
                .day = @intCast(systemTime.wDay),
                .month = @intCast(systemTime.wMonth),
                .year = @intCast(systemTime.wYear),
                .hour = @intCast(systemTime.wHour),
                .minute = @intCast(systemTime.wMinute),
                .second = @intCast(systemTime.wSecond),
                .utc_offset_in_seconds = utcOffset,
            };
        },
        .linux, .macos => {
            const time: posix.time_t = @intCast(std.time.timestamp());
            // NOTE(jae): 2024-12-01
            // Zero out the memory so that if "tm_zone" is not written too, we know it's not supported
            var tmData: posix.tm = std.mem.zeroes(posix.tm);
            // According to POSIX.1-2004, localtime() is required to behave as though tzset(3) was called,
            // while localtime_r() does not have this requirement.For portable code tzset(3) should be called before localtime_r().
            // https://linux.die.net/man/3/localtime_r
            posix.tzset();
            const tm: *posix.tm = posix.localtime_r(&time, &tmData) orelse {
                return error.InvalidTime;
            };
            if (tm.tm_mday == 0) {
                // TODO(jae): Handle this edge case
                // "In many implementations, including glibc, a 0 in tm_mday is interpreted as meaning the last day of the preceding month."
                // https://linux.die.net/man/3/mktime
                return error.InvalidDay;
            }
            // NOTE(jae): 2024-12-01
            // Since tm_gmtoff and tm_zone are optional fields, check if the timezone is null
            // and if it is, fail with this call.
            if (tm.tm_zone == null) {
                return error.MissingTimezone;
            }
            // NOTE(jae): 2024-12-06
            // For Linux, tm_sec can be 60 in the case of leap seconds, so lets just ignore that
            const second: u6 = @intCast(if (tm.tm_sec == 60) 59 else tm.tm_sec);
            return .{
                .day = @intCast(tm.tm_mday),
                .month = @intCast(1 + tm.tm_mon),
                .year = @intCast(1900 + tm.tm_year),
                .hour = @intCast(tm.tm_hour),
                .minute = @intCast(tm.tm_min),
                .second = second,
                .utc_offset_in_seconds = @intCast(tm.tm_gmtoff),
            };
        },
        else => {
            // Zig 0.13.0 does not support any datetime functionality out of the box so
            // we just use UTC
            return GetUTCDateTime();
        },
    }
}

pub fn GetUTCDateTime() DateTime {
    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        // Get a calendar timestamp, in seconds, relative to UTC 1970-01-01.
        .secs = @intCast(std.time.timestamp()),
    };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return .{
        .day = @intCast(month_day.day_index + 1),
        .month = month_day.month.numeric(),
        .year = year_day.year,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
        .utc_offset_in_seconds = 0,
    };
}

/// Returns in seconds the offset from UTC for the local timezone
/// ie. 600 or 660 for Melbourne/Australia
fn windowsGetLocalUTCOffset() error{InvalidTimezone}!i32 {
    var timezoneInformation: windows.TIME_ZONE_INFORMATION = undefined;
    const r = windows.GetTimeZoneInformation(&timezoneInformation);
    // const date: windows.SYSTEMTIME = switch (r) {
    //     windows.TIME_ZONE_ID_UNKNOWN => timezoneInformation.StandardDate,
    //     windows.TIME_ZONE_ID_STANDARD => timezoneInformation.StandardDate,
    //     windows.TIME_ZONE_ID_DAYLIGHT => timezoneInformation.DaylightDate,
    //     windows.TIME_ZONE_ID_INVALID => {
    //         return error.InvalidTimezone;
    //     },
    //     else => unreachable,
    // };
    // _ = date; // autofix
    const bias: i32 = switch (r) {
        windows.TIME_ZONE_ID_UNKNOWN => timezoneInformation.Bias,
        windows.TIME_ZONE_ID_STANDARD => timezoneInformation.Bias + timezoneInformation.StandardBias,
        windows.TIME_ZONE_ID_DAYLIGHT => timezoneInformation.Bias + timezoneInformation.DaylightBias,
        windows.TIME_ZONE_ID_INVALID => {
            return error.InvalidTimezone;
        },
        else => unreachable,
    };
    // Convert from negative value and minutes ...to... positive and seconds
    return @intCast(-bias * 60);
}
