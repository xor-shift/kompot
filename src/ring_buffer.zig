const std = @import("std");

/// can be used as an atomic SPSC ring buffer.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// It's your job to make sure this doesn't dangle.
        ///
        /// It's safe to re-set this in between calls to write etc.
        storage: []T,
        read_head: std.atomic.Value(usize) = .init(0),
        write_head: std.atomic.Value(usize) = .init(0),

        pub fn init(storage: []T) Self {
            return .{
                .storage = storage,
            };
        }

        fn usedCapacityImpl(self: *const Self, maybe_read_head: ?usize, maybe_write_head: ?usize) usize {
            // these may both advance and that's ok

            const write_head = maybe_write_head orelse self.write_head.load(.acquire);
            const read_head = maybe_read_head orelse self.read_head.load(.acquire);

            return write_head - read_head;
        }

        fn remainingCapacityImpl(self: *const Self, maybe_read_head: ?usize, maybe_write_head: ?usize) usize {
            const used_capacity = self.usedCapacityImpl(maybe_read_head, maybe_write_head);

            return self.storage.len - used_capacity;
        }

        /// returns the best-effort used capacity.
        ///
        /// meant to be called by the consumer side.
        ///
        /// there might be more elements stored than the number this function
        /// returns if the RB is used in a SPSC manner.
        pub fn usedCapacity(self: *const Self) usize {
            return self.usedCapacityImpl(self.read_head.load(.unordered), null);
        }

        /// returns the best-effort free capacity.
        ///
        /// meant to be called by the producer side.
        ///
        /// there might be more elements free than the number this functon
        /// returns if the RB is used in a SPSC manner.
        pub fn remainingCapacity(self: *const Self) usize {
            return self.remainingCapacityImpl(null, self.write_head.load(.unordered));
        }

        /// from the infinite-index `head` into `self.storage`, fetches at most
        /// `no_more_than` elements.
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

        /// pretends that `offset` number of elements were written a call to this.
        ///
        /// meant to be called by the producer side.
        pub fn writableSlice(self: *Self, offset: usize) []T {
            const remaining_capacity = self.remainingCapacity();

            std.debug.assert(offset <= remaining_capacity);

            return self.getSlice(self.write_head.load(.unordered) + offset, remaining_capacity - offset);
        }

        /// pretends that `offset` number of elements were read before a call to this
        ///
        /// mreant to be called by the consumer side
        pub fn readableSlice(self: Self, offset: usize) []const T {
            const used_capacity = self.usedCapacity();

            std.debug.assert(offset <= used_capacity);

            return self.getSlice(self.read_head.load(.unordered) + offset, used_capacity - offset);
        }

        pub fn writeSome(self: *Self, in: []const T) usize {
            const slice = self.writableSlice(0);

            const num_to_write = @min(slice.len, in.len);

            @memcpy(slice[0..num_to_write], in[0..num_to_write]);

            self.write_head.store(self.write_head.load(.unordered) + num_to_write, .release);

            return num_to_write;
        }

        /// The returned value is the number of elements to `out` that were written.
        pub fn peek(self: *Self, out: []T) usize {
            return self.peekAfter(out, 0);
        }

        /// The returned value is the number of elements to `out` that were written.
        ///
        /// Pretends that `offset` number of elements were read before a call to this.
        pub fn peekAfter(self: *Self, out: []T, offset: usize) usize {
            const slice = self.readableSlice(offset);

            const num_to_read = @min(slice.len, out.len);

            @memcpy(out[0..num_to_read], slice[0..num_to_read]);

            return num_to_read;
        }

        /// The returned value is the number of elements to `out` that were written.
        pub fn read(self: *Self, out: []T) usize {
            return self.readAfter(out, 0);
        }

        /// The returned value is the number of elements to `out` that were written.
        ///
        /// Pretends that `offset` number of elements were read before a call to this.
        pub fn readAfter(self: *Self, out: []T, offset: usize) usize {
            const num_read = self.peekAfter(out, offset);
            self.read_head.store(self.read_head.load(.unordered) + num_read, .release);

            return num_read;
        }

        pub fn writeAll(self: *Self, in: []const T) void {
            std.debug.assert(in.len <= self.remainingCapacity());

            var num_written: usize = 0;
            while (num_written < in.len) {
                const num_written_curr = self.writeSome(in[num_written..]);
                std.debug.assert(num_written_curr != 0);

                num_written += num_written_curr;
            }
        }

        pub fn peekAll(self: *Self, out: []T) void {
            var num_read: usize = 0;

            while (num_read < out.len) {
                const num_read_curr = self.peekAfter(out[num_read..], num_read);
                std.debug.assert(num_read_curr != 0);

                num_read += num_read_curr;
            }
        }

        pub fn readAll(self: *Self, out: []T) void {
            self.peekAll(out);
            self.read_head.store(self.read_head.load(.unordered) + out.len, .release);
        }

        /// unsafe to use multithreaded!
        pub fn rewind(self: *Self, num_elements: usize) void {
            std.debug.assert(self.remainingCapacity() >= num_elements);
            self.read_head.store(self.read_head.load(.unordered) - num_elements, .unordered);
        }

        /// pretends that `num_elements` elements were read
        pub fn discard(self: *Self, num_elements: usize) void {
            std.debug.assert(self.usedCapacity() >= num_elements);
            self.read_head.store(self.read_head.load(.unordered) + num_elements, .release);
        }

        /// pretends that `num_elements` elements were written
        pub fn advance(self: *Self, num_elements: usize) void {
            std.debug.assert(self.remainingCapacity() >= num_elements);
            self.write_head.store(self.write_head.load(.unordered) + num_elements, .release);
        }

        pub fn indexOfScalar(self: *Self, v: T) ?usize {
            var offset: usize = 0;
            while (true) {
                const readable_slice = self.readableSlice(offset);
                if (readable_slice.len == 0) break;

                defer offset += readable_slice.len;

                const local_index = std.mem.indexOfScalar(T, readable_slice, v) orelse continue;
                return offset + local_index;
            }

            return null;
        }

        pub const Reader = struct {
            reader: std.Io.Reader,
            rb: *Self,

            fn init(self: *Self, buffer: []u8) Reader {
                return .{
                    .reader = .{
                        .buffer = buffer,
                        .seek = 0,
                        .end = 0,
                        .vtable = &std.Io.Reader.VTable{
                            .stream = &Reader.vStream,
                            .discard = &Reader.vDiscard,
                        },
                    },
                    .rb = self,
                };
            }

            /// this function is atomic: it will not consume bytes from the
            /// ring buffer if the write operation returns errors.
            fn vStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                const ctx: *Reader = @alignCast(@fieldParentPtr("reader", r));

                var written_total: usize = 0;

                while (true) {
                    const remaining_limit = limit.subtract(written_total).?;
                    if (remaining_limit == std.Io.Limit.limited(0)) break;

                    const slice = ctx.rb.readableSlice(written_total);
                    if (slice.len == 0) return std.Io.Reader.StreamError.EndOfStream;

                    const num_to_consume: usize = remaining_limit.minInt(slice.len);

                    const to_consume = slice[0..num_to_consume];
                    const written_cur = try w.write(to_consume);
                    written_total += written_cur;

                    if (written_cur == 0) break;
                }

                ctx.rb.discard(written_total);
                return written_total;
            }

            fn vDiscard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
                const ctx: *Reader = @alignCast(@fieldParentPtr("reader", r));

                const to_discard = limit.minInt(ctx.rb.usedCapacity());
                ctx.rb.discard(to_discard);

                return to_discard;
            }
        };

        pub fn reader(self: *Self, buffer: []u8) Reader {
            return Reader.init(self, buffer);
        }
    };
}

