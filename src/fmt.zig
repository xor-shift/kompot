const std = @import("std");

pub const BasicSpecifier = union(enum) {
    int: struct {
        underlying: std.builtin.Type.Int,
        base: u8 = 10,
        case: std.fmt.Case = .lower,
        options: std.fmt.Options = .{},

        pub fn from(comptime T: type) @This() {
            return .{
                .underlying = @typeInfo(T).int,
            };
        }
    },
    float: struct {
        underlying: std.builtin.Type.Float,
        options: std.fmt.Number = .{},

        pub fn from(comptime T: type) @This() {
            return .{
                .underlying = @typeInfo(T).float,
            };
        }
    },
};

pub const ConversionSpecifier = struct {
    pub const Kind = enum {
        value,
        array,
    };

    kind: Kind = .value,
    basic_specifier: BasicSpecifier,

    pub const @"u8": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(u8) } };
    pub const @"u16": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(u16) } };
    pub const @"u32": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(u32) } };
    pub const @"u64": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(u64) } };
    pub const @"usize": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(usize) } };
    pub const @"i8": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(i8) } };
    pub const @"i16": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(i16) } };
    pub const @"i32": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(i32) } };
    pub const @"i64": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(i64) } };
    pub const @"isize": ConversionSpecifier = .{ .basic_specifier = .{ .int = .from(isize) } };
    pub const @"f16": ConversionSpecifier = .{ .basic_specifier = .{ .float = .from(f16) } };
    pub const @"f32": ConversionSpecifier = .{ .basic_specifier = .{ .float = .from(f32) } };
    pub const @"f64": ConversionSpecifier = .{ .basic_specifier = .{ .float = .from(f64) } };
};

pub const FormatElement = union(enum) {
    utf8_literal: []const u8,
    conversion_specifier: ConversionSpecifier,

    pub const @"u8": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(u8) } } };
    pub const @"u16": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(u16) } } };
    pub const @"u32": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(u32) } } };
    pub const @"u64": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(u64) } } };
    pub const @"usize": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(usize) } } };
    pub const @"i8": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(i8) } } };
    pub const @"i16": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(i16) } } };
    pub const @"i32": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(i32) } } };
    pub const @"i64": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(i64) } } };
    pub const @"isize": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .int = .from(isize) } } };
    pub const @"f16": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .float = .from(f16) } } };
    pub const @"f32": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .float = .from(f32) } } };
    pub const @"f64": FormatElement = .{ .conversion_specifier = .{ .basic_specifier = .{ .float = .from(f64) } } };
};

fn formatElement(writer: *std.io.Writer, elem: FormatElement, arg_reader: *std.io.Reader) !void {
    const readBasic = struct {
        fn aufruf(arg_reader_: *std.io.Reader, comptime T: type) !T {
            var buf: [@sizeOf(T)]u8 = undefined;
            try arg_reader_.readSliceAll(&buf);
            return @bitCast(buf);
        }
    }.aufruf;

    const specifier = switch (elem) {
        .utf8_literal => |v| {
            try writer.writeAll(v);
            return;
        },
        .conversion_specifier => |v| v,
    };

    const count = switch (specifier.kind) {
        .array => @as(usize, @intCast(try readBasic(arg_reader, u32))),
        .value => 1,
    };

    const bs_is_character = switch (specifier.basic_specifier) {
        .int => |v| true and v.underlying.signedness == .unsigned and v.underlying.bits == 8 and v.base == 10 and v.case == .lower,
        .float => false,
    };

    const value_is_string = specifier.kind == .array and bs_is_character;

    if (value_is_string) {
        try writer.writeByte('"');
    } else if (specifier.kind == .array) {
        try writer.writeByte('[');
    }

    // special case
    if (value_is_string) {
        try arg_reader.streamExact(writer, count);
    } else for (0..count) |i| {
        if (i != 0) try writer.writeAll(", ");
        switch (specifier.basic_specifier) {
            .int => |v| try switch (v.underlying.signedness) {
                .signed => switch (v.underlying.bits) {
                    8 => writer.printInt(try readBasic(arg_reader, i8), v.base, v.case, v.options),
                    16 => writer.printInt(try readBasic(arg_reader, i16), v.base, v.case, v.options),
                    32 => writer.printInt(try readBasic(arg_reader, i32), v.base, v.case, v.options),
                    64 => writer.printInt(try readBasic(arg_reader, i64), v.base, v.case, v.options),
                    else => @panic("unsupported integer width"),
                },
                .unsigned => switch (v.underlying.bits) {
                    8 => writer.printInt(try readBasic(arg_reader, u8), v.base, v.case, v.options),
                    16 => writer.printInt(try readBasic(arg_reader, u16), v.base, v.case, v.options),
                    32 => writer.printInt(try readBasic(arg_reader, u32), v.base, v.case, v.options),
                    64 => writer.printInt(try readBasic(arg_reader, u64), v.base, v.case, v.options),
                    else => @panic("unsupported integer width"),
                },
            },
            .float => |v| try switch (v.underlying.bits) {
                16 => writer.printFloat(try readBasic(arg_reader, f16), v.options),
                32 => writer.printFloat(try readBasic(arg_reader, f32), v.options),
                64 => writer.printFloat(try readBasic(arg_reader, f64), v.options),
                else => @panic("unsupported float width"),
            },
        }
    }

    if (value_is_string) {
        try writer.writeByte('"');
    } else if (specifier.kind == .array) {
        try writer.writeByte(']');
    }
}

