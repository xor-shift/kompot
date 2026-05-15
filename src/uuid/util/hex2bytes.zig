const util = @import("util.zig");

pub fn isCapitalisedHex(comptime N: usize, arr: [N]u8) bool {
    // auto vectorisation will work its magic im sure

    for (arr) |v| {
        if (('0' <= v and v <= '9') or ('A' <= v and v <= 'F')) continue;
        return false;
    }

    return true;
}

pub const capitalisedHex2bytes = struct {
    fn nibble(digit: u8) u4 {
        if (digit <= '9')
            return @intCast(digit - '0');
        return @as(u4, @intCast(digit - 'A')) + 10;
    }

    fn implSimple(comptime N: usize, arr: [N * 2]u8) [N]u8 {
        var ret: [N]u8 = undefined;
        for (0..N) |i| {
            const hi: u8 = nibble(arr[i * 2 + 0]);
            const lo: u8 = nibble(arr[i * 2 + 1]);

            ret[i] = (hi << 4) | lo;
        }

        return ret;
    }

    pub fn aufruf(comptime N: usize, arr: [N * 2]u8) [N]u8 {
        return implSimple(N, arr);
    }
};
