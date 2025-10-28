const std = @import("std");

const wgm = @import("root.zig");

const Matrix = wgm.Matrix;

const He = wgm.Helper;

fn invert2(mat: anytype) ?[2][2]He(@TypeOf(mat)).T {
    const H = He(@TypeOf(mat));

    const a = H.get(&mat, 0, 0);
    const b = H.get(&mat, 0, 1);
    const c = H.get(&mat, 1, 0);
    const d = H.get(&mat, 1, 1);

    const D = a * d - b * c;

    if (D == 0) return null;

    return [2][2]H.T{
        .{ d / D, -b / D },
        .{ -c / D, a / D },
    };
}

fn invert3(mat: anytype) ?[3][3]He(@TypeOf(mat)).T {
    const H = He(@TypeOf(mat));

    const l = H.cfp(&mat);

    const D = wgm.determinant(mat);

    if (D == 0) return null;

    // cba with find/replace
    const m = [9]usize{
        0, 3, 6,
        1, 4, 7,
        2, 5, 8,
    };

    return [3][3]H.T{
        .{
            (l[m[4]] * l[m[8]] - l[m[5]] * l[m[7]]) / D,
            (l[m[5]] * l[m[6]] - l[m[3]] * l[m[8]]) / D,
            (l[m[3]] * l[m[7]] - l[m[4]] * l[m[6]]) / D,
        },
        .{
            (l[m[2]] * l[m[7]] - l[m[1]] * l[m[8]]) / D,
            (l[m[0]] * l[m[8]] - l[m[2]] * l[m[6]]) / D,
            (l[m[1]] * l[m[6]] - l[m[0]] * l[m[7]]) / D,
        },
        .{
            (l[m[1]] * l[m[5]] - l[m[2]] * l[m[4]]) / D,
            (l[m[2]] * l[m[3]] - l[m[0]] * l[m[5]]) / D,
            (l[m[0]] * l[m[4]] - l[m[1]] * l[m[3]]) / D,
        },
    };
}

