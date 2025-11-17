const std = @import("std");

const fmt = @import("../root.zig");

pub const FormatStrIterator = struct {
    full_str: []const u8,
    index: usize = 0,

    pub fn init(str: []const u8) FormatStrIterator {
        return .{
            .full_str = str,
        };
    }

    pub fn next(self: *FormatStrIterator) ?fmt.FormatElement {
        const view = self.full_str[self.index..];

        if (view.len == 0) return null;
        if (view.len == 1) {
            self.index += 1;
            return fmt.FormatElement{ .literal = view };
        }

        const escapes = [_]struct { []const u8, []const u8 }{
            .{ "{{", "{" },
            .{ "}}", "}" },
        };

        for (escapes) |escape_pair| {
            const if_seen, const then_emit = escape_pair;

            if (!std.mem.eql(u8, if_seen, view[0..2])) continue;

            self.index += 2;
            return fmt.FormatElement{ .literal = then_emit };
        }

        if (view[0] != '{') {
            const idx = std.mem.indexOfScalar(u8, view, '{') orelse view.len;

            self.index += idx;
            return fmt.FormatElement{ .literal = view[0..idx] };
        }

        const end_idx = std.mem.indexOfScalarPos(u8, view, 1, '}') orelse {
            self.index += view.len;
            return fmt.FormatElement{ .literal = view };
        };

        const specifier_and_options = view[1..end_idx];

        const specifier, const options = if (std.mem.indexOfScalar(u8, specifier_and_options, ':')) |split_at|
            .{ specifier_and_options[0..split_at], specifier_and_options[split_at + 1 ..] }
        else
            .{ specifier_and_options[0..], "" };

        self.index += end_idx + 1;
        return fmt.FormatElement{ .format_specifier = .{
            .conversion_specifier = specifier,
            .options = options,
        } };
    }
};

pub fn formatImpl(
    writer: *std.io.Writer,
    format_str: []const u8,
    arg_reader: *std.io.Reader,
    comptime conversion_tuples: anytype,
) fmt.FormatError!void {
    var iter: FormatStrIterator = .init(format_str);
    while (iter.next()) |elem| {
        switch (elem) {
            .literal => |literal_str| {
                writer.writeAll(literal_str) catch |e| switch (e) {
                    std.io.Writer.Error.WriteFailed => return fmt.FormatError.FailedToWrite,
                };
            },
            .format_specifier => |sno| {
                var converted: bool = false;

                inline for (conversion_tuples) |pair| {
                    if (std.mem.eql(
                        u8,
                        pair.conversion_specifier,
                        sno.conversion_specifier,
                    )) {
                        std.debug.assert(!converted);
                        converted = true;
                        try pair.conversion_function(writer, arg_reader, sno.options);
                    }
                }

                if (!converted) return fmt.FormatError.UnknownSpecifier;
            },
        }
    }
}

test formatImpl {
    var out_buffer: [128]u8 = undefined;
    var fixed_writer = std.io.Writer.fixed(&out_buffer);

    const arg_buffer = [_]u8{
        123,
        0xdb, 0x0f, 0x49, 0x40, // pi

        // 0x04, 0x00, 0x00, 0x00,
        // 0x01, 0x00, 0x00, 0x00,
        // 0x02, 0x00, 0x00, 0x00,
        // 0x03, 0x00, 0x00, 0x00,
        // 0xff, 0xff, 0xff, 0xff,

        0xEF, 0xBE, 0xAD, 0xDE,

        0x0D, 0x00, 0x00, 0x00,
        'H',  'e',  'l',  'l',
        'o',  ',',  ' ',  'w',
        'o',  'r',  'l',  'd',
        '!',
    };
    var fixed_reader = std.io.Reader.fixed(&arg_buffer);

    try formatImpl(
        &fixed_writer,
        "Value: {u8}, pi = {f32}, {u32:09X} str: {s}",
        &fixed_reader,
        fmt.builtin_conversion_tuples,
    );

    try std.testing.expectEqualSlices(
        u8,
        "Value: 123, pi = 3.1415927, 0DEADBEEF str: Hello, world!",
        fixed_writer.buffer[0..fixed_writer.end],
    );
}
