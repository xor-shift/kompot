pub const algorithm = @import("algorithm.zig");
pub const bit = @import("bit.zig");
pub const cobs = @import("cobs.zig");
pub const curves = @import("curves.zig");
pub const fmt = @import("fmt/root.zig");
pub const ring_buffer = @import("ring_buffer.zig");

pub const coro = @import("coro/root.zig");
pub const dyn = @import("dynnew/root.zig");
pub const heap = @import("heap/root.zig");
pub const thread = @import("thread/root.zig");
pub const wgm = @import("wgm/root.zig");

const std = @import("std");

test {
    std.testing.log_level = .debug;

    std.testing.refAllDecls(algorithm);
    std.testing.refAllDecls(bit);
    std.testing.refAllDecls(cobs);
    std.testing.refAllDecls(curves);
    std.testing.refAllDecls(fmt);
    std.testing.refAllDecls(ring_buffer);

    // std.testing.refAllDecls(coro);
    std.testing.refAllDecls(dyn);
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