/// straight from GLU
/// https://stackoverflow.com/a/1148405
fn invert4(mat: anytype) ?[4][4]He(@TypeOf(mat)).T {
    const H = He(@TypeOf(mat));

    var r = std.mem.zeroes([16]H.T);

    const m = H.cfp(&mat).*;
    const l = [16]usize{
        0, 4, 8,  12,
        1, 5, 9,  13,
        2, 6, 10, 14,
        3, 7, 11, 15,
    };

    r[l[0]] = m[l[5]] * m[l[10]] * m[l[15]] -
        m[l[5]] * m[l[11]] * m[l[14]] -
        m[l[9]] * m[l[6]] * m[l[15]] +
        m[l[9]] * m[l[7]] * m[l[14]] +
        m[l[13]] * m[l[6]] * m[l[11]] -
        m[l[13]] * m[l[7]] * m[l[10]];

    r[l[4]] = -m[l[4]] * m[l[10]] * m[l[15]] +
        m[l[4]] * m[l[11]] * m[l[14]] +
        m[l[8]] * m[l[6]] * m[l[15]] -
        m[l[8]] * m[l[7]] * m[l[14]] -
        m[l[12]] * m[l[6]] * m[l[11]] +
        m[l[12]] * m[l[7]] * m[l[10]];

    r[l[8]] = m[l[4]] * m[l[9]] * m[l[15]] -
        m[l[4]] * m[l[11]] * m[l[13]] -
        m[l[8]] * m[l[5]] * m[l[15]] +
        m[l[8]] * m[l[7]] * m[l[13]] +
        m[l[12]] * m[l[5]] * m[l[11]] -
        m[l[12]] * m[l[7]] * m[l[9]];

    r[l[12]] = -m[l[4]] * m[l[9]] * m[l[14]] +
        m[l[4]] * m[l[10]] * m[l[13]] +
        m[l[8]] * m[l[5]] * m[l[14]] -
        m[l[8]] * m[l[6]] * m[l[13]] -
        m[l[12]] * m[l[5]] * m[l[10]] +
        m[l[12]] * m[l[6]] * m[l[9]];

    r[l[1]] = -m[l[1]] * m[l[10]] * m[l[15]] +
        m[l[1]] * m[l[11]] * m[l[14]] +
        m[l[9]] * m[l[2]] * m[l[15]] -
        m[l[9]] * m[l[3]] * m[l[14]] -
        m[l[13]] * m[l[2]] * m[l[11]] +
        m[l[13]] * m[l[3]] * m[l[10]];

    r[l[5]] = m[l[0]] * m[l[10]] * m[l[15]] -
        m[l[0]] * m[l[11]] * m[l[14]] -
        m[l[8]] * m[l[2]] * m[l[15]] +
        m[l[8]] * m[l[3]] * m[l[14]] +
        m[l[12]] * m[l[2]] * m[l[11]] -
        m[l[12]] * m[l[3]] * m[l[10]];

    r[l[9]] = -m[l[0]] * m[l[9]] * m[l[15]] +
        m[l[0]] * m[l[11]] * m[l[13]] +
        m[l[8]] * m[l[1]] * m[l[15]] -
        m[l[8]] * m[l[3]] * m[l[13]] -
        m[l[12]] * m[l[1]] * m[l[11]] +
        m[l[12]] * m[l[3]] * m[l[9]];

    r[l[13]] = m[l[0]] * m[l[9]] * m[l[14]] -
        m[l[0]] * m[l[10]] * m[l[13]] -
        m[l[8]] * m[l[1]] * m[l[14]] +
        m[l[8]] * m[l[2]] * m[l[13]] +
        m[l[12]] * m[l[1]] * m[l[10]] -
        m[l[12]] * m[l[2]] * m[l[9]];

    r[l[2]] = m[l[1]] * m[l[6]] * m[l[15]] -
        m[l[1]] * m[l[7]] * m[l[14]] -
        m[l[5]] * m[l[2]] * m[l[15]] +
        m[l[5]] * m[l[3]] * m[l[14]] +
        m[l[13]] * m[l[2]] * m[l[7]] -
        m[l[13]] * m[l[3]] * m[l[6]];

    r[l[6]] = -m[l[0]] * m[l[6]] * m[l[15]] +
        m[l[0]] * m[l[7]] * m[l[14]] +
        m[l[4]] * m[l[2]] * m[l[15]] -
        m[l[4]] * m[l[3]] * m[l[14]] -
        m[l[12]] * m[l[2]] * m[l[7]] +
        m[l[12]] * m[l[3]] * m[l[6]];

    r[l[10]] = m[l[0]] * m[l[5]] * m[l[15]] -
        m[l[0]] * m[l[7]] * m[l[13]] -
        m[l[4]] * m[l[1]] * m[l[15]] +
        m[l[4]] * m[l[3]] * m[l[13]] +
        m[l[12]] * m[l[1]] * m[l[7]] -
        m[l[12]] * m[l[3]] * m[l[5]];

    r[l[14]] = -m[l[0]] * m[l[5]] * m[l[14]] +
        m[l[0]] * m[l[6]] * m[l[13]] +
        m[l[4]] * m[l[1]] * m[l[14]] -
        m[l[4]] * m[l[2]] * m[l[13]] -
        m[l[12]] * m[l[1]] * m[l[6]] +
        m[l[12]] * m[l[2]] * m[l[5]];

    r[l[3]] = -m[l[1]] * m[l[6]] * m[l[11]] +
        m[l[1]] * m[l[7]] * m[l[10]] +
        m[l[5]] * m[l[2]] * m[l[11]] -
        m[l[5]] * m[l[3]] * m[l[10]] -
        m[l[9]] * m[l[2]] * m[l[7]] +
        m[l[9]] * m[l[3]] * m[l[6]];

    r[l[7]] = m[l[0]] * m[l[6]] * m[l[11]] -
        m[l[0]] * m[l[7]] * m[l[10]] -
        m[l[4]] * m[l[2]] * m[l[11]] +
        m[l[4]] * m[l[3]] * m[l[10]] +
        m[l[8]] * m[l[2]] * m[l[7]] -
        m[l[8]] * m[l[3]] * m[l[6]];

    r[l[11]] = -m[l[0]] * m[l[5]] * m[l[11]] +
        m[l[0]] * m[l[7]] * m[l[9]] +
        m[l[4]] * m[l[1]] * m[l[11]] -
        m[l[4]] * m[l[3]] * m[l[9]] -
        m[l[8]] * m[l[1]] * m[l[7]] +
        m[l[8]] * m[l[3]] * m[l[5]];

    r[l[15]] = m[l[0]] * m[l[5]] * m[l[10]] -
        m[l[0]] * m[l[6]] * m[l[9]] -
        m[l[4]] * m[l[1]] * m[l[10]] +
        m[l[4]] * m[l[2]] * m[l[9]] +
        m[l[8]] * m[l[1]] * m[l[6]] -
        m[l[8]] * m[l[2]] * m[l[5]];

    const D = m[l[0]] * r[l[0]] + m[l[1]] * r[l[4]] + m[l[2]] * r[l[8]] + m[l[3]] * r[l[12]];

    if (D == 0) return null;

    const ret: *const [4][4]H.T = @ptrCast(&r);
    return wgm.div(ret.*, D);
}

