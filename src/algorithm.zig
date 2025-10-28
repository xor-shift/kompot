const std = @import("std");

pub fn unstable_partition(
    comptime T: type,
    values: []T,
    context: anytype,
    comptime predicate: fn (context: @TypeOf(context), v: T) bool,
) usize {
    var i: usize = 0;

    for (0..values.len) |j| {
        if (@call(.auto, predicate, .{ context, values[j] })) continue;

        std.mem.swap(T, &values[i], &values[j]);
        i += 1;
    }

    return i;
}

test unstable_partition {
    var arr = [_]i32{ 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144 };
    try std.testing.expectEqual(8, unstable_partition(i32, &arr, {}, struct {
        fn aufruf(_: void, v: i32) bool {
            return @mod(v, 2) == 0;
        }
    }.aufruf));
    try std.testing.expectEqualSlices(i32, &.{ 1, 1, 3, 5, 13, 21, 55, 89, 34, 2, 8, 144 }, &arr);
}
