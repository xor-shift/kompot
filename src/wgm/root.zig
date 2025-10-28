const std = @import("std");

const determinant_mod = @import("determinant.zig");
const inverse_mod = @import("invert.zig");
const special_matrices_mod = @import("special_matrices.zig");
const swizzle_mod = @import("swizzle.zig");

pub const determinant = determinant_mod.determinant;

pub const inverse = inverse_mod.inverse;

pub const identity = special_matrices_mod.identity;
pub const fromHomogenous = special_matrices_mod.fromHomogenous;
pub const padAffine = special_matrices_mod.padAffine;
pub const rotation2D = special_matrices_mod.rotation2D;
pub const rotateYZ = special_matrices_mod.rotateYZ;
pub const rotateZX = special_matrices_mod.rotateZX;
pub const rotateXY = special_matrices_mod.rotateXY;
pub const translate3D = special_matrices_mod.translate3D;
pub const scale3D = special_matrices_mod.scale3D;
pub const scale3DAffine = special_matrices_mod.scale3DAffine;
pub const ortho = special_matrices_mod.ortho;
pub const zScale = special_matrices_mod.zScale;
pub const perspective = special_matrices_mod.perspective;
pub const perspectiveFOV = special_matrices_mod.perspectiveFOV;

pub const swizzle = swizzle_mod.swizzle;

const do_simd = false;

test {
    std.testing.refAllDecls(determinant_mod);
    std.testing.refAllDecls(inverse_mod);
    std.testing.refAllDecls(special_matrices_mod);
    std.testing.refAllDecls(swizzle_mod);
    std.testing.refAllDecls(@import("test.zig"));
}

pub fn Canonical(comptime Mat: type) type {
    const H = Helper(Mat);

    if (H.cols == 1) {
        return if (H.rows == 1) H.T else [H.rows]H.T;
    } else {
        return [H.cols][H.rows]H.T;
    }
}

pub fn Vector(comptime T: type, comptime rows: usize) type {
    return Canonical([1][rows]T);
}

pub fn Matrix(comptime T: type, comptime rows: usize, comptime cols: usize) type {
    return Canonical([cols][rows]T);
}

pub fn Verbose(comptime Mat: type) type {
    const H = Helper(Mat);
    return [H.cols][H.rows]H.T;
}

pub fn Helper(comptime Mat: type) type {
    return struct {
        fn tcr() struct { type, usize, usize } {
            return switch (@typeInfo(Mat)) {
                .array => |v| switch (@typeInfo(v.child)) {
                    .array => |r| .{ r.child, v.len, r.len }, // v columns, r rows
                    else => .{ v.child, 1, v.len }, // v rows
                },
                else => .{ Mat, 1, 1 },
            };
        }

        pub const T = tcr().@"0";
        pub const cols = tcr().@"1";
        pub const rows = tcr().@"2";

        pub const Identity = Canonical([cols][rows]T);
        pub const Transposed = Canonical([rows][cols]T);

        /// Turns `mat` (a pointer to type `Mat`) into `*[cols][rows]T`
        /// regardless of whether `mat.*` is canonical.
        pub inline fn p(mat: anytype) *Verbose(Mat) {
            return @constCast(cp(mat));
        }

        /// Turns `mat` (a pointer to type `Mat`) into `*const [cols][rows]T`
        /// regardless of whether `mat.*` is canonical.
        pub inline fn cp(mat: anytype) *const Verbose(Mat) {
            const self: *const Verbose(Mat) = @ptrCast(mat);
            return self;
        }

        /// Turns `mat` (a pointer to type `Mat`) into `*[cols * rows]T`
        /// regardless of whether `mat.*` is canonical.
        pub inline fn fp(mat: anytype) *[rows * cols]T {
            return @constCast(cfp(mat));
        }

        /// Turns `mat` (a pointer to type `Mat`) into `*const [cols * rows]T`
        /// regardless of whether `mat.*` is canonical.
        pub inline fn cfp(mat: anytype) *const [rows * cols]T {
            const self: *const [rows * cols]T = @ptrCast(mat);
            return self;
        }

        pub inline fn get(mat: anytype, row: usize, col: usize) T {
            std.debug.assert(col < cols);
            std.debug.assert(row < rows);

            return cp(mat)[col][row];
        }

        pub inline fn set(mat: anytype, row: usize, col: usize, v: T) void {
            std.debug.assert(col < cols);
            std.debug.assert(row < rows);

            p(mat)[col][row] = v;
        }

        // zig fmt: off
        pub inline fn x(mat: anytype) T { return get(&mat, 0, 0); }
        pub inline fn y(mat: anytype) T { return get(&mat, 1, 0); }
        pub inline fn z(mat: anytype) T { return get(&mat, 2, 0); }
        pub inline fn w(mat: anytype) T { return get(&mat, 3, 0); }
        // zig fmt: on
    };
}