pub fn inverse(mat: anytype) ?Matrix(He(@TypeOf(mat)).T, He(@TypeOf(mat)).rows, He(@TypeOf(mat)).cols) {
    const Mat = @TypeOf(mat);
    const H = He(Mat);

    if (H.rows != H.cols) {
        @compileError("only square matrices are invertible");
    }

    const sl = H.rows;

    // handle cases where there are analytical solutions
    switch (sl) {
        0 => @compileError("why are you trying to invert a 0x0 matrix?"),
        1 => {
            const v = H.get(&mat, 0, 0);
            if (v == 0) return null;

            return 1 / v;
        },
        2 => return invert2(mat),
        3 => return invert3(mat),
        4 => return invert4(mat),
        else => {},
    }

    @compileError("inversion of matrices larger than 4x4 is not yet supported");
}

test inverse {
    try std.testing.expectEqual(1, inverse(@as(f64, 1)));
    try std.testing.expectEqual(0.5, inverse([1][1]f64{.{2}}));

    try std.testing.expectEqual(
        [2][2]f64{
            .{ -7, 3 },
            .{ 5, -2 },
        },
        inverse([2][2]f64{
            .{ 2, 5 },
            .{ 3, 7 },
        }),
    );

    try std.testing.expectEqual(
        [3][3]f64{
            .{ -1, -1, 1 },
            .{ -4, 13, -6.5 },
            .{ 1, -3, 1.5 },
        },
        inverse([3][3]f64{
            .{ 0, 3, 13 },
            .{ 1, 5, 21 },
            .{ 2, 8, 34 },
        }),
    );
}

// /// https://stackoverflow.com/a/2625420
// pub fn affine_inverse(mat: anytype) ?@TypeOf(mat) {
//     const m = Matrix(T, 3, 3){ .el = .{
//         mat.get(0, 0), mat.get(0, 1), mat.get(0, 2),
//         mat.get(1, 0), mat.get(1, 1), mat.get(1, 2),
//         mat.get(2, 0), mat.get(2, 1), mat.get(2, 2),
//     } };
//
//     const inv_m = inverse(m) orelse return null;
//
//     const b = Vector(T, 3){ .el = .{
//         mat.get(0, 3),
//         mat.get(1, 3),
//         mat.get(2, 3),
//     } };
//
//     const ninv_m_b = wgm.mulmm(wgm.negate(inv_m), b);
//
//     return Matrix(T, 4, 4){ .el = .{
//         inv_m.get(0, 0), inv_m.get(0, 1), inv_m.get(0, 2), ninv_m_b.get(0, 0),
//         inv_m.get(1, 0), inv_m.get(1, 1), inv_m.get(1, 2), ninv_m_b.get(1, 0),
//         inv_m.get(2, 0), inv_m.get(2, 1), inv_m.get(2, 2), ninv_m_b.get(2, 0),
//         0,               0,               0,               1,
//     } };
// }
//
// test affine_inverse {
//     try std.testing.expectEqual(
//         Matrix(f64, 4, 4){ .el = .{
//             -2.0,        1.5,          -0.5,  1.0,
//             25.0 / 14.0, -53.0 / 28.0, 0.75,  -0.5,
//             -1.0 / 14.0, 15.0 / 28.0,  -0.25, -1.5,
//             0,           0,            0,     1,
//         } },
//         affine_inverse(f64, Matrix(f64, 4, 4){ .el = .{
//             2,  3,  5,  7,
//             11, 13, 17, 21,
//             23, 27, 31, 37,
//             0,  0,  0,  1,
//         } }),
//     );
// }
