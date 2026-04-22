const ring_buffer = @import("ring_buffer.zig");

pub const algorithm = @import("algorithm.zig");
pub const bit = @import("bit.zig");
pub const cobs = @import("cobs.zig");
pub const curves = @import("curves.zig");
pub const meta = @import("meta.zig");
pub const poly = @import("poly.zig");

pub const heap = @import("heap/root.zig");
pub const log = @import("log/root.zig");
pub const net = @import("net/root.zig");
pub const rand = @import("rand/root.zig");
pub const sync = @import("sync/root.zig");
pub const wgm = @import("wgm/root.zig");

pub const HyperGraph = @import("HyperGraph.zig");
pub const HyperGraphScheduler = @import("HyperGraphScheduler.zig");

pub const RingBuffer = ring_buffer.RingBuffer;

const std = @import("std");

test {
    std.testing.log_level = .debug;

    std.testing.refAllDecls(algorithm);
    std.testing.refAllDecls(bit);
    std.testing.refAllDecls(cobs);
    std.testing.refAllDecls(curves);
    std.testing.refAllDecls(meta);
    std.testing.refAllDecls(poly);
    std.testing.refAllDecls(ring_buffer);

    std.testing.refAllDecls(heap);
    std.testing.refAllDecls(log);
    std.testing.refAllDecls(net);
    std.testing.refAllDecls(rand);
    std.testing.refAllDecls(sync);
    std.testing.refAllDecls(wgm);

    std.testing.refAllDecls(HyperGraph);
    std.testing.refAllDecls(HyperGraphScheduler);
}

// std.Io.Writer.Discarding has references to files
pub const DiscardingWriterNoFiles = struct {
    count: usize,
    writer: std.Io.Writer,

    pub fn init(buffer: []u8) DiscardingWriterNoFiles {
        return .{
            .count = 0,
            .writer = .{
                .vtable = &.{
                    .drain = DiscardingWriterNoFiles.drain,
                },
                .buffer = buffer,
            },
        };
    }

    pub fn fullCount(d: *const DiscardingWriterNoFiles) usize {
        return d.count + d.writer.end;
    }

    pub fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const d: *DiscardingWriterNoFiles = @alignCast(@fieldParentPtr("writer", w));

        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];

        var written: usize = pattern.len * splat;
        for (slice) |bytes| written += bytes.len;

        d.count += w.end + written;
        w.end = 0;

        return written;
    }
};

/// Splits a doubly linked list s.t. `split_at` is the last element of the
/// first returned list.
pub fn splitDoublyLinkedList(
    list: std.DoublyLinkedList,
    split_at: *std.DoublyLinkedList.Node,
) [2]std.DoublyLinkedList {
    // edge cases:
    // split_at == list.first:
    //  - split_at.prev will be null
    //  - split_at.next will be set to null
    //  this is fine
    //
    // split_at == list.last:
    //   doesn't concern lhs
    const lhs: std.DoublyLinkedList = .{
        .first = list.first,
        .last = split_at,
    };

    // split_at == list.first:
    //  since split_at.next is set to null, rhs.first will be null
    //
    // split_at == list.last:
    //   split_at will be a member of lhs so this is an issue

    const rhs: std.DoublyLinkedList = if (split_at == list.last)
        .{}
    else blk: {
        split_at.next.?.prev = null;
        break :blk .{
            .first = split_at.next,
            .last = list.last,
        };
    };

    split_at.next = null;

    return .{ lhs, rhs };
}

pub const UnalignedDoublyLinkedList = struct {
    pub const Node = struct {
        prev: ?*align(1) Node = null,
        next: ?*align(1) Node = null,
    };

    const Self = @This();

    // invariant: (first == null) == (last == null)
    // it is inconvenient to represent this with an enum

    first: ?*align(1) Node = null,
    last: ?*align(1) Node = null,

    pub fn appendAfter(self: *Self, after: *align(1) Node, node: *align(1) Node) void {
        std.debug.assert(self.first != null);
        std.debug.assert(self.last != null);

        // A <-> B
        // into
        // A <-> N <-> B
        const a = after;

        if (a.next) |b| {
            a.next = node;
            b.prev = node;

            node.* = .{
                .prev = a,
                .next = b,
            };

            return;
        }

        std.debug.assert(self.last.? == a);

        a.next = node;
        self.last = node;

        node.* = .{
            .prev = a,
            .next = null,
        };
    }

    pub fn append(self: *Self, node: *align(1) Node) void {
        node.* = .{};

        if (self.last) |last| {
            return self.appendAfter(last, node);
        }

        std.debug.assert(self.first == null);

        self.first = node;
        self.last = node;
    }

    pub fn remove(self: *Self, node: *align(1) Node) void {
        if (node.prev) |a| {
            a.next = node.next;
        } else {
            self.first = node.next;
        }

        if (node.next) |b| {
            b.prev = node.prev;
        } else {
            self.last = node.prev;
        }

        std.debug.assert((self.first == null) == (self.last == null));
    }

    pub fn isEmpty(self: *Self) bool {
        std.debug.assert((self.first == null) == (self.last == null));
        return self.first == null;
    }
};

pub const deleter = struct {
    pub fn Pointer(comptime T: type) type {
        return struct {
            const Self = @This();

            const ValueType = *T;

            alloc: std.mem.Allocator,

            pub fn init(alloc: std.mem.Allocator) Self {
                return .{
                    .alloc = alloc,
                };
            }

            pub fn delete(self: Self, ptr: *ValueType) void {
                self.alloc.destroy(ptr.*);
            }
        };
    }

    pub fn Slice(comptime T: type) type {
        return struct {
            const Self = @This();

            const ValueType = []T;

            alloc: std.mem.Allocator,

            pub fn init(alloc: std.mem.Allocator) Self {
                return .{
                    .alloc = alloc,
                };
            }

            // ptr must be `*[]const T` or `*[] T`
            pub fn delete(self: Self, ptr: anytype) void {
                self.alloc.free(ptr.*);
            }
        };
    }

    pub fn Trivial(comptime T: type) type {
        return struct {
            const Self = @This();

            const ValueType = T;

            alloc: std.mem.Allocator,

            pub fn init(alloc: std.mem.Allocator) Self {
                return .{
                    .alloc = alloc,
                };
            }

            pub fn delete(self: Self, ptr: *ValueType) void {
                _ = self;
                _ = ptr;
            }
        };
    }
};

pub const EscapedString = struct {
    inner: []const u8,

    pub fn format(self: EscapedString, writer: *std.Io.Writer) !void {
        const printable_start = 32;
        const printable_end = 126;

        const escapes = [_]struct { u8, u8 }{
            .{ '\n', 'n' },
            .{ '\r', 'r' },
            .{ '\t', 't' },
            .{ '\\', '\\' },
        };

        // TODO: SIMD
        outer: for (self.inner) |c| {
            if (c >= printable_start and c <= printable_end) {
                try writer.writeByte(c);
                continue;
            }

            for (escapes) |escape_pair| {
                if (c != escape_pair.@"0") continue;

                try writer.writeByte('\\');
                try writer.writeByte(escape_pair.@"1");

                continue :outer;
            }

            try writer.writeAll("\\x");

            const hex_lookup: [16]u8 = .{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F' };
            const nibble_0: u4 = @intCast((c >> 4) & 0xF);
            const nibble_1: u4 = @intCast((c >> 0) & 0xF);

            const nibble_0_char = hex_lookup[@intCast(nibble_0)];
            const nibble_1_char = hex_lookup[@intCast(nibble_1)];

            try writer.writeAll(&.{ nibble_0_char, nibble_1_char });
        }
    }
};