const He = Helper;

pub fn transpose(mat: anytype) He(@TypeOf(mat)).Transposed {
    const H = He(@TypeOf(mat));
    const RH = He(H.Transposed);

    var ret: H.Transposed = undefined;
    for (0..H.cols) |col| for (0..H.rows) |row| {
        const v = H.get(&mat, row, col);
        RH.set(&ret, col, row, v);
    };

    return ret;
}

pub inline fn vec(comptime T: type, values: anytype) Vector(T, values.len) {
    const H = Helper(Vector(T, values.len));

    var ret: Vector(T, values.len) = undefined;
    inline for (values, 0..) |v, i| H.set(&ret, i, 0, @as(T, v));

    return ret;
}

pub fn dot(lhs: anytype, rhs: @TypeOf(lhs)) He(@TypeOf(lhs)).T {
    const H = He(@TypeOf(lhs));

    if (H.cols != 1) @compileError("`dot` is meant for vectors");

    if (do_simd) {
        const lv: @Vector(H.rows, H.T) = lhs;
        const rv: @Vector(H.rows, H.T) = rhs;

        return @reduce(.Add, lv * rv);
    }

    var ret: H.T = 0;
    for (0..H.rows) |i| {
        const v = H.get(&lhs, i, 0) * H.get(&rhs, i, 0);
        ret += v;
    }

    return ret;
}

fn ArithmeticResult(comptime Lhs: type, comptime Rhs: type) type {
    const LRet = Canonical(Lhs);
    const RRet = Canonical(Rhs);

    const LH = He(Lhs);
    const RH = He(Rhs);

    const l_scalar = LH.rows == 1 and LH.cols == 1;
    const r_scalar = RH.rows == 1 and RH.cols == 1;

    if (LRet == RRet) return LRet;
    if (l_scalar and r_scalar) return LRet;

    if (!l_scalar and r_scalar) return LRet;
    if (l_scalar and !r_scalar) return RRet;

    @compileError("can't perform an arithmetic operation on two differently-sized matrices");
}

// glorified macros
const binary_ops = struct {
    const max = struct {
        inline fn scalar(lhs: anytype, rhs: anytype) @TypeOf(@max(lhs, rhs)) {
            return @max(lhs, rhs);
        }

        inline fn simd(comptime T: type, comptime w: usize, lhs: @Vector(w, T), rhs: @Vector(w, T)) @Vector(w, T) {
            return @max(lhs, rhs);
        }
    };

    const min = struct {
        inline fn scalar(lhs: anytype, rhs: anytype) @TypeOf(@min(lhs, rhs)) {
            return @min(lhs, rhs);
        }

        inline fn simd(comptime T: type, comptime w: usize, lhs: @Vector(w, T), rhs: @Vector(w, T)) @Vector(w, T) {
            return @min(lhs, rhs);
        }
    };

    const add = struct {
        inline fn scalar(lhs: anytype, rhs: anytype) @TypeOf(lhs + rhs) {
            return lhs + rhs;
        }

        inline fn simd(comptime T: type, comptime w: usize, lhs: @Vector(w, T), rhs: @Vector(w, T)) @Vector(w, T) {
            return lhs + rhs;
        }
    };

    const sub = struct {
        inline fn scalar(lhs: anytype, rhs: anytype) @TypeOf(lhs - rhs) {
            return lhs - rhs;
        }

        inline fn simd(comptime T: type, comptime w: usize, lhs: @Vector(w, T), rhs: @Vector(w, T)) @Vector(w, T) {
            return lhs - rhs;
        }
    };

    const mul = struct {
        inline fn scalar(lhs: anytype, rhs: anytype) @TypeOf(lhs * rhs) {
            return lhs * rhs;
        }

        inline fn simd(comptime T: type, comptime w: usize, lhs: @Vector(w, T), rhs: @Vector(w, T)) @Vector(w, T) {
            return lhs * rhs;
        }
    };

    const div = struct {
        inline fn scalar(lhs: anytype, rhs: anytype) @TypeOf(lhs + rhs) {
            if (@typeInfo(@TypeOf(lhs)) == .int) return @divTrunc(lhs, rhs) //
            else return lhs / rhs;
        }

        inline fn simd(comptime T: type, comptime w: usize, lhs: @Vector(w, T), rhs: @Vector(w, T)) @Vector(w, T) {
            return lhs / rhs;
        }
    };
};

