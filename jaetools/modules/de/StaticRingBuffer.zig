pub fn StaticRingBuffer(comptime T: type, comptime Capacity: u31) type {
    return struct {
        buffer: [Capacity]T,
        head: u31,
        tail: u31,
        len: u31,

        pub const empty: Self = .{
            .buffer = undefined,
            .head = 0,
            .tail = 0,
            .len = 0,
        };

        pub inline fn push(self: *Self, item: T) void {
            self.buffer[self.head] = item;
            self.head = (self.head + 1) % Capacity;
            if (self.len < Capacity) {
                self.len += 1;
            } else {
                // Overwrite oldest entry
                self.tail = (self.tail + 1) % Capacity;
            }
        }

        pub inline fn pop(self: *Self) ?T {
            if (self.len == 0) return null;

            const item = self.buffer[self.tail];
            self.tail = (self.tail + 1) % Capacity;
            self.len -= 1;
            return item;
        }

        pub inline fn iterator(self: *Self) Iterator {
            return .{
                .data = self,
                .index = 0,
            };
        }

        pub const Iterator = struct {
            data: *const Self,
            index: u31,

            pub inline fn next(it: *Iterator) ?T {
                const self = it.data;
                if (it.index >= self.len) return null;
                const v = self.buffer[(self.tail + it.index) % Capacity];
                it.index += 1;
                return v;
            }
        };

        const Self = @This();
    };
}
