const std = @import("std");

pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// It's your job to make sure this doesn't dangle.
        ///
        /// It's safe to re-set this in between calls to write etc.
        storage: []T,
        read_head: usize = 0,
        write_head: usize = 0,

        pub fn usedCapacity(self: Self) usize {
            return self.write_head - self.read_head;
        }

        pub fn remainingCapacity(self: Self) usize {
            return self.storage.len - self.usedCapacity();
        }

        fn getSlice(
            self: Self,
            head: usize,
            no_more_than: usize,
        ) []T {
            const rela_h = head % self.storage.len;
            const elements_to_end = self.storage.len - rela_h;
            const num_elems = @min(elements_to_end, no_more_than);

            return self.storage[rela_h .. rela_h + num_elems];
        }

        pub fn writableSlice(self: *Self) []T {
            return self.getSlice(self.write_head, self.remainingCapacity());
        }

        pub fn writableSliceAfter(self: *Self, after: usize) []T {
            std.debug.assert(self.usedCapacity() + after < self.storage.len);
            return self.getSlice(self.write_head + after, self.remainingCapacity());
        }

        pub fn readableSlice(self: Self) []const T {
            return self.getSlice(self.read_head, self.usedCapacity());
        }

        pub fn write(self: *Self, in: []const T) usize {
            const slice = self.writableSlice();

            const num_to_write = @min(slice.len, in.len);

            @memcpy(slice[0..num_to_write], in[0..num_to_write]);
            self.write_head += num_to_write;

            return num_to_write;
        }

        pub fn read(self: *Self, out: []T) usize {
            const slice = self.readableSlice();

            const num_to_read = @min(slice.len, out.len);

            @memcpy(out[0..num_to_read], slice[0..num_to_read]);
            self.read_head += num_to_read;

            return num_to_read;
        }

        pub fn writeAll(self: *Self, in: []const T) void {
            var num_written: usize = 0;
            while (num_written < in.len) {
                const num_written_curr = self.write(in[num_written..]);
                std.debug.assert(num_written_curr != 0);

                num_written += num_written_curr;
            }
        }

        pub fn readAll(self: *Self, out: []T) void {
            var num_read: usize = 0;
            while (num_read < out.len) {
                const num_read_curr = self.read(out[num_read..]);
                std.debug.assert(num_read_curr != 0);

                num_read += num_read_curr;
            }
        }

        pub fn discard(self: *Self, num_elements: usize) void {
            std.debug.assert(self.usedCapacity() >= num_elements);
            self.read_head += num_elements;
        }

        pub fn advance(self: *Self, num_elements: usize) void {
            std.debug.assert(self.remainingCapacity() >= num_elements);
            self.write_head += num_elements;
        }
    };
}

test RingBuffer {
    var buffer: [5]u8 = undefined;
    var ring_buffer: RingBuffer(u8) = .{
        .storage = &buffer,
    };

    ring_buffer.writeAll(&.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, ring_buffer.readableSlice());
    ring_buffer.discard(3);

    ring_buffer.writeAll(&.{ 4, 5, 6, 7, 8 });
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, ring_buffer.readableSlice());
    ring_buffer.discard(2);
    try std.testing.expectEqualSlices(u8, &.{ 6, 7, 8 }, ring_buffer.readableSlice());
}
