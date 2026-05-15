const std = @import("std");

const util = @import("util/root.zig");

test {
    std.testing.refAllDecls(util);
}

pub const Raw = u128;
pub const Str = [36]u8;
const CompactStr = [32]u8;

fn strToCompactStr(str: Str) ?CompactStr {
    var ret: CompactStr = undefined;

    @memcpy(ret[0..8], str[0..8]);
    @memcpy(ret[8..12], str[9..13]);
    @memcpy(ret[12..16], str[14..18]);
    @memcpy(ret[16..20], str[19..23]);
    @memcpy(ret[20..32], str[24..36]);

    if (str[8] != '-') return null;
    if (str[13] != '-') return null;
    if (str[18] != '-') return null;
    if (str[23] != '-') return null;

    return ret;
}

test {
    try std.testing.expectEqualSlices(u8, "ebb5c73503084e3c9aea8a270aebfe15", &(strToCompactStr("ebb5c735-0308-4e3c-9aea-8a270aebfe15".*).?));
    try std.testing.expectEqual(null, strToCompactStr("ebb5c735-0308-4e3c-9aea+8a270aebfe15".*));
}

/// this function is fairly lenient.
pub fn strToRaw(str: Str) ?Raw {
    // checks are as explicit as possible so that the compiler has an easier time if this function is called with `orelse unreachable`

    const compact: CompactStr = strToCompactStr(str) orelse return null;
    const capitalised: CompactStr = util.capitalise(compact.len, compact);

    if (!util.isCapitalisedHex(capitalised.len, capitalised)) return null;
    const raw_bytes = util.capitalisedHex2bytes(16, capitalised);

    return std.mem.bigToNative(u128, @bitCast(raw_bytes));
}

test strToRaw {
    const res = strToRaw("ebb5c735-0308-4e3c-9aea-8a270aebfe15".*).?;
    const expected: u128 = 0xebb5c73503084e3c9aea8a270aebfe15;
    try std.testing.expectEqual(expected, res);
}

fn rawToCompactStr(raw: Raw) CompactStr {
    const raw_arr: [16]u8 = @bitCast(std.mem.nativeToBig(u128, raw));
    const raw_vec: @Vector(16, u8) = raw_arr;
    const v0: @Vector(32, u8) = @shuffle(u8, raw_vec, undefined, [_]u8{
        0,  0,  1,  1,  2,  2,  3,  3,
        4,  4,  5,  5,  6,  6,  7,  7,
        8,  8,  9,  9,  10, 10, 11, 11,
        12, 12, 13, 13, 14, 14, 15, 15,
    });

    const masks: @Vector(32, u8) = [_]u8{ 0xF0, 0x0F } ** 16;
    const shifts: @Vector(32, u8) = [_]u8{ 4, 0 } ** 16;

    const nibbles = ((v0 & masks) >> shifts);

    const all_tens: @Vector(32, u8) = @splat(10);
    const all_as: @Vector(32, u8) = @splat('a');
    const all_0s: @Vector(32, u8) = @splat('0');

    const is_alphabetical = nibbles >= all_tens;

    const a = nibbles -% all_tens +% all_as;
    const b = nibbles +% all_0s;
    const res_vec = @select(u8, is_alphabetical, a, b);

    const res: CompactStr = res_vec;

    return res;
}

test rawToCompactStr {
    const raw: Raw = 0xebb5c73503084e3c9aea8a270aebfe15;
    const expected: CompactStr = "ebb5c73503084e3c9aea8a270aebfe15".*;
    const got = rawToCompactStr(raw);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

pub fn rawToStr(raw: Raw) Str {
    const compact_str = rawToCompactStr(raw);

    var ret: Str = undefined;
    @memcpy(ret[0..8], compact_str[0..8]);
    @memcpy(ret[9..13], compact_str[8..12]);
    @memcpy(ret[14..18], compact_str[12..16]);
    @memcpy(ret[19..23], compact_str[16..20]);
    @memcpy(ret[24..36], compact_str[20..32]);

    ret[8] = '-';
    ret[13] = '-';
    ret[18] = '-';
    ret[23] = '-';

    return ret;
}

test rawToStr {
    const raw: Raw = 0xebb5c73503084e3c9aea8a270aebfe15;
    const expected: Str = "ebb5c735-0308-4e3c-9aea-8a270aebfe15".*;
    const got = rawToStr(raw);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}
