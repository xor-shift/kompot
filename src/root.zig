pub const algorithm = @import("algorithm.zig");
pub const bit = @import("bit.zig");
pub const cobs = @import("cobs.zig");
pub const curves = @import("curves.zig");
pub const meta = @import("meta.zig");
pub const poly = @import("poly.zig");
const ring_buffer = @import("ring_buffer.zig");

// pub const coro = @import("coro/root.zig");
pub const fmt = @import("fmt/root.zig");
pub const heap = @import("heap/root.zig");
pub const sync = @import("sync/root.zig");
pub const thread = @import("thread/root.zig");
pub const wgm = @import("wgm/root.zig");

pub const RingBuffer = ring_buffer.RingBuffer;

const std = @import("std");

test {
    std.testing.log_level = .debug;

    std.testing.refAllDecls(algorithm);
    std.testing.refAllDecls(bit);
    std.testing.refAllDecls(cobs);
    std.testing.refAllDecls(curves);
    std.testing.refAllDecls(fmt);
    std.testing.refAllDecls(meta);
    std.testing.refAllDecls(poly);
    std.testing.refAllDecls(ring_buffer);
    std.testing.refAllDecls(sync);

    // std.testing.refAllDecls(coro);
    std.testing.refAllDecls(heap);
    std.testing.refAllDecls(thread);
    std.testing.refAllDecls(wgm);
}

// std.io.Writer.Discarding has references to files
pub const DiscardingWriterNoFiles = struct {
    count: usize,
    writer: std.io.Writer,

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

    pub fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
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