test RingBuffer {
    const alloc = std.testing.allocator;

    var allocating_writer = std.Io.Writer.Allocating.init(alloc);
    defer allocating_writer.deinit();
    const writer = &allocating_writer.writer;

    var buffer: [5]u8 = undefined;
    var ring_buffer: RingBuffer(u8) = .{
        .storage = &buffer,
    };

    var rb_reader = ring_buffer.reader(&.{});
    const reader = &rb_reader.reader;

    ring_buffer.writeAll(&.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, ring_buffer.readableSlice(0));
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, ring_buffer.readableSlice(1));
    try std.testing.expectEqualSlices(u8, &.{3}, ring_buffer.readableSlice(2));
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.readableSlice(3));

    try std.testing.expectEqual(@as(usize, 3), try reader.stream(writer, .limited(3)));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, allocating_writer.written());

    ring_buffer.writeAll(&.{ 4, 5, 6, 7, 8 });
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, ring_buffer.readableSlice(0));
    try std.testing.expectEqualSlices(u8, &.{5}, ring_buffer.readableSlice(1));
    try std.testing.expectEqualSlices(u8, &.{ 6, 7, 8 }, ring_buffer.readableSlice(2));
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, ring_buffer.readableSlice(3));
    try std.testing.expectEqualSlices(u8, &.{8}, ring_buffer.readableSlice(4));
    try std.testing.expectEqualSlices(u8, &.{}, ring_buffer.readableSlice(5));
    ring_buffer.discard(2);
    try std.testing.expectEqualSlices(u8, &.{ 6, 7, 8 }, ring_buffer.readableSlice(0));

    try std.testing.expectEqual(@as(usize, 3), try reader.stream(writer, .limited(3)));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 6, 7, 8 }, allocating_writer.written());

    try std.testing.expectError(std.Io.Reader.StreamError.EndOfStream, reader.stream(writer, .limited(1)));
}
