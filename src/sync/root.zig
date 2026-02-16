const std = @import("std");

const tearing_atomic_uint = @import("tearing_atomic_uint.zig");

pub const TearingAtomicUint = tearing_atomic_uint.TearingAtomicUint;

test {
    std.testing.refAllDecls(tearing_atomic_uint);
}

pub const AppendOnlyAtomicSinglyLinkedList = struct {
    const Self = @This();

    pub const Node = struct {
        next: ?*Node = null,

        // if `null` is returned, the next node has been succesfully set,
        // otherwise, the actual `next` node is returned
        inline fn trySetNext(self: *Node, next: *Node) ??*Node {
            return @cmpxchgWeak(?*Node, &self.next, null, next, .acq_rel, .acquire);
        }
    };

    first: ?*Node = null,

    pub fn getLastFrom(self: *Self, maybe_last_known: ?*Node) ?*Node {
        const last_known = maybe_last_known orelse {
            const maybe_first = @atomicLoad(?*Node, &self.first, .acquire);
            if (maybe_first) |first| {
                return self.getLastFrom(first);
            }

            return null;
        };

        const maybe_next = @atomicLoad(?*Node, &last_known.next, .acquire);
        if (maybe_next) |next| {
            return self.getLastFrom(next);
        }

        return last_known;
    }

    inline fn trySetFirst(self: *Self, first: *Node) ??*Node {
        return @cmpxchgWeak(?*Node, &self.first, null, first, .acq_rel, .acquire);
    }

    pub fn append(self: *Self, node: *Node) void {
        var maybe_last_known: ?*Node = null;
        while (true) {
            maybe_last_known = self.getLastFrom(maybe_last_known);

            const last_known = maybe_last_known orelse {
                const maybe_new_first = self.trySetFirst(node);
                if (maybe_new_first) |new_first| {
                    maybe_last_known = new_first;
                    continue;
                }

                return;
            };

            const maybe_next = last_known.trySetNext(node);
            if (maybe_next) |next| {
                maybe_last_known = next;
                continue;
            }

            break;
        }
    }

    pub const Iterator = struct {
        curr: ?*Node,

        pub fn next(self: *Iterator) ?*Node {
            const curr = self.curr orelse {
                return null;
            };

            const maybe_next = @atomicLoad(?*Node, &curr.next, .acquire);
            self.curr = maybe_next;

            return curr;
        }
    };

    pub fn iterateFrom(self: *const Self, from: ?*Node) Iterator {
        _ = self;

        return .{
            .curr = from,
        };
    }

    pub fn iterate(self: *const Self) Iterator {
        return self.iterateFrom(@atomicLoad(?*Node, &self.first, .acquire));
    }
};

test AppendOnlyAtomicSinglyLinkedList {
    const List = AppendOnlyAtomicSinglyLinkedList;

    const TestNode = struct {
        list_node: List.Node = .{},
        value: usize,
    };

    var list: List = .{};

    const getValues = struct {
        fn aufruf(list_: *List) ![]usize {
            var arraylist: std.ArrayListUnmanaged(usize) = .{};

            var iterator = list_.iterate();
            while (iterator.next()) |list_node| {
                const node: *TestNode = @fieldParentPtr("list_node", list_node);
                try arraylist.append(std.testing.allocator, node.value);
            }

            return try arraylist.toOwnedSlice(std.testing.allocator);
        }
    }.aufruf;

    const values_0 = try getValues(&list);
    defer std.testing.allocator.free(values_0);
    try std.testing.expectEqualSlices(usize, &.{}, values_0);

    var nodes = [_]TestNode{
        .{ .value = 1 },
        .{ .value = 1 },
        .{ .value = 2 },
        .{ .value = 3 },
        .{ .value = 5 },
    };

    list.append(&nodes[0].list_node);

    const values_1 = try getValues(&list);
    defer std.testing.allocator.free(values_1);
    try std.testing.expectEqualSlices(usize, &.{1}, values_1);

    list.append(&nodes[1].list_node);
    list.append(&nodes[2].list_node);
    list.append(&nodes[3].list_node);
    list.append(&nodes[4].list_node);

    const values_2 = try getValues(&list);
    defer std.testing.allocator.free(values_2);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 2, 3, 5 }, values_2);
}

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

// test AtomicSPSCRingBuffer {
//     const RingBuffer = AtomicSPSCRingBuffer(usize);
// 
//     var backing_buffer: [5]usize = undefined;
//     var buffer: RingBuffer = .{ .buffer = &backing_buffer };
// 
//     std.testing.expectEqual(RingBuffer.AppendRes{ .remaining = 0, .stalled = true }, buffer.append(&.{ 1, 2, 3 }));
//     std.testing.expectEqual(RingBuffer.AppendRes{ .remaining = 1, .stalled = true }, buffer.append(&.{ 1, 2, 3 }));
// 
//     //
// }