fn bopvv(comptime Op: type, comptime H: type, lhs: anytype, rhs: anytype) ArithmeticResult(@TypeOf(lhs), @TypeOf(rhs)) {
    const Ret = ArithmeticResult(@TypeOf(lhs), @TypeOf(rhs));

    if (do_simd) {
        const elem_ct = H.rows * H.cols;
        const VecType = @Vector(elem_ct, H.T);

        const lv: VecType = @as(*const [elem_ct]H.T, @ptrCast(&lhs)).*;
        const rv: VecType = @as(*const [elem_ct]H.T, @ptrCast(&rhs)).*;

        const resv = Op.simd(H.T, elem_ct, lv, rv);
        const res: [elem_ct]H.T = resv;

        return @as(*const Ret, @ptrCast(&res)).*;
    }

    var ret: Ret = undefined;
    for (0..H.cols) |c| for (0..H.rows) |r| {
        const v = Op.scalar(H.get(&lhs, r, c), H.get(&rhs, r, c));
        H.set(&ret, r, c, v);
    };

    return ret;
}

fn bopvs(comptime Op: type, comptime H: type, vector: anytype, scalar: anytype) ArithmeticResult(@TypeOf(vector), @TypeOf(scalar)) {
    const Ret = ArithmeticResult(@TypeOf(vector), @TypeOf(scalar));

    if (do_simd) {
        const elem_ct = H.rows * H.cols;
        const VecType = @Vector(elem_ct, H.T);

        const vv: VecType = @as(*const [elem_ct]H.T, @ptrCast(&vector)).*;
        const sv: VecType = @splat(scalar);

        const resv = Op.simd(H.T, elem_ct, vv, sv);
        const res: [elem_ct]H.T = resv;

        return @as(*const Ret, @ptrCast(&res)).*;
    }

    var ret: Ret = undefined;
    for (0..H.cols) |c| for (0..H.rows) |r| {
        const v = Op.scalar(H.get(&vector, r, c), scalar);
        H.set(&ret, r, c, v);
    };

    return ret;
}

fn bop(comptime Op: type, lhs: anytype, rhs: anytype) ArithmeticResult(@TypeOf(lhs), @TypeOf(rhs)) {
    const Lhs = @TypeOf(lhs);
    const Rhs = @TypeOf(rhs);
    const Ret = ArithmeticResult(Lhs, Rhs);

    const LH = He(Lhs);
    const RH = He(Rhs);
    const H = He(Ret);

    const l_scalar = LH.rows == 1 and LH.cols == 1;
    const r_scalar = RH.rows == 1 and RH.cols == 1;

    if (l_scalar and r_scalar) {
        const lv = @as(*const LH.T, @ptrCast(&lhs)).*;
        const rv = @as(*const RH.T, @ptrCast(&rhs)).*;
        return Op.scalar(lv, rv);
    }

    if (!l_scalar and !r_scalar) return bopvv(Op, H, lhs, rhs);

    const scalar = if (l_scalar) lhs else rhs;
    const vector = if (l_scalar) rhs else lhs;

    // TODO: bopvs does not respect the order and always divides *by* the scalar
    return bopvs(Op, H, vector, @as(H.T, scalar));
}

