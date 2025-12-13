const std = @import("std");

const fmt = @import("root.zig");

fn readType(comptime T: type, arg_reader: *std.io.Reader) fmt.FormatError!T {
    var buf: [@sizeOf(T)]u8 = undefined;
    arg_reader.readSliceAll(&buf) catch {
        return fmt.FormatError.FailedToReadArg;
    };
    const v: T = @bitCast(buf);
    return v;
}

const ScalarKind = enum {
    int,
    float,
};

fn convertForScalar(comptime T: type) fmt.ConversionFunction {
    const kind = switch (@typeInfo(T)) {
        .int => ScalarKind.int,
        .float => ScalarKind.float,
        else => unreachable,
    };

    return struct {
        fn aufruf(
            out_writer: *std.io.Writer,
            arg_reader: *std.io.Reader,
            options_str: []const u8,
        ) fmt.FormatError!void {
            const v = try readType(T, arg_reader);

            const options = fmt.parseBasicOptions(options_str) catch return fmt.FormatError.BadOptions;

            switch (kind) {
                .int => out_writer.printInt(v, options.mode.base().?, options.case, .{
                    .precision = null,
                    .width = options.width,
                    .alignment = options.alignment,
                    .fill = options.fill,
                }) catch return fmt.FormatError.FailedToWrite,

                .float => out_writer.printFloat(v, options) catch return fmt.FormatError.FailedToWrite,
            }
        }
    }.aufruf;
}

fn serializeForScalar(comptime T: type) fmt.SerializationFunction {
    const kind = switch (@typeInfo(T)) {
        .int => ScalarKind.int,
        .float => ScalarKind.float,
        else => unreachable,
    };

    return struct {
        fn aufruf(writer: *std.io.Writer, v: anytype) fmt.SerializationError!void {
            const U = @TypeOf(v);
            switch (kind) {
                .int => if (U != T and U != comptime_int) return fmt.SerializationError.BadType,
                .float => if (U != T and U != comptime_float) return fmt.SerializationError.BadType,
            }

            const w: T = v;
            const b: [@sizeOf(T)]u8 = @bitCast(w);

            writer.writeAll(&b) catch {
                return fmt.SerializationError.FailedToWrite;
            };
        }
    }.aufruf;
}

fn convertString(
    out_writer: *std.io.Writer,
    arg_reader: *std.io.Reader,
    options: []const u8,
) fmt.FormatError!void {
    const str_size: usize = @intCast(try readType(u32, arg_reader));

    const do_escape = std.mem.indexOfScalar(u8, options, 'e') != null;
    if (!do_escape) {
        arg_reader.streamExact(out_writer, str_size) catch |e| switch (e) {
            std.io.Reader.StreamError.ReadFailed => return fmt.FormatError.FailedToReadArg,
            std.io.Reader.StreamError.WriteFailed => return fmt.FormatError.FailedToWrite,
            std.io.Reader.StreamError.EndOfStream => return fmt.FormatError.FailedToReadArg,
        };

        return;
    }

    const escapes = [_]struct { u8, u8 }{
        .{ '\r', 'r' },
        .{ '\n', 'n' },
        .{ '\t', 't' },
        .{ '\\', '\\' },
    };

    // TODO: make this faster
    //
    // we can search for the printable range and skip
    //
    // searching is fast in vector ISAs
    outer: for (0..str_size) |_| {
        const c = arg_reader.takeByte() catch return fmt.FormatError.FailedToReadArg;

        for (escapes) |escape_pair| {
            const from = escape_pair.@"0";
            const to = escape_pair.@"1";

            if (c != from) continue;

            const arr: [2]u8 = .{ '\\', to };
            out_writer.writeAll(&arr) catch return fmt.FormatError.FailedToWrite;

            continue :outer;
        }

        if (c < ' ') {
            const c_as_hex = std.fmt.hex(c);
            const arr: [4]u8 = .{ '\\', 'x' } ++ c_as_hex;

            out_writer.writeAll(&arr) catch return fmt.FormatError.FailedToWrite;
        }

        out_writer.writeByte(c) catch return fmt.FormatError.FailedToWrite;
    }
}

fn serializeString(writer: *std.io.Writer, v: anytype) fmt.SerializationError!void {
    const T = @TypeOf(v);

    switch (@typeInfo(T)) {
        .pointer => |p| {
            const is_str = p.child == u8 and p.size == .slice;
            const is_ptr_to_str = switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            };
            if (!is_str and !is_ptr_to_str) return fmt.SerializationError.BadType;
        },
        else => return fmt.SerializationError.BadType,
    }

    const w: []const u8 = v;

    writer.writeInt(u32, @as(u32, @intCast(w.len)), .little) catch {
        return fmt.SerializationError.FailedToWrite;
    };

    writer.writeAll(w) catch {
        return fmt.SerializationError.FailedToWrite;
    };
}

fn convertBool(
    out_writer: *std.io.Writer,
    arg_reader: *std.io.Reader,
    options: []const u8,
) fmt.FormatError!void {
    _ = options;

    var val: u8 = undefined;
    arg_reader.readSliceAll((&val)[0..1]) catch |e| switch (e) {
        std.io.Reader.Error.ReadFailed => return fmt.FormatError.FailedToReadArg,
        std.io.Reader.Error.EndOfStream => return fmt.FormatError.FailedToReadArg,
    };

    out_writer.writeAll(if (val == 0) "false" else "true") catch return fmt.FormatError.FailedToWrite;
}

fn serializeBool(writer: *std.io.Writer, v: anytype) fmt.SerializationError!void {
    const T = @TypeOf(v);

    if (T != bool) return fmt.SerializationError.BadType;

    writer.writeByte(@as(u8, @intCast(@intFromBool(v)))) catch return fmt.SerializationError.FailedToWrite;
}

fn tupleForScalar(comptime T: type) fmt.ConversionTuple {
    return .{
        .conversion_specifier = @typeName(T),
        .conversion_function = convertForScalar(T),
        .serialization_function = serializeForScalar(T),
    };
}

pub const tuples = [_]fmt.ConversionTuple{
    tupleForScalar(u8),
    tupleForScalar(u16),
    tupleForScalar(u32),
    tupleForScalar(u64),
    tupleForScalar(usize),
    tupleForScalar(i8),
    tupleForScalar(i16),
    tupleForScalar(i32),
    tupleForScalar(i64),
    tupleForScalar(isize),
    tupleForScalar(f32),
    tupleForScalar(f64),
    .{
        .conversion_specifier = "s",
        .conversion_function = convertString,
        .serialization_function = serializeString,
    },
    .{
        .conversion_specifier = "bool",
        .conversion_function = convertBool,
        .serialization_function = serializeBool,
    },
};
