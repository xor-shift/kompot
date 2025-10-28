const std = @import("std");

const testing_stuff = @import("testing_stuff.zig");
const util = @import("util.zig");

const Fat = @import("root.zig").Fat;
const StrippedPointer = @import("StrippedPointer.zig");

pub fn Proxied(
    comptime ProxyAs: type,
    comptime ProxyFor: type,
    comptime name: []const u8,
) type {
    const info = @typeInfo(@TypeOf(@field(ProxyFor, name))).@"fn";

    const old_first_param = info.params[0];

    if (old_first_param.is_generic) {
        @compileError("unsuitable first parameter for proxying");
    }

    if (old_first_param.is_noalias) {
        @compileError("unsuitable first parameter for proxying");
    }

    const Self = if (old_first_param.type) |Self| Self else {
        @compileError("unsuitable first parameter for proxying");
    };

    const stripped_self = StrippedPointer.fromType(Self);

    const first_param: std.builtin.Type.Fn.Param = .{
        .type = Fat((StrippedPointer{
            .type = ProxyAs,
            .kind = stripped_self.kind,
        }).Type()),
        .is_noalias = false,
        .is_generic = false,
    };

    var ret = info;
    ret.params = .{first_param} ++ info.params[1..info.params.len];
    return @Type(.{ .@"fn" = ret });
}

test Proxied {
    try std.testing.expectEqual(
        fn (Fat(testing_stuff.IFoo), i32) void,
        Proxied(testing_stuff.IFoo, testing_stuff.Foo, "bar"),
    );
}

pub fn proxied(
    comptime ProxyAs: type,
    comptime ProxyFor: type,
    comptime name: []const u8,
) Proxied(ProxyAs, ProxyFor, name) {
    const P = Proxied(ProxyAs, ProxyFor, name);
    const p = @typeInfo(P).@"fn";

    const concrete_fn = @field(ProxyFor, name);

    return switch (p.params.len) {
        1 => struct {
            pub fn aufruf(
                self: p.params[0].type.?,
            ) p.return_type.? {
                const concrete = self.get_concrete(ProxyFor);
                return @call(.auto, concrete_fn, .{concrete});
            }
        }.aufruf,
        2 => struct {
            pub fn aufruf(
                self: p.params[0].type.?,
                a0: p.params[1].type.?,
            ) p.return_type.? {
                const concrete = self.get_concrete(ProxyFor);
                return @call(.auto, concrete_fn, .{ concrete, a0 });
            }
        }.aufruf,
        3 => struct {
            pub fn aufruf(
                self: p.params[0].type.?,
                a0: p.params[1].type.?,
                a1: p.params[2].type.?,
            ) p.return_type.? {
                const concrete = self.get_concrete(ProxyFor);
                return @call(.auto, concrete_fn, .{ concrete, a0, a1 });
            }
        }.aufruf,
        // 4 => proxy4,
        // 5 => proxy5,
        // 6 => proxy6,
        // 7 => proxy7,
        // 8 => proxy8,
        else => util.fmtErr("too many arguments to proxy (have {d}, can do 8 at most)", .{p.params.len}),
    };
}

test proxied {
    const Foo = struct {
        const Self = @This();

        value: i32 = 0,

        fn foo0(_: Self) void {}

        fn foo1(_: *const Self, v: i32) i32 {
            return v;
        }

        fn foo2(self: *Self, v: i32) i32 {
            self.value += v;
            return self.value;
        }
    };

    const foo_c: Foo = .{};
    var foo_m: Foo = .{};
    foo_m = foo_m;

    const fp_foo_c_v = Fat(testing_stuff.IFoo){.this_ptr = @ptrCast(&foo_c), .vtable_ptr = undefined};
    const fp_foo_c_c = Fat(*const testing_stuff.IFoo){.this_ptr = @ptrCast(&foo_c), .vtable_ptr = undefined};

    proxied(testing_stuff.IFoo, Foo, "foo0")(fp_foo_c_v);
    try std.testing.expectEqual(123, proxied(testing_stuff.IFoo, Foo, "foo1")(fp_foo_c_c, 123));

    const fp_foo_m_m = Fat(*testing_stuff.IFoo){.this_ptr = @ptrCast(&foo_m), .vtable_ptr = undefined};

    try std.testing.expectEqual(2, proxied(testing_stuff.IFoo, Foo, "foo2")(fp_foo_m_m, 2));
    try std.testing.expectEqual(4, proxied(testing_stuff.IFoo, Foo, "foo2")(fp_foo_m_m, 2));
}
