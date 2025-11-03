const std = @import("std");

pub const FormatError = error{
    UnknownSpecifier,
    FailedToReadArg,
    FailedToWrite,
    BadArgData,
};

pub const ConversionFunction = fn (
    out_writer: *std.io.Writer,
    arg_reader: *std.io.Reader,
    options: []const u8,
) FormatError!void;

pub const SerializationError = error{
    FailedToWrite,
    BadType,
};

pub const SerializationFunction = fn (
    out_writer: *std.io.Writer,
    v: anytype,
) SerializationError!void;

const ConversionTuple = struct {
    specifier: []const u8,
    convert: ConversionFunction,
    serialize: SerializationFunction,
};

pub const FormatElement = union(enum) {
    literal: []const u8,
    conversion_specifier: struct {
        specifier: []const u8,
        options: []const u8,
    },
};

const conversion_functions = struct {
    fn readType(comptime T: type, arg_reader: *std.io.Reader) FormatError!T {
        var buf: [@sizeOf(T)]u8 = undefined;
        arg_reader.readSliceAll(&buf) catch {
            return FormatError.FailedToReadArg;
        };
        const v: T = @bitCast(buf);
        return v;
    }

    const ScalarKind = enum {
        int,
        float,
    };

    fn convertForScalar(comptime T: type) ConversionFunction {
        const kind = switch (@typeInfo(T)) {
            .int => ScalarKind.int,
            .float => ScalarKind.float,
            else => unreachable,
        };

        return struct {
            fn aufruf(
                out_writer: *std.io.Writer,
                arg_reader: *std.io.Reader,
                options: []const u8,
            ) FormatError!void {
                const v = try readType(T, arg_reader);

                const base: u8, const case: std.fmt.Case = if (options.len == 1)
                    switch (options[0]) {
                        'o' => .{ 8, .lower },
                        'x' => .{ 16, .lower },
                        'X' => .{ 16, .upper },
                        else => .{ 10, .lower },
                    }
                else
                    .{ 10, .lower };

                switch (kind) {
                    .int => out_writer.printInt(v, base, case, .{}) catch return FormatError.FailedToWrite,
                    .float => out_writer.printFloat(v, .{}) catch return FormatError.FailedToWrite,
                }
            }
        }.aufruf;
    }

    fn serializeForScalar(comptime T: type) SerializationFunction {
        const kind = switch (@typeInfo(T)) {
            .int => ScalarKind.int,
            .float => ScalarKind.float,
            else => unreachable,
        };

        return struct {
            fn aufruf(writer: *std.io.Writer, v: anytype) SerializationError!void {
                const U = @TypeOf(v);
                switch (kind) {
                    .int => if (U != T and U != comptime_int) return SerializationError.BadType,
                    .float => if (U != T and U != comptime_float) return SerializationError.BadType,
                }

                const w: T = v;
                const b: [@sizeOf(T)]u8 = @bitCast(w);

                writer.writeAll(&b) catch {
                    return SerializationError.FailedToWrite;
                };
            }
        }.aufruf;
    }

    fn string(
        out_writer: *std.io.Writer,
        arg_reader: *std.io.Reader,
        options: []const u8,
    ) FormatError!void {
        _ = options;

        const str_size: usize = @intCast(try readType(u32, arg_reader));

        arg_reader.streamExact(out_writer, str_size) catch |e| switch (e) {
            std.io.Reader.StreamError.ReadFailed => return FormatError.FailedToReadArg,
            std.io.Reader.StreamError.WriteFailed => return FormatError.FailedToWrite,
            std.io.Reader.StreamError.EndOfStream => return FormatError.FailedToReadArg,
        };
    }

    fn serializeString(writer: *std.io.Writer, v: anytype) SerializationError!void {
        const T = @TypeOf(v);

        switch (@typeInfo(T)) {
            .pointer => |p| {
                const is_str = p.child == u8 and p.size == .slice;
                const is_ptr_to_str = switch (@typeInfo(p.child)) {
                    .array => |a| a.child == u8,
                    else => false,
                };
                if (!is_str and !is_ptr_to_str) return SerializationError.BadType;
            },
            else => return SerializationError.BadType,
        }

        const w: []const u8 = v;

        writer.writeInt(u32, @as(u32, @intCast(w.len)), .little) catch {
            return SerializationError.FailedToWrite;
        };

        writer.writeAll(w) catch {
            return SerializationError.FailedToWrite;
        };
    }

    fn tupleForScalar(comptime T: type) ConversionTuple {
        return .{
            .specifier = @typeName(T),
            .convert = convertForScalar(T),
            .serialize = serializeForScalar(T),
        };
    }
};

const default_pairs = [_]ConversionTuple{
    conversion_functions.tupleForScalar(u8),
    conversion_functions.tupleForScalar(u16),
    conversion_functions.tupleForScalar(u32),
    conversion_functions.tupleForScalar(u64),
    conversion_functions.tupleForScalar(usize),
    conversion_functions.tupleForScalar(i8),
    conversion_functions.tupleForScalar(i16),
    conversion_functions.tupleForScalar(i32),
    conversion_functions.tupleForScalar(i64),
    conversion_functions.tupleForScalar(isize),
    conversion_functions.tupleForScalar(f32),
    conversion_functions.tupleForScalar(f64),
    .{
        .specifier = "s",
        .convert = conversion_functions.string,
        .serialize = conversion_functions.serializeString,
    },
};

