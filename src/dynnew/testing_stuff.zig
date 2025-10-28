const std = @import("std");

const Fat = @import("root.zig").Fat;
const StaticForInterface = @import("root.zig").StaticForInterface;
const StaticForConcrete = @import("root.zig").StaticForConcrete;

pub const IFoo = struct {
    pub const DynStatic = StaticForInterface(IFoo);

    pub fn foo(self: Fat(*IFoo)) void {
        // self.d(.bar, .{1337});
        _ = self;
    }

    pub const bar = fn (self: Fat(*const IFoo), v: i32) void;
};

pub const IBar = struct {
    pub const DynStatic = StaticForInterface(IBar);

    pub const baz = fn (self: Fat(IFoo), s: []const u8) void;
};

pub const Foo = struct {
    pub const DynStatic = StaticForConcrete(Foo, .{IFoo});

    pub fn bar(self: Foo, v: i32) void {
        _ = self;
        std.log.debug("{d}", .{v});
    }
};

// VVV this will likely not be implemented VVV

pub const IFooForBar = struct {
    pub const DynStatic = StaticForInterface(IFooForBar, .{IBar});

    pub fn bar(self: Fat(*const IFooForBar), v: i32) void {
        const self_baz = self.sideways_cast(IBar);

        var buf: [128]u8 = undefined;
        const no_chars = std.fmt.formatIntBuf(buf, v, 10, .lower, .{});
        const chars = buf[0..no_chars];

        self_baz.d(.baz(chars));
    }
};

pub const Bar = struct {
    pub const DynStatic = StaticForConcrete(Bar, .{ IBar, .{IFoo, IFooForBar} });

    pub fn baz(self: Fat(*const IFoo), s: []const u8) void {
        _ = self;
        std.log.debug("{s}", .{s});
    }
};
