//! If, for any `n`, the bit depth of `coords[n]` exceeds `depth`, the
//! behaviour is undefined. Likewise, if the bit depth of `index` exceeds
//! `depth * 3`, the behaviour is undefined.

const std = @import("std");

const bit = @import("root.zig").bit;

pub const raster = struct {
    pub inline fn forward(comptime depth: usize, coords: [3]usize) usize {
        return 0 //
        | (coords[0] << (0 * depth)) //
        | (coords[1] << (1 * depth)) //
        | (coords[2] << (2 * depth));
    }

    pub inline fn backward(comptime depth: usize, index: usize) [3]usize {
        const mask = (@as(usize, 1) << depth) - 1;
        return .{
            (index >> (0 * depth)) & mask,
            (index >> (1 * depth)) & mask,
            (index >> (2 * depth)) & mask,
        };
    }
};

test raster {
    try std.testing.expectEqual(0x07, raster.forward(1, .{ 1, 1, 1 }));
    try std.testing.expectEqual(0x15, raster.forward(2, .{ 1, 1, 1 }));
    try std.testing.expectEqual(0x16, raster.forward(2, .{ 2, 1, 1 }));
    try std.testing.expectEqual(0x25, raster.forward(2, .{ 1, 1, 2 }));
    try std.testing.expectEqual(0x3F, raster.forward(2, .{ 3, 3, 3 }));
}

pub const morton = struct {
    pub inline fn forward(comptime depth: usize, coords: [3]usize) usize {
        const T = @Type(std.builtin.Type{ .int = .{
            .bits = @intCast(depth),
            .signedness = .unsigned,
        } });

        const pad = bit.stuff_3_zeroes_left;

        const x: usize = @intCast(pad(@as(T, @intCast(coords[0]))));
        const y: usize = @intCast(pad(@as(T, @intCast(coords[1]))));
        const z: usize = @intCast(pad(@as(T, @intCast(coords[2]))));

        return x | (y << 1) | (z << 2);
    }

    pub inline fn backward(comptime depth: usize, index: usize) [3]usize {
        _ = depth;

        const k: u64 = 0x1249_2492_4924_9249;
        const x_bits: u63 = @intCast((index >> 0) & k);
        const y_bits: u63 = @intCast((index >> 1) & k);
        const z_bits: u63 = @intCast((index >> 2) & k);

        const x: usize = @intCast(bit.unstuff_3_zeroes_left(x_bits));
        const y: usize = @intCast(bit.unstuff_3_zeroes_left(y_bits));
        const z: usize = @intCast(bit.unstuff_3_zeroes_left(z_bits));

        return .{ x, y, z };
    }
};

test morton {
    try std.testing.expectEqual(0b110101, morton.forward(2, .{ 1, 2, 3 }));
    try std.testing.expectEqual([_]usize{ 1, 2, 3 }, morton.backward(2, 0b110101));
}

pub const llm = struct {
    pub inline fn forward(comptime depth: usize, coords: [3]usize) usize {
        // z4 z3 z2 z1 z0  y4 y3 y2 y1 y0  x5 x4 x3 x2 x1 x0
        // z4 z3 z2 z1     y4 y3 y2 y1     x5 x4 x3 x2 x1    z0 y0 x0

        return 0 | //
            (coords[0] & 1) << 0 |
            (coords[1] & 1) << 1 |
            (coords[2] & 1) << 2 |
            (coords[0] >> 1) << (3 + (depth - 1) * 0) |
            (coords[1] >> 1) << (3 + (depth - 1) * 1) |
            (coords[2] >> 1) << (3 + (depth - 1) * 2);
    }

    pub inline fn backward(comptime depth: usize, index: usize) [3]usize {
        const last_three = index & 7;
        const base_raw = raster.backward(depth - 1, index >> 3);

        return .{
            (base_raw[0] << 1) | ((last_three >> 0) & 1),
            (base_raw[1] << 1) | ((last_three >> 1) & 1),
            (base_raw[2] << 1) | ((last_three >> 2) & 1),
        };
    }
};

test llm {
    // 014589CD
    // 2367ABEF
    // 014589CD
    // 2367ABEF
    // ...

    const table = [_][3]usize{
        .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 },
        .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 1 },
        .{ 2, 0, 0 }, .{ 3, 0, 0 }, .{ 2, 1, 0 }, .{ 3, 1, 0 },
        .{ 2, 0, 1 }, .{ 3, 0, 1 }, .{ 2, 1, 1 }, .{ 3, 1, 1 },
        .{ 4, 0, 0 }, .{ 5, 0, 0 }, .{ 4, 1, 0 }, .{ 5, 1, 0 },
        .{ 4, 0, 1 }, .{ 5, 0, 1 }, .{ 4, 1, 1 }, .{ 5, 1, 1 },
        .{ 6, 0, 0 }, .{ 7, 0, 0 }, .{ 6, 1, 0 }, .{ 7, 1, 0 },
        .{ 6, 0, 1 }, .{ 7, 0, 1 }, .{ 6, 1, 1 }, .{ 7, 1, 1 },

        .{ 0, 2, 0 }, .{ 1, 2, 0 }, .{ 0, 3, 0 }, .{ 1, 3, 0 },
        .{ 0, 2, 1 }, .{ 1, 2, 1 }, .{ 0, 3, 1 }, .{ 1, 3, 1 },
        .{ 2, 2, 0 }, .{ 3, 2, 0 }, .{ 2, 3, 0 }, .{ 3, 3, 0 },
        .{ 2, 2, 1 }, .{ 3, 2, 1 }, .{ 2, 3, 1 }, .{ 3, 3, 1 },
        .{ 4, 2, 0 }, .{ 5, 2, 0 }, .{ 4, 3, 0 }, .{ 5, 3, 0 },
        .{ 4, 2, 1 }, .{ 5, 2, 1 }, .{ 4, 3, 1 }, .{ 5, 3, 1 },
        .{ 6, 2, 0 }, .{ 7, 2, 0 }, .{ 6, 3, 0 }, .{ 7, 3, 0 },
        .{ 6, 2, 1 }, .{ 7, 2, 1 }, .{ 6, 3, 1 }, .{ 7, 3, 1 },
    };

    for (0.., table) |i, v| {
        try std.testing.expectEqual(i, llm.forward(3, v));
        try std.testing.expectEqual(v, llm.backward(3, i));
    }
}
