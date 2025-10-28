const std = @import("std");

const Self = @This();

pub const Kind = enum {
    /// T
    value,
    /// *T
    ptr,
    /// *const T
    const_ptr,
};

pub fn fromType(comptime T: type) Self {
    const t_info: std.builtin.Type = @typeInfo(T);
    return comptime switch (t_info) {
        .pointer => |v| {
            const U = v.child;

            return .{
                .type = U,
                .kind = if (v.is_const) .const_ptr else .ptr,
            };
        },
        else => {
            return .{
                .type = T,
                .kind = .value,
            };
        },
    };
}

pub fn Type(comptime self: Self) type {
    return switch (self.kind) {
        .value => self.type,
        .ptr => *self.type,
        .const_ptr => *const self.type,
    };
}

test Self {
    const Foo = struct {};

    try std.testing.expectEqual(Self{
        .type = Foo,
        .kind = .ptr,
    }, Self.fromType(*Foo));

    try std.testing.expectEqual(Self{
        .type = Foo,
        .kind = .const_ptr,
    }, Self.fromType(*const Foo));

    try std.testing.expectEqual(Self{
        .type = Foo,
        .kind = .value,
    }, Self.fromType(Foo));
}

type: type,
kind: Kind,
