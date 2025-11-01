pub const algorithm = @import("algorithm.zig");
pub const bit = @import("bit.zig");
pub const cobs = @import("cobs.zig");
pub const curves = @import("curves.zig");
pub const fmt = @import("fmt.zig");
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
