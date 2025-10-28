const std = @import("std");

const wgm = @import("root.zig");

const Canonical = wgm.Canonical;
const Helper = wgm.Helper;
const He = wgm.Helper;

const vec = wgm.vec;

const transpose = wgm.transpose;

const dot = wgm.dot;

const add = wgm.add;
const sub = wgm.sub;
const mulew = wgm.mulew;
const div = wgm.div;

const mulmm = wgm.mulmm;

const compare = wgm.compare;

test Helper {
    try std.testing.expectEqual(i32, He(i32).T);
    try std.testing.expectEqual(i32, He([2]i32).T);
    try std.testing.expectEqual(i32, He([2][3]i32).T);

    try std.testing.expectEqual(1, He(i32).cols);
    try std.testing.expectEqual(1, He([2]i32).cols);
    try std.testing.expectEqual(2, He([2][3]i32).cols);

    try std.testing.expectEqual(1, He(i32).rows);
    try std.testing.expectEqual(2, He([2]i32).rows);
    try std.testing.expectEqual(3, He([2][3]i32).rows);

    try std.testing.expectEqual(i32, Canonical(i32));
    try std.testing.expectEqual(i32, Canonical([1]i32));
    try std.testing.expectEqual(i32, Canonical([1][1]i32));
    try std.testing.expectEqual([2]i32, Canonical([2]i32));
    try std.testing.expectEqual([2][1]i32, Canonical([2][1]i32));
    try std.testing.expectEqual([2]i32, Canonical([1][2]i32));
}

test transpose {
    try std.testing.expectEqual(
        [2][2]i32{ .{ 1, 2 }, .{ 3, 4 } },
        transpose([2][2]i32{ .{ 1, 3 }, .{ 2, 4 } }),
    );
}

test vec {
    try std.testing.expectEqual([3]i32{ 1, 2, 3 }, vec(i32, .{ @intFromBool(true), 2, 3 }));
}

test dot {
    try std.testing.expectEqual(-138, dot([_]i32{ -2, 3, -5 }, [_]i32{ 7, -13, 17 }));
}

test "binary ops" {
    try std.testing.expectEqual(3, add(1, 2));

    try std.testing.expectEqual(
        [_]i32{ 4, 4, 4 },
        add([_]i32{ 1, 2, 3 }, [_]i32{ 3, 2, 1 }),
    );

    try std.testing.expectEqual(
        [_]i32{ -2, 0, 2 },
        sub([_]i32{ 1, 2, 3 }, [_]i32{ 3, 2, 1 }),
    );

    try std.testing.expectEqual(
        [_]i32{ 3, 4, 3 },
        mulew([_]i32{ 1, 2, 3 }, [_]i32{ 3, 2, 1 }),
    );

    try std.testing.expectEqual(
        [_]i32{ 64, 16, 2 },
        div([_]i32{ 512, 64, -8 }, [_]i32{ 8, 4, -3 }),
    );

    try std.testing.expectEqual(
        [3][3]i32{ .{ 10, 10, 10 }, .{ 10, 10, 10 }, .{ 10, 10, 10 } },
        add(
            [3][3]i32{ .{ 1, 4, 7 }, .{ 2, 5, 8 }, .{ 3, 6, 9 } },
            [3][3]i32{ .{ 9, 6, 3 }, .{ 8, 5, 2 }, .{ 7, 4, 1 } },
        ),
    );

    try std.testing.expectEqual(
        [_]i32{ 2, 3, 4 },
        add([_]i32{ 1, 2, 3 }, 1),
    );

    try std.testing.expectEqual(
        [_]i32{ 2, 3, 4 },
        add(1, [_]i32{ 1, 2, 3 }),
    );

    try std.testing.expectEqual(
        [3][3]i32{ .{ 2, 5, 8 }, .{ 3, 6, 9 }, .{ 4, 7, 10 } },
        add([3][3]i32{ .{ 1, 4, 7 }, .{ 2, 5, 8 }, .{ 3, 6, 9 } }, 1),
    );

    try std.testing.expectEqual(
        [3][3]i32{ .{ 2, 5, 8 }, .{ 3, 6, 9 }, .{ 4, 7, 10 } },
        add(1, [3][3]i32{ .{ 1, 4, 7 }, .{ 2, 5, 8 }, .{ 3, 6, 9 } }),
    );
}

