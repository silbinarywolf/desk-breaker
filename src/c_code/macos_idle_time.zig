const assert = @import("std").debug.assert;

pub fn getSystemIdleTimeInNanoseconds() i64 {
    var iter: zig_io_iterator_t(io_registry_entry_t) = .empty;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOHIDSystem"), iter.toCPointer()) != .success) {
        return -1;
    }
    defer iter.release();

    const entry = iter.next();
    if (entry == .null) {
        return -1;
    }
    defer entry.release();

    var dict: *Dictionary(CFStringRef, CFNumberRef) = undefined;
    if (IORegistryEntryCreateCFProperties(entry, @ptrCast(&dict), .default, .none) != .success) {
        return -1;
    }
    defer dict.release();

    const obj = dict.getValue(__CFStringMakeConstantString("HIDIdleTime")) orelse {
        return -1;
    };
    defer obj.release();

    var nanoseconds: i64 = 0;
    if (CFNumberGetValue(obj, .int64, @ptrCast(@alignCast(&nanoseconds))) == .False) {
        return -1;
    }
    // Convert to seconds
    // const idlesecs = nanoseconds >> @intCast(@as(i64, 30));
    return nanoseconds;
}

// Mac OS types / functions

fn zig_io_iterator_t(comptime ReturnValue: type) type {
    return enum(c_uint) {
        empty = 0,
        _,

        pub inline fn next(iterator: @This()) ReturnValue {
            return .fromC(IOIteratorNext(iterator.toC()));
        }

        pub inline fn release(iterator: @This()) void {
            return io_object_t.release(@enumFromInt(@intFromEnum(iterator)));
        }

        pub inline fn toC(iterator: @This()) io_iterator_t {
            return @enumFromInt(@intFromEnum(iterator));
        }

        pub inline fn toCPointer(iterator: *@This()) *io_iterator_t {
            return @ptrCast(iterator);
        }
    };
}

/// For sub-types of io_object_t
fn zig_io_object_t() type {
    return enum(c_uint) {
        null = 0,
        _,

        pub inline fn release(object: Self) void {
            return object.toC().release();
        }

        pub inline fn fromC(object: io_object_t) Self {
            return @enumFromInt(@intFromEnum(object));
        }

        pub inline fn toC(object: Self) io_object_t {
            return @enumFromInt(@intFromEnum(object));
        }

        const Self = @This();
    };
}

fn Dictionary(comptime K: type, comptime V: type) type {
    return opaque {
        pub inline fn release(object: *const Self) void {
            return __CFDictionary.release(@ptrCast(object));
        }

        pub inline fn getValue(theDict: *const Self, key: K) V {
            return @ptrCast(CFDictionaryGetValue(@ptrCast(theDict), @ptrCast(key)));
        }

        const Self = @This();
    };
}

const __CFDictionary = opaque {
    pub inline fn release(theDict: *const @This()) void {
        return CFRelease(@ptrCast(theDict));
    }

    pub inline fn getValue(theDict: *const @This(), key: ?*const opaque {}) ?*const opaque {} {
        return @ptrCast(CFDictionaryGetValue(@ptrCast(theDict), @ptrCast(key)));
    }
};
const CFMutableDictionaryRef = ?*__CFDictionary;
const CFDictionaryRef = ?*const __CFDictionary;
const kern_return_t = enum(c_int) {
    success = 0,
    _,
};
const mach_port_t = enum(c_uint) {
    _,

    // pub const master_port_default = kIOMasterPortDefault;
};
const io_iterator_t = enum(c_uint) {
    empty = 0,
    _,

    pub inline fn next(iterator: @This()) io_object_t {
        return IOIteratorNext(iterator);
    }
};
const io_object_t = enum(c_uint) {
    null = 0,
    _,

    pub inline fn release(object: io_object_t) void {
        const v = IOObjectRelease(object);
        assert(v == .success);
    }
};
const io_registry_entry_t = zig_io_object_t();
const IOOptionBits = packed struct(u32) {
    _: u32,

    pub const none: IOOptionBits = .{
        ._ = 0,
    };
};
const __CFAllocator = opaque {
    /// Alias of 'kCFAllocatorDefault'
    pub const default: CFAllocatorRef = null;

    /// This is a synonym for NULL, if you'd rather use a named constant.
    pub extern const kCFAllocatorDefault: CFAllocatorRef;
};
const CFAllocatorRef = ?*const __CFAllocator;
const __CFString = opaque {};
const CFStringRef = ?*const __CFString;
const CFMutableStringRef = ?*__CFString;
const CFNumberRef = ?*const opaque {
    pub inline fn release(number: *const @This()) void {
        return CFRelease(@ptrCast(number));
    }
};
const CFTypeRef = ?*const anyopaque;
const CFNumberType = enum(c_long) {
    int8 = 1,
    int16 = 2,
    int32 = 3,
    int64 = 4,
    _,
    // const kCFNumberSInt8Type: c_int = 1;
    // const kCFNumberSInt16Type: c_int = 2;
    // const kCFNumberSInt32Type: c_int = 3;
    // const kCFNumberSInt64Type: c_int = 4;
};
const Boolean = enum(u8) { False = 0, _ };

extern const kIOMasterPortDefault: mach_port_t;

extern fn CFDictionaryGetValue(theDict: CFDictionaryRef, key: ?*const anyopaque) ?*const anyopaque;

extern fn __CFStringMakeConstantString(cStr: [*c]const u8) CFStringRef;
extern fn IOIteratorNext(iterator: io_iterator_t) io_object_t;
extern fn IOServiceMatching(name: [*c]const u8) CFMutableDictionaryRef;
extern fn IOServiceGetMatchingServices(mainPort: mach_port_t, matching: CFDictionaryRef, existing: [*c]io_iterator_t) kern_return_t;
extern fn IORegistryEntryCreateCFProperties(entry: io_registry_entry_t, properties: *?*anyopaque, allocator: CFAllocatorRef, options: IOOptionBits) kern_return_t;
extern fn CFNumberGetValue(number: CFNumberRef, theType: CFNumberType, valuePtr: ?*anyopaque) Boolean;
extern fn CFRelease(cf: CFTypeRef) void;
extern fn IOObjectRelease(object: io_object_t) kern_return_t;
