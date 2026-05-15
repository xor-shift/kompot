pub fn hybridCall(
    comptime T: type,
    comptime funs: []const struct { usize, *const fn (usize, [*]const u8, [*]u8) void },
    len: usize,
    arr_divisor: usize,
    arr: [*]const T,
    out_divisor: usize,
    out: [*]T,
) void {
    var consumed: usize = 0;

    inline for (funs) |fun_pair| {
        const block_size = fun_pair.@"0";
        const fun = fun_pair.@"1";

        const remaining_in = len - consumed;
        const blocks = remaining_in / block_size;

        const cur_arr = arr + consumed / arr_divisor;
        const cur_out = out + consumed / out_divisor;
        const cur_len = blocks * block_size;

        if (blocks != 0) {
            fun(cur_len, cur_arr, cur_out);
            consumed += cur_len;
        }
    }
}
