const std = @import("std");

const util = @import("util.zig");

const ascii_table: [256]u8 = .{
    0,   1,   2,   3,   4,   5,   6,   7,    8,   9,   10,  11,  12,   13,  14,  15,
    16,  17,  18,  19,  20,  21,  22,  23,   24,  25,  26,  27,  28,   29,  30,  31,
    ' ', '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',',  '-', '.', '/',
    '0', '1', '2', '3', '4', '5', '6', '7',  '8', '9', ':', ';', '<',  '=', '>', '?',
    '@', 'A', 'B', 'C', 'D', 'E', 'F', 'G',  'H', 'I', 'J', 'K', 'L',  'M', 'N', 'O',
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W',  'X', 'Y', 'Z', '[', '\\', ']', '^', '_',
    '`', 'a', 'b', 'c', 'd', 'e', 'f', 'g',  'h', 'i', 'j', 'k', 'l',  'm', 'n', 'o',
    'p', 'q', 'r', 's', 't', 'u', 'v', 'w',  'x', 'y', 'z', '{', '|',  '}', '~', 127,
    128, 129, 130, 131, 132, 133, 134, 135,  136, 137, 138, 139, 140,  141, 142, 143,
    144, 145, 146, 147, 148, 149, 150, 151,  152, 153, 154, 155, 156,  157, 158, 159,
    160, 161, 162, 163, 164, 165, 166, 167,  168, 169, 170, 171, 172,  173, 174, 175,
    176, 177, 178, 179, 180, 181, 182, 183,  184, 185, 186, 187, 188,  189, 190, 191,
    192, 193, 194, 195, 196, 197, 198, 199,  200, 201, 202, 203, 204,  205, 206, 207,
    208, 209, 210, 211, 212, 213, 214, 215,  216, 217, 218, 219, 220,  221, 222, 223,
    224, 225, 226, 227, 228, 229, 230, 231,  232, 233, 234, 235, 236,  237, 238, 239,
    240, 241, 242, 243, 244, 245, 246, 247,  248, 249, 250, 251, 252,  253, 254, 255,
};

const lookup: [256]u8 = .{
    0,   1,   2,   3,   4,   5,   6,   7,    8,   9,   10,  11,  12,   13,  14,  15,
    16,  17,  18,  19,  20,  21,  22,  23,   24,  25,  26,  27,  28,   29,  30,  31,
    ' ', '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',',  '-', '.', '/',
    '0', '1', '2', '3', '4', '5', '6', '7',  '8', '9', ':', ';', '<',  '=', '>', '?',
    '@', 'A', 'B', 'C', 'D', 'E', 'F', 'G',  'H', 'I', 'J', 'K', 'L',  'M', 'N', 'O',
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W',  'X', 'Y', 'Z', '[', '\\', ']', '^', '_',
    '`', 'A', 'B', 'C', 'D', 'E', 'F', 'G',  'H', 'I', 'J', 'K', 'L',  'M', 'N', 'O',
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W',  'X', 'Y', 'Z', '{', '|',  '}', '~', 127,
    128, 129, 130, 131, 132, 133, 134, 135,  136, 137, 138, 139, 140,  141, 142, 143,
    144, 145, 146, 147, 148, 149, 150, 151,  152, 153, 154, 155, 156,  157, 158, 159,
    160, 161, 162, 163, 164, 165, 166, 167,  168, 169, 170, 171, 172,  173, 174, 175,
    176, 177, 178, 179, 180, 181, 182, 183,  184, 185, 186, 187, 188,  189, 190, 191,
    192, 193, 194, 195, 196, 197, 198, 199,  200, 201, 202, 203, 204,  205, 206, 207,
    208, 209, 210, 211, 212, 213, 214, 215,  216, 217, 218, 219, 220,  221, 222, 223,
    224, 225, 226, 227, 228, 229, 230, 231,  232, 233, 234, 235, 236,  237, 238, 239,
    240, 241, 242, 243, 244, 245, 246, 247,  248, 249, 250, 251, 252,  253, 254, 255,
};

fn implLookup(
    len: usize,
    arr: [*]const u8,
    out: [*]u8,
) void {
    for (arr[0..len], 0..) |v, i| out[i] = lookup[v];
}

test implLookup {
    var res: [256]u8 = undefined;
    implLookup(256, &ascii_table, &res);
    try std.testing.expectEqualSlices(u8, &lookup, &res);
}

fn implSimple(
    len: usize,
    arr: [*]const u8,
    out: [*]u8,
) void {
    for (arr[0..len], 0..) |v, i| out[i] = if ('a' <= v and v <= 'z') v - ('a' - 'A') else v;
}

test implSimple {
    var res: [256]u8 = undefined;
    implSimple(256, &ascii_table, &res);
    try std.testing.expectEqualSlices(u8, &lookup, &res);
}

fn implSIMD(
    comptime vector_len: usize,
    len: usize,
    arr: [*]const u8,
    out: [*]u8,
) void {
    const num_blocks = len / vector_len;
    std.debug.assert(len % vector_len == 0);

    for (0..num_blocks) |block_no| {
        var vec_arr: [vector_len]u8 = undefined;
        @memcpy(&vec_arr, arr[block_no * vector_len .. (block_no + 1) * vector_len]);
        const vec: @Vector(vector_len, u8) = vec_arr;

        const lower_bound: @Vector(vector_len, u8) = @splat('a');
        const upper_bound: @Vector(vector_len, u8) = @splat('z');

        const c_0 = lower_bound <= vec;
        const c_1 = vec <= upper_bound;

        const all_false: @Vector(vector_len, bool) = @splat(false);

        const c = @select(bool, c_1, c_0, all_false);

        const to_subtract: @Vector(vector_len, u8) = @splat('a' - 'A');
        const subtracted = vec -% to_subtract;

        const res_local: [vector_len]u8 = @select(u8, c, subtracted, vec);
        @memcpy(out[block_no * vector_len .. (block_no + 1) * vector_len], &res_local);
    }
}

fn simdFactory(comptime vector_len: usize) fn (len: usize, arr: [*]const u8, out: [*]u8) void {
    return struct {
        fn aufruf(len: usize, arr: [*]const u8, out: [*]u8) void {
            return implSIMD(vector_len, len, arr, out);
        }
    }.aufruf;
}

test implSIMD {
    const arr = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' };
    const arr_capitalised = [_]u8{ 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H' };

    var res: [8 * 32]u8 = undefined;
    implSIMD(8, 8 * 32, &(arr ** 32), &res);

    try std.testing.expectEqualSlices(u8, &(arr_capitalised ** 32), &res);
}

pub fn capitalise(comptime N: usize, arr: [N]u8) [N]u8 {
    var ret: [N]u8 = undefined;

    util.hybridCall(u8, &.{
        .{ 64, simdFactory(64) },
        .{ 32, simdFactory(32) },
        .{ 16, simdFactory(16) },
        .{ 8, simdFactory(8) },
        .{ 1, implLookup },
    }, N, 1, &arr, 1, &ret);

    return ret;
}