test mulmm {
    try std.testing.expectEqual(
        transpose([3][3]i32{
            .{ 121, 131, 157 },
            .{ 288, 312, 374 },
            .{ 564, 612, 734 },
        }),
        mulmm(
            transpose([3][2]i32{
                .{ 2, 3 },
                .{ 5, 7 },
                .{ 11, 13 },
            }),
            transpose([2][3]i32{
                .{ 17, 19, 23 },
                .{ 29, 31, 37 },
            }),
        ),
    );
}

test compare {
    try std.testing.expectEqual(false, compare(
        .all,
        [4]i32{ 0, 1, 2, 3 },
        .equal,
        [4]i32{ 3, 2, 1, 0 },
    ));

    try std.testing.expectEqual(true, compare(
        .none,
        [4]i32{ 0, 1, 2, 3 },
        .equal,
        [4]i32{ 3, 2, 1, 0 },
    ));

    try std.testing.expectEqual(true, compare(
        .all,
        [4]i32{ 0, 1, 2, 3 },
        .not_equal,
        [4]i32{ 3, 2, 1, 0 },
    ));

    try std.testing.expectEqual(true, compare(
        .some,
        [4]i32{ 0, 1, 2, 3 },
        .less_than,
        [4]i32{ 3, 2, 1, 0 },
    ));

    try std.testing.expectEqual(false, compare(
        .some,
        [4]i32{ 9, 9, 2, 3 },
        .less_than,
        [4]i32{ 3, 2, 1, 0 },
    ));
}

const padAffine = wgm.padAffine;
const fromHomogenous = wgm.fromHomogenous;

const rotation2D = wgm.rotation2D;
const rotation3D = wgm.rotation3D;
const translate3D = wgm.translate3D;

const ortho = wgm.ortho;
const perspective = wgm.perspective;

test padAffine {
    try std.testing.expectEqual(
        transpose([4][4]i32{
            .{ 1, 2, 3, 0 },
            .{ 4, 5, 6, 0 },
            .{ 7, 8, 9, 0 },
            .{ 0, 0, 0, 1 },
        }),
        padAffine(transpose([3][3]i32{
            .{ 1, 2, 3 },
            .{ 4, 5, 6 },
            .{ 7, 8, 9 },
        })),
    );
}

test translate3D {
    try std.testing.expectEqual(
        transpose([4][4]i32{
            .{ 1, 0, 0, 1 },
            .{ 0, 1, 0, 2 },
            .{ 0, 0, 1, -3 },
            .{ 0, 0, 0, 1 },
        }),
        translate3D([3]i32{ 1, 2, -3 }),
    );
}

test "projections" {
    const nudge = struct {
        const NudgeType = enum {
            ninf,
            inf,
        };

        fn aufruf(comptime T: type, comptime typ: NudgeType, comptime n: usize) fn (_: T) T {
            return struct {
                fn aufruf(v: T) T {
                    var ret = v;
                    const inf = std.math.inf(T);

                    inline for (0..n) |_| {
                        ret = std.math.nextAfter(T, ret, if (typ == .inf) inf else -inf);
                    }

                    return ret;
                }
            }.aufruf;
        }
    }.aufruf;

    const nudge1id = nudge(f64, .inf, 1);
    const nudge2id = nudge(f64, .inf, 2);

    const mat_o = ortho([3]f64{ 2, 3, 4 }, [3]f64{ 5, 5, 5 });
    try std.testing.expectEqual(transpose([4][4]f64{
        .{ 2.0 / 3.0, 0, 0, nudge1id(-7.0 / 3.0) },
        .{ 0, 2.0 / 2.0, 0, -8.0 / 2.0 },
        .{ 0, 0, 1.0 / 1.0, -4.0 / 1.0 },
        .{ 0, 0, 0, 1 },
    }), mat_o);

    try std.testing.expectEqual(
        [4]f64{ nudge2id(-1), -1, 0, 1 },
        mulmm(mat_o, [4]f64{ 2, 3, 4, 1 }),
    );

    try std.testing.expectEqual(
        [4]f64{ 0, 0, 0.5, 1 },
        mulmm(mat_o, [4]f64{ 3.5, 4, 4.5, 1 }),
    );

    const mat_p = perspective([3]f64{ 2, 3, 4 }, [3]f64{ 5, 5, 5 });

    try std.testing.expectEqual(
        [3]f64{ nudge2id(-1), -1, 0 },
        fromHomogenous(mulmm(mat_p, [4]f64{ 2, 3, 4, 1 })),
    );

    // try std.testing.expectEqual(
    //     vec3d(0, 0, 0.5),
    //     from_homogenous(f64, mulmm(mat_p, vec4d(3.5, 4, 4.5, 1))),
    // );
}