pub fn format(writer: *std.io.Writer, elems: []const FormatElement, arg_reader: *std.io.Reader) !void {
    for (elems) |elem| try formatElement(writer, elem, arg_reader);
}

test format {
    var out_buffer: [128]u8 = undefined;
    var fixed_writer = std.io.Writer.fixed(&out_buffer);

    const arg_buffer = [_]u8{
        123,
    };
    var fixed_reader = std.io.Reader.fixed(&arg_buffer);

    try format(&fixed_writer, &.{
        FormatElement{ .utf8_literal = "Value: " },
        FormatElement.u8,
    }, &fixed_reader);

    std.log.debug("{s}", .{fixed_writer.buffer[0..fixed_writer.end]});
}

pub fn formatStr(writer: *std.io.Writer, format_str: []const u8, arg_stream: *std.io.Reader) !void {
    const processView = struct {
        fn aufruf(writer_: *std.io.Writer, view: []const u8, arg_stream_: *std.io.Reader, finish: bool) !enum {
            @"continue",
            consume,
            consume_again,
        } {
            if (view.len == 0) return .@"continue";

            const escapes = .{
                .{ "{{", "{" },
                .{ "}}", "}" },
            };

            inline for (escapes) |escape_pair| if (std.mem.eql(u8, view, escape_pair.@"0")) {
                try writer_.writeAll(escape_pair.@"1");
                return .consume;
            };

            if (view[0] == '{') {
                if (view[view.len - 1] != '}') {
                    return .@"continue";
                }

                const spec_str = view[1 .. view.len - 1];

                const maybe_arg_split = std.mem.indexOfScalar(u8, spec_str, ':');

                const full_spec_str = spec_str[0 .. maybe_arg_split orelse spec_str.len];
                const spec_is_array = std.mem.startsWith(u8, full_spec_str, "[]");
                const base_spec_str = if (spec_is_array) full_spec_str[2..] else full_spec_str;

                const spec_args = spec_str[maybe_arg_split orelse spec_str.len ..];

                const spec_lookup = .{
                    .{ "u8", ConversionSpecifier.u8 },
                    .{ "u16", ConversionSpecifier.u16 },
                    .{ "u32", ConversionSpecifier.u32 },
                    .{ "u64", ConversionSpecifier.u64 },
                    .{ "usize", ConversionSpecifier.usize },
                    .{ "i8", ConversionSpecifier.i8 },
                    .{ "i16", ConversionSpecifier.i16 },
                    .{ "i32", ConversionSpecifier.i32 },
                    .{ "i64", ConversionSpecifier.i64 },
                    .{ "isize", ConversionSpecifier.isize },
                    .{ "f16", ConversionSpecifier.f16 },
                    .{ "f32", ConversionSpecifier.f32 },
                    .{ "f64", ConversionSpecifier.f64 },
                };

                inline for (spec_lookup) |spec_pair| if (std.mem.eql(u8, spec_pair.@"0", base_spec_str)) {
                    const base_spec = spec_pair.@"1";

                    var spec: ConversionSpecifier = base_spec;
                    spec.kind = if (spec_is_array) ConversionSpecifier.Kind.array else .value;
                    _ = spec_args;

                    try formatElement(writer_, .{ .conversion_specifier = spec }, arg_stream_);
                };

                return .consume;
            }

            if (view[view.len - 1] == '{') {
                const lit = view[0 .. view.len - 1];
                try formatElement(writer_, .{ .utf8_literal = lit }, undefined);
                return .consume_again;
            }

            if (finish) {
                try writer_.writeAll(view);
                return .consume;
            }

            return .@"continue";
        }
    }.aufruf;

    var cur_start: usize = 0;

    for (0..format_str.len) |cur_end| {
        const cur_view = format_str[cur_start..cur_end];

        // std.log.debug("{s}", .{cur_view});
        switch (try processView(writer, cur_view, arg_stream, false)) {
            .@"continue" => {},
            .consume => cur_start = cur_end,
            .consume_again => cur_start = cur_end - 1,
        }
    }

    _ = try processView(writer, format_str[cur_start..], arg_stream, true);
}

test formatStr {
    std.testing.log_level = .debug;

    var out_buffer: [128]u8 = undefined;
    var fixed_writer = std.io.Writer.fixed(&out_buffer);

    const arg_buffer = [_]u8{
        123,
        0xdb, 0x0f, 0x49, 0x40, // pi

        0x04, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff,

        0x0D, 0x00, 0x00, 0x00,
        'H',  'e',  'l',  'l',
        'o',  ',',  ' ',  'w',
        'o',  'r',  'l',  'd',
        '!',
    };
    var fixed_reader = std.io.Reader.fixed(&arg_buffer);

    try formatStr(&fixed_writer, "Value: {u8}, pi = {f32}, arr of i32 = {[]i32}, str = {[]u8}", &fixed_reader);

    std.log.debug("{s}", .{fixed_writer.buffer[0..fixed_writer.end]});
}