pub fn min(lhs: anytype, rhs: anytype) ArithmeticResult(@TypeOf(lhs), @TypeOf(rhs)) {
    return bop(binary_ops.min, lhs, rhs);
}

pub fn max(lhs: anytype, rhs: anytype) ArithmeticResult(@TypeOf(lhs), @TypeOf(rhs)) {
    return bop(binary_ops.max, lhs, rhs);
}

pub fn add(lhs: anytype, rhs: anytype) ArithmeticResult(@TypeOf(lhs), @TypeOf(rhs)) {
    return bop(binary_ops.add, lhs, rhs);
}

pub fn sub(lhs: anytype, rhs: anytype) ArithmeticResult(@TypeOf(lhs), @TypeOf(rhs)) {
    return bop(binary_ops.sub, lhs, rhs);
}

pub fn mulew(lhs: anytype, rhs: anytype) ArithmeticResult(@TypeOf(lhs), @TypeOf(rhs)) {
    return bop(binary_ops.mul, lhs, rhs);
}

/// No sane man would expect this to do actual matrix division and so it's
/// named "div" instead of "divew". Go invert and multiply if you want actual
/// division.
pub fn div(lhs: anytype, rhs: anytype) ArithmeticResult(@TypeOf(lhs), @TypeOf(rhs)) {
    return bop(binary_ops.div, lhs, rhs);
}

pub fn lerp(lhs: anytype, rhs: @TypeOf(lhs), factor: He(@TypeOf(lhs)).T) @TypeOf(lhs) {
    const Lhs = @TypeOf(lhs);
    const H = He(Lhs);

    var ret: Lhs = undefined;
    for (0..H.cols) |c| for (0..H.rows) |r| {
        const lv = H.get(&lhs, r, c);
        const rv = H.get(&rhs, r, c);
        const v = lv + (rv - lv) * factor;
        H.set(&ret, r, c, v);
    };

    return ret;
}

pub fn divideRoundUp(v: anytype, align_to: anytype) ArithmeticResult(@TypeOf(v), @TypeOf(align_to)) {
    return div(sub(add(v, align_to), 1), align_to);
}

pub fn alignUp(v: anytype, align_to: anytype) ArithmeticResult(@TypeOf(v), @TypeOf(align_to)) {
    return mulew(divideRoundUp(v, align_to), align_to);
}

test div {
    // try std.testing.expectEqual([3]usize{ 1, 2, 3 }, div(@as(usize, 6), [3]usize{ 6, 3, 2 }));
}

pub fn mulmm(lhs: anytype, rhs: anytype) Matrix(He(@TypeOf(lhs)).T, He(@TypeOf(lhs)).rows, He(@TypeOf(rhs)).cols) {
    const Lhs = @TypeOf(lhs);
    const Rhs = @TypeOf(rhs);

    const LH = He(Lhs);
    const RH = He(Rhs);

    std.debug.assert(LH.T == RH.T);
    std.debug.assert(LH.cols == RH.rows);

    const Ret = Matrix(LH.T, LH.rows, RH.cols);
    const H = He(Ret);

    var ret: Ret = undefined;

    if (!do_simd) {
        for (0..RH.cols) |o_c| for (0..LH.rows) |o_r| {
            var v: H.T = 0;

            for (0..LH.cols) |i| {
                const l = LH.get(&lhs, o_r, i);
                const r = RH.get(&rhs, i, o_c);
                v += l * r;
            }

            H.set(&ret, o_r, o_c, v);
        };

        return ret;
    }

    const LTH = He(LH.Transposed);
    const lhs_t = transpose(lhs);

    // a b * x y z
    // c d   i j k
    // e f
    //
    // a c e
    // b d f

    for (0..RH.cols) |o_c| for (0..LH.rows) |o_r| {
        const l: @Vector(LTH.rows, H.T) = LTH.cp(&lhs_t)[o_r];
        const r: @Vector(RH.rows, H.T) = RH.cp(&rhs)[o_c];
        const v = @reduce(.Add, l * r);
        H.set(&ret, o_r, o_c, v);
    };

    return ret;
}

