const std = @import("std");

pub fn AtomicSPSCRingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T = undefined,
        read_head: usize align(std.atomic.cache_line) = 0,
        write_head: usize align(std.atomic.cache_line) = 0,
        is_stalled: bool align(std.atomic.cache_line) = false,

        fn appendSomeDontUpdateWriteHead(self: *Self, range: []const T, write_head_offset: usize) usize {
            // the write head is only updated by us, no atomic load
            const write_head = self.write_head + write_head_offset;
            const read_head = @atomicLoad(usize, &self.read_head, .acquire);

            const num_occupied_elems = write_head - read_head;
            const num_free_elems = self.buffer.len - num_occupied_elems;

            const adjusted_write_head = write_head % self.buffer.len;
            // const adjusted_read_head = read_head % self.buffer.len;

            // 3
            // 0 1 2 3 4 5
            // 0 1 2 0 1 2
            // 3 2 1 3 2 1
            // ^ im dumb i have to take notes like this please understand
            const num_elems_to_end = self.buffer.len - adjusted_write_head;
            const num_elems_to_write = @min(num_elems_to_end, num_free_elems);

            const slice_to_end = self.buffer[adjusted_write_head..];
            const slice_to_copy_to = slice_to_end[0..num_elems_to_write];

            @memcpy(slice_to_copy_to, range[0..num_elems_to_write]);
        }

        fn appendAsMuchAsPossibleDontUpdateWriteHead(self: *Self, range: []const T) usize {
            var written: usize = 0;
            while (true) {
                const remaining = range[written..];

                const written_now = self.appendSomeDontUpdateWriteHead(remaining, written);
                written += written_now;

                if (written_now == 0) break;
            }

            return written;
        }

        pub const AppendRes = struct {
            remaining: usize,
            stalled: bool,
        };

        pub fn append(self: *Self, range: []const u8) AppendRes {
            const written = self.appendAsMuchAsPossibleDontUpdateWriteHead(range);
            std.debug.assert(written <= range.len);

            const write_head = self.write_head;
            const read_head = @atomicLoad(usize, &self.write_head, .acquire);

            const num_occupied_elems = write_head - read_head;
            std.debug.assert(num_occupied_elems <= range.len);

            @atomicStore(usize, &self.write_head, write_head + written, .release);

            return .{
                .remaining = range.len - written,
                .stalled = num_occupied_elems == 0,
            };
        }
    };
}
