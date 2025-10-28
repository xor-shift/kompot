const std = @import("std");

pub inline fn fmtPanic(comptime fmt: []const u8, comptime args: anytype) noreturn {
    @panic(std.fmt.comptimePrint(fmt, args));
}

pub inline fn fmtErr(comptime fmt: []const u8, comptime args: anytype) noreturn {
    @compileError(std.fmt.comptimePrint(fmt, args));
}

pub inline fn fmtLog(comptime fmt: []const u8, comptime args: anytype) void {
    @compileLog(std.fmt.comptimePrint(fmt, args));
}