const BooleanReduction = enum {
    all, // and
    not_all, // nand

    some_not_all, // xor
    none_or_all, // xnor

    some, // or
    none, // nor
};

const Comparison = enum {
    equal,
    not_equal,

    greater_than,
    greater_than_equal,

    less_than,
    less_than_equal,
};

/// Returns whether (`some`|`all`|...) of the elements of `lhs` are
/// (`equal`|`not_equal`|...) to `rhs`.
pub fn compare(comptime reduction: BooleanReduction, lhs: anytype, comptime comparison: Comparison, rhs: anytype) bool {
    const Lhs = @TypeOf(lhs);
    const Rhs = @TypeOf(rhs);

    const LH = He(Lhs);
    const RH = He(Rhs);

    std.debug.assert(LH.rows == RH.rows);
    std.debug.assert(LH.cols == RH.cols);

    if (!do_simd) {
        var got_true = false;
        var got_false = false;

        for (0..LH.cols) |c| for (0..RH.rows) |r| {
            const lv = LH.get(&lhs, r, c);
            const rv = LH.get(&rhs, r, c);

            const do_negate = switch (comparison) {
                .not_equal, .less_than_equal, .greater_than_equal => true,
                else => false,
            };

            const comp_res = switch (comparison) {
                .equal, .not_equal => lv == rv,
                .less_than, .greater_than_equal => lv < rv,
                .greater_than, .less_than_equal => lv > rv,
            };

            const res = comp_res and !do_negate or !comp_res and do_negate;

            switch (reduction) {
                .all => if (!res) return false,
                .not_all => if (!res) return true,
                .some_not_all => if (res and got_false or !res and got_true) return true,
                .none_or_all => if (res and got_false or !res and got_true) return false,
                .some => if (res) return true,
                .none => if (res) return false,
            }

            got_true = got_true or res;
            got_false = got_false or !res;
        };

        return switch (reduction) {
            .all => true,
            .not_all => false,
            .some_not_all => false,
            .none_or_all => true,
            .some => false,
            .none => true,
        };
    }

    std.debug.assert(LH.T == RH.T);

    const lv: @Vector(LH.rows * LH.cols, LH.T) = LH.cfp(&lhs).*;
    const rv: @Vector(RH.rows * RH.cols, RH.T) = RH.cfp(&rhs).*;

    const comp_res = switch (comparison) {
        .equal => lv == rv,
        .not_equal => lv != rv,
        .greater_than => lv > rv,
        .greater_than_equal => lv >= rv,
        .less_than => lv < rv,
        .less_than_equal => lv <= rv,
    };

    return switch (reduction) {
        .all => @reduce(.And, comp_res),
        .not_all => !@reduce(.And, comp_res),
        .some_not_all => @reduce(.Xor, comp_res),
        .none_or_all => !@reduce(.Xor, comp_res),
        .some => @reduce(.Or, comp_res),
        .none => !@reduce(.Or, comp_res),
    };
}

pub fn length(v: anytype) He(@TypeOf(v)).T {
    const H = He(@TypeOf(v));

    std.debug.assert(H.cols == 1);

    if (!do_simd) {
        var ret: H.T = 0;
        for (0..H.rows) |r| {
            const v_r = H.get(&v, r, 0);
            ret += v_r * v_r;
        }
        return @sqrt(ret);
    }

    const vv: @Vector(H.rows, H.T) = H.cfp(&v).*;
    const vvvv = vv * vv;
    return @sqrt(@reduce(.Add, vvvv));
}

pub fn normalized(v: anytype) @TypeOf(v) {
    return div(v, length(v));
}