pub const FormatStrIterator = struct {
    full_str: []const u8,
    index: usize = 0,

    pub fn init(str: []const u8) FormatStrIterator {
        return .{
            .full_str = str,
        };
    }

    pub fn next(self: *FormatStrIterator) ?FormatElement {
        const view = self.full_str[self.index..];

        if (view.len == 0) return null;
        if (view.len == 1) {
            self.index += 1;
            return FormatElement{ .literal = view };
        }

        const escapes = [_]struct { []const u8, []const u8 }{
            .{ "{{", "{" },
            .{ "}}", "}" },
        };

        for (escapes) |escape_pair| {
            const if_seen, const then_emit = escape_pair;

            if (!std.mem.eql(u8, if_seen, view[0..2])) continue;

            self.index += 2;
            return FormatElement{ .literal = then_emit };
        }

        if (view[0] != '{') {
            const idx = std.mem.indexOfScalar(u8, view, '{') orelse view.len;

            self.index += idx;
            return FormatElement{ .literal = view[0..idx] };
        }

        const end_idx = std.mem.indexOfScalarPos(u8, view, 1, '}') orelse {
            self.index += view.len;
            return FormatElement{ .literal = view };
        };

        const specifier_and_options = view[1..end_idx];

        const specifier, const options = if (std.mem.indexOfScalar(u8, specifier_and_options, ':')) |split_at|
            .{ specifier_and_options[0..split_at], specifier_and_options[split_at + 1 ..] }
        else
            .{ specifier_and_options[0..], "" };

        self.index += end_idx + 1;
        return FormatElement{ .conversion_specifier = .{
            .specifier = specifier,
            .options = options,
        } };
    }
};

pub fn format(writer: *std.io.Writer, format_str: []const u8, arg_reader: *std.io.Reader) FormatError!void {
    var iter: FormatStrIterator = .init(format_str);
    while (iter.next()) |elem| {
        switch (elem) {
            .literal => |literal_str| {
                writer.writeAll(literal_str) catch |e| switch (e) {
                    std.io.Writer.Error.WriteFailed => return FormatError.FailedToWrite,
                };
            },
            .conversion_specifier => |sno| {
                var converted: bool = false;

                inline for (default_pairs) |pair| {
                    if (std.mem.eql(u8, pair.specifier, sno.specifier)) {
                        std.debug.assert(!converted);
                        converted = true;
                        try pair.convert(writer, arg_reader, sno.options);
                    }
                }

                if (!converted) return FormatError.UnknownSpecifier;
            },
        }
    }
}

test format {
    std.testing.log_level = .debug;

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

        0x0D, 0x00, 0x00, 0x00,
        'H',  'e',  'l',  'l',
        'o',  ',',  ' ',  'w',
        'o',  'r',  'l',  'd',
        '!',
    };
    var fixed_reader = std.io.Reader.fixed(&arg_buffer);

    try format(&fixed_writer, "Value: {u8}, pi = {f32}, str = {s}", &fixed_reader);

    std.log.debug("{s}", .{fixed_writer.buffer[0..fixed_writer.end]});
}

pub fn serializeArguments(writer: *std.io.Writer, format_str: []const u8, args: anytype) !void {
    var iter: FormatStrIterator = .init(format_str);

    inline for (args) |arg| {
        const specifier_for_arg = while (true) {
            const res = iter.next() orelse return error.MismatchedFormatStringAndArgs;

            const specifier = switch (res) {
                .literal => continue,
                .conversion_specifier => |sno| sno.specifier,
            };

            break specifier;
        };

        var serialized: bool = false;

        inline for (default_pairs) |pair| {
            if (std.mem.eql(u8, pair.specifier, specifier_for_arg)) {
                std.debug.assert(!serialized);
                serialized = true;
                try pair.serialize(writer, arg);
            }
        }

        if (!serialized) return FormatError.UnknownSpecifier;
    }
}

test serializeArguments {
    const alloc = std.testing.allocator;

    var writer: std.io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    try serializeArguments(&writer.writer, "{f32}, asdasd {i16}, {s}, aaaaaaaAAA {{{s}", .{
        3.1415926535,
        @as(i16, 1337),
        "Hello, world!",
        @errorName(error.Asdf),
    });

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

// std.io.Writer.Discarding has references to files
const Discarding = struct {
    count: usize,
    writer: std.io.Writer,

    pub fn init(buffer: []u8) Discarding {
        return .{
            .count = 0,
            .writer = .{
                .vtable = &.{
                    .drain = Discarding.drain,
                },
                .buffer = buffer,
            },
        };
    }

    pub fn fullCount(d: *const Discarding) usize {
        return d.count + d.writer.end;
    }

    pub fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
        const d: *Discarding = @alignCast(@fieldParentPtr("writer", w));
        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];
        var written: usize = pattern.len * splat;
        for (slice) |bytes| written += bytes.len;
        d.count += w.end + written;
        w.end = 0;
        return written;
    }
};

pub fn serializeArgumentsAlloc(alloc: std.mem.Allocator, format_str: []const u8, args: anytype) ![]const u8 {
    var counting_writer: Discarding = .init(&.{});
    try serializeArguments(&counting_writer.writer, format_str, args);
    const count: usize = @intCast(counting_writer.fullCount());

    const buf = try alloc.alloc(u8, count);
    errdefer alloc.free(buf);

    var fb_writer = std.io.Writer.fixed(buf);
    try serializeArguments(&fb_writer, format_str, args);

    return buf;
}

test serializeArgumentsAlloc {
    const alloc = std.testing.allocator;

    const res = try serializeArgumentsAlloc(alloc, "asd: {s}", .{"asd"});
    defer alloc.free(res);

    try std.testing.expectEqualSlices(u8, &.{0x03, 0x00, 0x00, 0x00, 'a', 's', 'd'}, res);
}
