//! {u64:016X} is a "format specifier"
//! u16 is the "conversion specifier"
//! 016X constitute the "options"
//!
//! The act of reading the bytes of the argument specified by the *format
//! specifier* and turning it into a string is referred to as *conversion*
//!
//! Conversion functions are selected based on the *conversion specifier*s.
//!
//! Taking a string consisting of literals and *format specifier*s and a stream
//! of argument bytes and turning those two into a string is referred to as
//! "formatting"
//!
//! Taking a tuple of arguments and turning it into bytes is referred to as
//! "serialization". Since all *format string*s are runtime, these tuples must
//! not contain types like `comptime_int` and the user must coerce types to
//! the corresponding *conversion specifier*s.
//!
//! This library is intended to be used alongside binary logging and provides
//! a runtime alternative to the `std.fmt` facilities while trying to follow
//! the APIs therein.
//!
//! Referring to arguments by index is not supported due to how arguments are
//! processed. This makes conversion specifiers such as `1u16` invalid. (This
//! might change in the future with certain constraints imposed)
//!
//! Arrays might get supported in the future.

const std = @import("std");

const kompot = @import("../root.zig");

pub const FormatError = error{
    UnknownSpecifier,
    FailedToReadArg,
    FailedToWrite,
    BadArgData,
    BadOptions,
};

pub const ConversionFunction = fn (
    out_writer: *std.io.Writer,
    arg_reader: *std.io.Reader,
    options: []const u8,
) FormatError!void;

pub const ConversionTuple = struct {
    conversion_specifier: []const u8,
    conversion_function: ConversionFunction,
    serialization_function: SerializationFunction,
};

pub const FormatElement = union(enum) {
    literal: []const u8,
    format_specifier: struct {
        conversion_specifier: []const u8,
        options: []const u8,
    },
};

pub const SerializationError = error{
    FailedToWrite,
    BadType,
};

pub const SerializationFunction = fn (
    out_writer: *std.io.Writer,
    v: anytype,
) SerializationError!void;

pub const builtin_conversion_tuples = @import("builtin_tuples.zig").tuples;

const util = @import("util.zig");
pub const ParseBasicOptionsError = util.ParseBasicOptionsError;
pub const parseBasicOptions = util.parseBasicOptions;

const impl_format = @import("impl/format.zig");
pub const FormatStrIterator = impl_format.FormatStrIterator;
pub const formatImpl = impl_format.formatImpl;

const impl_serialize = @import("impl/serialize.zig");
pub const serializeImpl = impl_serialize.serializeImpl;

pub fn serializeArgumentsImplAlloc(
    alloc: std.mem.Allocator,
    format_str: []const u8,
    args: anytype,
    comptime conversion_tuples: anytype,
) ![]const u8 {
    const DiscardingWriterNoFiles = kompot.DiscardingWriterNoFiles;

    var counting_writer: DiscardingWriterNoFiles = .init(&.{});
    try serializeImpl(
        &counting_writer.writer,
        format_str,
        args,
        conversion_tuples,
    );
    const count: usize = @intCast(counting_writer.fullCount());

    const buf = try alloc.alloc(u8, count);
    errdefer alloc.free(buf);

    var fb_writer = std.io.Writer.fixed(buf);
    try serializeImpl(
        &fb_writer,
        format_str,
        args,
        conversion_tuples,
    );

    return buf;
}

test serializeArgumentsImplAlloc {
    const alloc = std.testing.allocator;

    const res = try serializeArgumentsImplAlloc(alloc, "asd: {s}", .{"asd"}, builtin_conversion_tuples);
    defer alloc.free(res);

    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00, 0x00, 0x00, 'a', 's', 'd' }, res);
}

pub fn serialize(
    alloc: std.mem.Allocator,
    format_str: []const u8,
    args: anytype,
) ![]const u8 {
    return serializeArgumentsImplAlloc(alloc, format_str, args, builtin_conversion_tuples);
}

pub fn format(
    writer: *std.io.Writer,
    format_str: []const u8,
    arg_reader: *std.io.Reader,
) FormatError!void {
    return formatImpl(writer, format_str, arg_reader, builtin_conversion_tuples);
}

pub fn serializeArgumentsAlloc(
    alloc: std.mem.Allocator,
    format_str: []const u8,
    args: anytype,
) ![]const u8 {
    return serializeArgumentsImplAlloc(alloc, format_str, args, builtin_conversion_tuples);
}

test "options" {
    const test_one = struct {
        fn aufruf(fmt_str: []const u8, args: anytype, expected: []const u8) !void {
            const alloc = std.testing.allocator;

            var writer: std.io.Writer.Allocating = .init(alloc);
            defer writer.deinit();

            const args_buf = try serializeArgumentsAlloc(alloc, fmt_str, args);
            defer alloc.free(args_buf);

            var arg_reader = std.io.Reader.fixed(args_buf);

            try format(&writer.writer, fmt_str, &arg_reader);

            const res = writer.written();
            try std.testing.expectEqualSlices(u8, expected, res);
        }
    }.aufruf;

    try test_one("{u32}", .{@as(u32, 0xDEADBEEF)}, "3735928559");
    try test_one("{u32:X}", .{@as(u32, 0xDEADBEEF)}, "DEADBEEF");
    try test_one("{u32:8X}", .{@as(u32, 0xDEADBEEF)}, "DEADBEEF");
    try test_one("{u32:9X}", .{@as(u32, 0xDEADBEEF)}, " DEADBEEF");
    try test_one("{u32:09X}", .{@as(u32, 0xDEADBEEF)}, "0DEADBEEF");
    try test_one("{u32:10X}", .{@as(u32, 0xDEADBEEF)}, "  DEADBEEF");
    try test_one("{u32:0>9X}", .{@as(u32, 0xDEADBEEF)}, "0DEADBEEF");
    try test_one("{u32:0<9X}", .{@as(u32, 0xDEADBEEF)}, "DEADBEEF0");
}
