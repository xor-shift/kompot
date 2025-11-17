const std = @import("std");

pub const ParseBasicOptionsError = error{
    BadFillChar,
    BadWidth,
};

/// example option strings:
/// 0>16X -> align right, pad with 0 til 16
/// 016X  -> ditto (special case)
/// 0016X -> align right, pad with 0 til 14
/// >16X  -> align right, pad with space til 16
/// 16X   -> ditto
/// 6X    -> align right, pad wth space til 6
///
/// not yet supported:
/// g.15f -> scientific notation with 15 digits of precision after the decimal
pub fn parseBasicOptions(str: []const u8) ParseBasicOptionsError!std.fmt.Number {
    var ret: std.fmt.Number = .{};

    if (str.len == 0) return ret;

    const maybe_base_and_case: ?struct {
        std.fmt.Number.Mode,
        std.fmt.Case,
    } = switch (str[str.len - 1]) {
        'b' => .{ std.fmt.Number.Mode.binary, .lower },
        'o' => .{ std.fmt.Number.Mode.octal, .lower },
        'x' => .{ std.fmt.Number.Mode.hex, .lower },
        'X' => .{ std.fmt.Number.Mode.hex, .upper },
        else => null,
    };

    const without_base_case = if (maybe_base_and_case) |base_and_case| blk: {
        ret.mode = base_and_case.@"0";
        ret.case = base_and_case.@"1";
        break :blk str[0 .. str.len - 1];
    } else str;

    const fill_str, const width_str, const alignment = if (std.mem.indexOfAny(
        u8,
        without_base_case,
        "<^>",
    )) |alignment_char_pos| .{
        without_base_case[0..alignment_char_pos],
        without_base_case[alignment_char_pos + 1 ..],
        switch (without_base_case[alignment_char_pos]) {
            '<' => std.fmt.Alignment.left,
            '^' => std.fmt.Alignment.center,
            '>' => std.fmt.Alignment.right,
            else => unreachable,
        },
    } else if (without_base_case.len >= 2) switch (without_base_case[0]) {
        '0' => .{ without_base_case[0..1], without_base_case[1..], std.fmt.Alignment.right },
        else => .{ " ", without_base_case, std.fmt.Alignment.right },
    } else .{ " ", without_base_case, std.fmt.Alignment.right };

    ret.fill = if (fill_str.len == 0)
        ' '
    else if (fill_str.len == 1)
        fill_str[0]
    else
        return ParseBasicOptionsError.BadFillChar;

    ret.width = if (width_str.len == 0)
        null
    else
        std.fmt.parseInt(usize, width_str, 0) catch return ParseBasicOptionsError.BadWidth;

    ret.alignment = alignment;

    return ret;
}