pub fn lossyCast(comptime To: type, m: anytype) Matrix(To, He(@TypeOf(m)).rows, He(@TypeOf(m)).cols) {
    const M = @TypeOf(m);
    const H = He(M);

    const Ret = Matrix(To, H.rows, H.cols);
    const RH = He(Ret);

    var ret: Ret = undefined;
    for (0..H.rows * H.cols) |i| {
        RH.fp(&ret)[i] = std.math.lossyCast(To, H.cfp(&m)[i]);
    }

    return ret;
}

pub fn cast(comptime To: type, m: anytype) ?Matrix(To, He(@TypeOf(m)).rows, He(@TypeOf(m)).cols) {
    const M = @TypeOf(m);
    const H = He(M);

    const Ret = Matrix(To, H.rows, H.cols);
    const RH = He(Ret);

    var ret: Ret = undefined;
    for (0..H.rows * H.cols) |i| {
        RH.fp(&ret)[i] = std.math.cast(To, H.cfp(&m)[i]) orelse return null;
    }

    return ret;
}

pub fn negate(m: anytype) @TypeOf(m) {
    const H = He(@TypeOf(m));

    var ret: @TypeOf(m) = undefined;
    for (0..H.rows * H.cols) |i| H.fp(&ret)[i] = -H.cfp(&m)[i];

    return ret;
}

pub fn round(m: anytype) @TypeOf(m) {
    const H = He(@TypeOf(m));

    var ret: @TypeOf(m) = undefined;
    for (0..H.rows * H.cols) |i| H.fp(&ret)[i] = std.math.round(H.cfp(&m)[i]);

    return ret;
}

pub fn trunc(m: anytype) @TypeOf(m) {
    const H = He(@TypeOf(m));

    var ret: @TypeOf(m) = undefined;
    for (0..H.rows * H.cols) |i| H.fp(&ret)[i] = std.math.trunc(H.cfp(&m)[i]);

    return ret;
}

pub fn abs(comptime T: type, m: anytype) Canonical(Matrix(T, He(@TypeOf(m)).rows, He(@TypeOf(m)).cols)) {
    // TODO: im being lazy here, deduce the result type
    const HM = He(@TypeOf(m));
    const Ret = Canonical(Matrix(T, He(@TypeOf(m)).rows, He(@TypeOf(m)).cols));
    const H = He(Ret);
    var ret: Ret = undefined;
    for (0..H.rows * H.cols) |i| H.fp(&ret)[i] = @abs(HM.cfp(&m)[i]);

    return ret;
}

pub fn toIdx(coords: anytype, dims: @TypeOf(coords)) He(@TypeOf(coords)).T {
    const T = @TypeOf(coords);
    const H = He(T);

    if (H.cols != 1) {
        @compileError("to_idx can only be used on vectors");
    }

    switch (@typeInfo(H.T)) {
        .int => |v| if (v.signedness != .unsigned) {
            @compileError("to_idx can only be used on vectors consisting of unsigned integers");
        },
        else => @compileError("to_idx can only be used on integer vectors"),
    }

    var mult: H.T = 1;
    var ret: H.T = 0;
    for (0..H.rows) |i| {
        ret += mult * H.get(&coords, i, 0);
        mult *= H.get(&dims, i, 0);
    }

    return ret;
}

test toIdx {
    try std.testing.expectEqual(1, toIdx(@as(usize, 1), 1));
    try std.testing.expectEqual(2 + 3 * 7 + 5 * 7 * 11, toIdx([_]usize{ 2, 3, 5 }, [_]usize{ 7, 11, 13 }));
}

pub fn fromIdx(idx: anytype, dims: anytype) @TypeOf(dims) {
    const T = @TypeOf(dims);
    const H = He(T);

    var ret: T = undefined;
    var v: H.T = idx;
    for (0..H.rows) |i| {
        ret[i] = v % dims[i];
        v /= dims[i];
    }

    return ret;
}

test fromIdx {
    try std.testing.expectEqual([_]usize{ 2, 3, 5 }, fromIdx(2 + 3 * 7 + 5 * 7 * 11, [_]usize{ 7, 11, 13 }));
}
