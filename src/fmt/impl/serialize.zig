const std = @import("std");

const fmt = @import("../root.zig");

pub fn serializeImpl(
    writer: *std.io.Writer,
    format_str: []const u8,
    args: anytype,
    comptime conversion_tuples: anytype,
) !void {
    var iter: fmt.FormatStrIterator = .init(format_str);

    inline for (args) |arg| {
        const specifier_for_arg = while (true) {
            const res = iter.next() orelse return error.MismatchedFormatStringAndArgs;

            const specifier = switch (res) {
                .literal => continue,
                .format_specifier => |sno| sno.conversion_specifier,
            };

            break specifier;
        };

        var serialized: bool = false;

        inline for (conversion_tuples) |pair| {
            if (std.mem.eql(u8, pair.conversion_specifier, specifier_for_arg)) {
                std.debug.assert(!serialized);
                serialized = true;
                try pair.serialization_function(writer, arg);
            }
        }

        if (!serialized) return fmt.FormatError.UnknownSpecifier;
    }
}

test serializeImpl {
    const alloc = std.testing.allocator;

    var writer: std.io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    try serializeImpl(
        &writer.writer,
        "{f32}, asdasd {i16}, {s}, aaaaaaaAAA {{{s}",
        .{
            3.1415926535,
            @as(i16, 1337),
            "Hello, world!",
            @errorName(error.Asdf),
        },
        fmt.builtin_conversion_tuples,
    );

    const res = try writer.toOwnedSlice();
    defer alloc.free(res);

    // zig fmt: off
    try std.testing.expectEqualSlices(u8, &.{
        0xdb, 0x0f, 0x49, 0x40, // pi
        0x39, 0x05, // 1337

        0x0D, 0x00, 0x00, 0x00,
        'H',  'e', 'l',  'l',
        'o',  ',', ' ',  'w',
        'o',  'r', 'l',  'd',
        '!',

        0x04, 0x00, 0x00, 0x00,
        'A',  's',  'd',  'f',
    }, res);
    // zig fmt: on
}
