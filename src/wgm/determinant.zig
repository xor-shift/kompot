const std = @import("std");

const wgm = @import("root.zig");

const He = wgm.Helper;

pub fn determinant(mat: anytype) He(@TypeOf(mat)).T {
    const Mat = @TypeOf(mat);
    const H = He(Mat);

    std.debug.assert(H.rows == H.cols);

    return switch (H.rows) {
        1 => H.get(&mat, 0, 0),
        2 => H.get(&mat, 0, 0) * H.get(&mat, 1, 1) - H.get(&mat, 0, 1) * H.get(&mat, 1, 0),
        3 => val: {
            // zig fmt: off
            const a = H.get(&mat, 0, 0); const b = H.get(&mat, 0, 1); const c = H.get(&mat, 0, 2);
            const d = H.get(&mat, 1, 0); const e = H.get(&mat, 1, 1); const f = H.get(&mat, 1, 2);
            const g = H.get(&mat, 2, 0); const h = H.get(&mat, 2, 1); const i = H.get(&mat, 2, 2);
            // zig fmt: on

            break :val a * e * i + b * f * g + c * d * h - c * e * g - b * d * i - a * f * h;
        },

        else => @compileError("NYI"),
    };
}

test determinant {
    const det = determinant;

    try std.testing.expectEqual(-2, det([2][2]isize{ .{ 1, 3 }, .{ 2, 4 } }));

    try std.testing.expectEqual(0, det([3][3]isize{
        .{ 1, 4, 7 },
        .{ 2, 5, 8 },
        .{ 3, 6, 9 },
    }));

    try std.testing.expectEqual(-2, det([3][3]isize{
        .{ 1, 3, 13 },
        .{ 1, 5, 21 },
        .{ 2, 8, 33 },
    }));
}
