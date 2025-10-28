const std = @import("std");

const wgm = @import("root.zig");

const Matrix = wgm.Matrix;
const Vector = wgm.Vector;

const He = wgm.Helper;

fn SquareMat(comptime T: type, comptime dims: usize) type {
    return Matrix(T, dims, dims);
}

const transpose = wgm.transpose;

pub fn identity(comptime T: type, comptime dims: usize) SquareMat(T, dims) {
    const Ret = SquareMat(T, dims);
    const H = He(Ret);

    var ret: Ret = undefined;
    @memset(H.fp(&ret), 0);
    for (0..dims) |i| H.set(&ret, i, i, 1);

    return ret;
}

pub fn fromHomogenous(vec: anytype) Vector(He(@TypeOf(vec)).T, He(@TypeOf(vec)).rows - 1) {
    const H = He(@TypeOf(vec));
    const Ret = Vector(H.T, H.rows - 1);
    const HR = He(Ret);

    var ret: Ret = undefined;
    @memcpy(HR.fp(&ret), H.cfp(&vec)[0 .. H.rows - 1]);

    return wgm.div(ret, H.get(&vec, H.rows - 1, 0));
}

test fromHomogenous {
    try std.testing.expectEqual([3]usize{ 1, 2, 3 }, fromHomogenous([4]usize{ 2, 4, 6, 2 }));
}

pub fn padAffine(mat: anytype) Matrix(He(@TypeOf(mat)).T, He(@TypeOf(mat)).rows + 1, He(@TypeOf(mat)).cols + 1) {
    const H = He(@TypeOf(mat));
    const Ret = Matrix(H.T, H.rows + 1, H.cols + 1);
    const RH = He(Ret);

    var ret = std.mem.zeroes(Ret);
    for (0..H.cols) |c| @memcpy(RH.p(&ret)[c][0 .. RH.rows - 1], &H.cp(&mat)[c]);
    RH.set(&ret, H.rows, H.cols, 1);

    return ret;
}

pub fn rotation2D(comptime T: type, theta: T) Matrix(T, 2, 2) {
    const sint = @sin(theta);
    const cost = @cos(theta);

    return transpose([2][2]T{
        cost, -sint,
        sint, cost,
    });
}

/// r = pi / 2 rotates [0 1 0] to [0 0 1]
pub fn rotateYZ(comptime T: type, r: T) [3][3]T {
    return transpose([3][3]T{
        .{ 1, 0, 0 },
        .{ 0, @cos(r), -@sin(r) },
        .{ 0, @sin(r), @cos(r) },
    });
}

test rotateYZ {
    try std.testing.expectEqual(
        [3]f64{ 0, 6.123233995736766e-17, 1 },
        wgm.mulmm(rotateYZ(f64, std.math.pi / 2.0), [3]f64{ 0, 1, 0 }),
    );
}

/// r = pi / 2 rotates [0 0 1] to [1 0 0]
pub fn rotateZX(comptime T: type, r: T) [3][3]T {
    return transpose([3][3]T{
        .{ @cos(r), 0, @sin(r) },
        .{ 0, 1, 0 },
        .{ -@sin(r), 0, @cos(r) },
    });
}

test rotateZX {
    try std.testing.expectEqual(
        [3]f64{ 1, 0, 6.123233995736766e-17 },
        wgm.mulmm(rotateZX(f64, std.math.pi / 2.0), [3]f64{ 0, 0, 1 }),
    );
}

/// r = pi / 2 rotates [1 0 0] to [0 1 0]
pub fn rotateXY(comptime T: type, r: T) [3][3]T {
    return transpose([3][3]T{
        .{ @cos(r), -@sin(r), 0 },
        .{ @sin(r), @cos(r), 0 },
        .{ 0, 0, 1 },
    });
}

test rotateXY {
    try std.testing.expectEqual(
        [3]f64{ 6.123233995736766e-17, 1, 0 },
        wgm.mulmm(rotateXY(f64, std.math.pi / 2.0), [3]f64{ 1, 0, 0 }),
    );
}

pub fn translate3D(vec: anytype) SquareMat(He(@TypeOf(vec)).T, He(@TypeOf(vec)).rows + 1) {
    const H = He(@TypeOf(vec));
    const Ret = SquareMat(H.T, H.rows + 1);
    const HR = He(Ret);

    std.debug.assert(H.rows == 3);
    std.debug.assert(H.cols == 1);

    var ret = identity(H.T, H.rows + 1);
    for (0..H.rows) |r| HR.set(&ret, r, H.rows, H.get(&vec, r, 0));

    return ret;
}

pub fn scale3D(vec: anytype) SquareMat(He(@TypeOf(vec)).T, He(@TypeOf(vec)).rows) {
    const H = He(@TypeOf(vec));
    const Ret = SquareMat(H.T, H.rows);
    const HR = He(Ret);

    std.debug.assert(H.rows == 3);
    std.debug.assert(H.cols == 1);

    var ret = std.mem.zeroes(Ret);
    for (0..H.rows) |r| HR.set(&ret, r, r, H.get(&vec, r, 0));

    return ret;
}

pub fn scale3DAffine(vec: anytype) SquareMat(He(@TypeOf(vec)).T, He(@TypeOf(vec)).rows + 1) {
    return padAffine(scale3D(vec));
}

pub fn ortho(near: anytype, far: @TypeOf(near)) SquareMat(He(@TypeOf(near)).T, 4) {
    const H = He(@TypeOf(near));
    const T = H.T;

    std.debug.assert(H.rows == 3);
    std.debug.assert(H.cols == 1);

    const translation = translate3D([3]T{
        -(H.x(near) + H.x(far)) / 2,
        -(H.y(near) + H.y(far)) / 2,
        -H.z(near),
    });

    const scale = scale3DAffine([3]T{
        2 / (H.x(far) - H.x(near)),
        2 / (H.y(far) - H.y(near)),
        1 / (H.z(far) - H.z(near)),
    });

    return wgm.mulmm(scale, translation);
}

pub fn zScale(comptime T: type, n: T, f: T) Matrix(T, 4, 4) {
    return transpose([4][4]T{
        .{ n, 0, 0, 0 },
        .{ 0, n, 0, 0 },
        .{ 0, 0, n + f, -n * f },
        .{ 0, 0, 1, 0 },
    });
}

pub fn perspective(near: anytype, far: @TypeOf(near)) SquareMat(He(@TypeOf(near)).T, 4) {
    const H = He(@TypeOf(near));

    return wgm.mulmm(ortho(near, far), zScale(H.T, H.z(near), H.z(far)));
}

pub fn perspectiveFOV(comptime T: type, near: T, far: T, fovy: T, aspect: T) Matrix(T, 4, 4) {
    const angle = fovy / 2;
    const ymax = near * @tan(angle);
    const xmax = ymax * aspect;

    const near_vec = [3]T{
        -xmax,
        -ymax,
        near,
    };

    const far_vec = [3]T{
        xmax,
        ymax,
        far,
    };

    if (@inComptime()) @setEvalBranchQuota(1500);
    return perspective(near_vec, far_vec);
}
