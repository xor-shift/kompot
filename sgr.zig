const std = @import("std");

const SGR = @This();

pub const State = enum {
    Unchanged,
    Set,
    Reset,
};

pub const BaseColor = enum(u32) {
    Black = 0,
    Red = 1,
    Green = 2,
    Yellow = 3,
    Blue = 4,
    Magenta = 5,
    Cyan = 6,
    White = 7,
    Default = 9,
};

pub const Color = struct {
    bright: bool = false,
    color: BaseColor,
};

bold: State = .Unchanged,
faint: State = .Unchanged,
italic: State = .Unchanged,
underline: State = .Unchanged,
blinking: State = .Unchanged,
inverse: State = .Unchanged,
hidden: State = .Unchanged,
strikethrough: State = .Unchanged,

background: ?Color = null,
foreground: ?Color = null,

fn color_to_u32(color: Color, background: bool) u32 {
    if (color.color == .Default) {
        return if (background) 49 else 39;
    }

    const offset =
        @as(u32, if (color.bright) 90 else 30) +
        @as(u32, if (background) 10 else 0);

    return offset + @intFromEnum(color.color);
}

pub fn write_to(comptime self: SGR, writer: std.io.AnyWriter) !void {
    _ = try writer.write("\x1b[");

    const Thing = std.meta.Tuple(&.{
        u32,
        u32,
        []const u8,
    });

    const things = comptime [_]Thing{
        .{ 1, 22, "bold" },
        .{ 2, 22, "faint" },
        .{ 3, 23, "italic" },
        .{ 4, 24, "underline" },
        .{ 5, 25, "blinking" },
        .{ 7, 27, "inverse" },
        .{ 8, 28, "hidden" },
        .{ 9, 29, "strikethrough" },
    };

    var emitted_anything: bool = false;

    inline for (things) |thing| {
        const active = thing.@"0";
        const inactive = thing.@"1";
        const field_name = thing.@"2";

        const to_emit: ?u32 = blk: {
            const ret = switch (@field(self, field_name)) {
                .Unchanged => null,
                .Set => active,
                .Reset => inactive,
            };

            break :blk ret;
        };

        if (to_emit) |v| {
            if (emitted_anything) {
                try writer.writeByte(';');
            }
            emitted_anything = true;
            _ = try std.fmt.format(writer, "{d}", .{v});
        }
    }

    if (self.background) |v| {
        if (emitted_anything) {
            try writer.writeByte(';');
        }
        emitted_anything = true;
        _ = try std.fmt.format(writer, "{d}", .{color_to_u32(v, true)});
    }

    if (self.foreground) |v| {
        if (emitted_anything) {
            try writer.writeByte(';');
        }
        emitted_anything = true;
        _ = try std.fmt.format(writer, "{d}", .{color_to_u32(v, false)});
    }

    if (!emitted_anything) {
        try writer.writeByte('0');
    }
    try writer.writeByte('m');
}

fn write_sz(comptime self: SGR) usize {
    var count: usize = 0;
    var counter: std.io.GenericWriter(
        *usize,
        anyerror,
        struct {
            pub fn aufruf(v: *usize, buf: []const u8) anyerror!usize {
                v.* += buf.len;
                return buf.len;
            }
        }.aufruf,
    ) = .{
        .context = &count,
    };

    self.write_to(counter.any()) catch unreachable;

    return count;
}

pub fn to_str(comptime self: SGR) [self.write_sz()]u8 {
    var ret: [self.write_sz()]u8 = undefined;

    const Context = struct {
        ret: *[self.write_sz()]u8,
        ptr: usize = 0,
    };

    var context: Context = .{
        .ret = &ret,
    };

    var writer: std.io.GenericWriter(
        *Context,
        anyerror,
        struct {
            pub fn aufruf(v: *Context, buf: []const u8) anyerror!usize {
                @memcpy(v.ret.*[v.ptr .. v.ptr + buf.len], buf);
                v.ptr += buf.len;
                return buf.len;
            }
        }.aufruf,
    ) = .{
        .context = &context,
    };

    _ = self.write_to(writer.any()) catch unreachable;

    return ret;
}

test SGR {
    try std.testing.expectEqualStrings(
        "\x1b[0m",
        &(SGR{}).to_str(),
    );

    try std.testing.expectEqualStrings(
        "\x1b[1m",
        &(SGR{
            .bold = .Set,
        }).to_str(),
    );

    try std.testing.expectEqualStrings(
        "\x1b[22;9m",
        &(SGR{
            .bold = .Reset,
            .strikethrough = .Set,
        }).to_str(),
    );

    try std.testing.expectEqualStrings(
        "\x1b[22;9;47;92m",
        &(SGR{
            .bold = .Reset,
            .strikethrough = .Set,
            .background = .{
                .color = .White,
            },
            .foreground = .{
                .bright = true,
                .color = .Green,
            },
        }).to_str(),
    );
}

