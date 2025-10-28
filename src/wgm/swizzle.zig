const std = @import("std");

const wgm = @import("root.zig");

fn Swizzled(comptime Vec: type, comptime swizzle_string: []const u8) type {
    return wgm.Canonical([swizzle_string.len]wgm.Helper(Vec).T);
}

pub fn swizzle(vec: anytype, comptime swizzle_string: []const u8) Swizzled(@TypeOf(vec), swizzle_string) {
    const Vec = @TypeOf(vec);
    const H = wgm.Helper(Vec);

    const Ret = Swizzled(@TypeOf(vec), swizzle_string);
    const HR = wgm.Helper(Ret);

    var ret: Ret = undefined;

    inline for (swizzle_string, 0..) |c, i| {
        const si = switch (c) {
            'x', 'r' => 0,
            'y', 'g' => 1,
            'z', 'b' => 2,
            'w', 'a' => 3,
            else => @compileError(std.fmt.comptimePrint("unsupported swizzle character '{c}'", .{c})),
        };
        HR.set(&ret, i, 0, H.get(&vec, si, 0));
    }

    return ret;
}

test {
    try std.testing.expect(true);
    try std.testing.expectEqual(
        [_]usize{ 1, 2, 3, 3, 2, 1, 1, 1, 2, 2, 3, 3 },
        swizzle([3]usize{ 1, 2, 3 }, "xyzzyxxxyyzz"),
    );
}
