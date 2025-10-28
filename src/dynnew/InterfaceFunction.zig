const std = @import("std");

const dyn = @import("root.zig");
const testing_stuff = @import("testing_stuff.zig");
const util = @import("util.zig");
const proxy = @import("proxy.zig");

const config = dyn.Config.get();

const Fat = @import("root.zig").Fat;
const StrippedPointer = @import("StrippedPointer.zig");

const Self = @This();

/// A subset of std.builtin.Type.Fn.Param
pub const Param = struct {
    type: type,
    is_noalias: bool = false,
};

pub fn fromDeclOf(
    comptime Of: type,
    comptime IFace: type,
    comptime name: [:0]const u8,
    comptime proxy_if_needed: bool,
) ?Self {
    if (!@hasDecl(Of, name)) {
        comptime if (config.log_everything) util.fmtLog(
            "VirtualFunction.fromDeclOf: type {s} has no declaration called \"{s}\"",
            .{ @typeName(Of), name },
        );
        return null;
    }

    const FnType: type, const impl: ?*const fn () void = blk: {
        const have_value = @TypeOf(@field(Of, name)) != type;

        // candidate to be a function type, not a valid function type
        const Candidate = if (!have_value)
            @field(Of, name)
        else
            @TypeOf(@field(Of, name));

        switch (@typeInfo(Candidate)) {
            .@"fn" => if (have_value) {
                break :blk .{ Candidate, @ptrCast(&@field(Of, name)) };
            } else {
                break :blk .{ Candidate, null };
            },
            else => {
                comptime if (config.log_everything) util.fmtLog(
                    "VirtualFunction.fromDeclOf: declaration \"{s}\" of {s} is not a function or a function type",
                    .{ name, @typeName(Of) },
                );
                return null;
            },
        }
    };

    const fn_info = @typeInfo(FnType).@"fn";

    if (fn_info.is_generic) {
        comptime if (config.log_everything) util.fmtLog(
            "VirtualFunction.fromDeclOf: declaration \"{s}\" of {s} declares a generic function. generic functions are not supported",
            .{ name, @typeName(Of) },
        );
        return null;
    }

    if (fn_info.is_var_args) {
        comptime if (config.log_everything) util.fmtLog(
            "VirtualFunction.fromDeclOf: declaration \"{s}\" of {s} declares a variadic function. variadic functions are not supported",
            .{ name, @typeName(Of) },
        );
        return null;
    }

    const ReturnType = if (fn_info.return_type) |v| v else {
        comptime if (config.log_everything) util.fmtLog(
            "VirtualFunction.fromDeclOf: the return type of \"{s}\" of {s} is not supported (try simpler types)",
            .{ name, @typeName(Of) },
        );
        return null;
    };

    const params = comptime blk: {
        var params: [fn_info.params.len]Param = undefined;

        for (fn_info.params, 0..) |param, i| {
            if (param.is_generic) {
                if (config.log_everything) util.fmtLog(
                    "VirtualFunction.fromDeclOf: parameter #{d} in the declaration \"{s}\" of {s} is generic. generic parameters are not supported",
                    .{ i, name, @typeName(Of) },
                );
                return null;
            }

            params[i] = .{
                .type = param.type orelse {
                    if (config.log_everything) util.fmtLog(
                        "VirtualFunction.fromDeclOf: parameter #{d} of \"{s}\" of {s} is not supported (try simpler types)",
                        .{ i, name, @typeName(Of) },
                    );
                    return null;
                },
                .is_noalias = param.is_noalias,
            };
        }

        break :blk params;
    };

    if (params.len == 0) {
        comptime if (config.log_everything) util.fmtLog(
            "VirtualFunction.fromDeclOf: \"{s}\" of {s} doesn't have a sufficient number of parameters",
            .{ name, @typeName(Of) },
        );
        return null;
    }

    const first_param_is_a_struct: bool = (switch (@typeInfo(params[0].type)) {
        .@"struct" => true,
        else => false,
    });

    const acutal_impl: ?*const fn () void, //
    const is_const: bool = switch (params[0].type) {
        Of, *Of, *const Of => blk: {
            if (!proxy_if_needed) {
                if (comptime config.log_everything) {
                    util.fmtLog("VirtualFunction.fromDeclOf: the function {s} of {s} is proxyable but proxy_if_needed was false", .{
                        name,
                        @typeName(Of),
                    });
                }

                return null;
            }

            const is_const = params[0].type == Of or params[0].type == *const Of;
            const proxied_impl = &proxy.proxied(IFace, Of, name);

            break :blk .{ @ptrCast(proxied_impl), is_const };
        },
        else => if (!first_param_is_a_struct) {
            if (comptime config.log_everything) {
                util.fmtLog("VirtualFunction.fromDeclOf: the first parameter of the function {s} of {s} is not a struct type and it wasn't proxyable", .{
                    name,
                    @typeName(Of),
                });
            }
            return null;
        } else if (@hasDecl(params[0].type, "fat_ptr_tag")) blk: {
            break :blk .{ impl, params[0].type.iface_kind != .ptr };
        } else {
            if (comptime config.log_everything) {
                util.fmtLog("VirtualFunction.fromDeclOf: the first parameter of the function {s} of {s} is not a fat pointer and it wasn't proxyable", .{
                    name,
                    @typeName(Of),
                });
            }
            return null;
        },
        // else => if (!@hasDecl(params[0].type, "fat_ptr_tag")) blk: {
        //     comptime if (config.log_everything) util.fmtLog(
        //         "VirtualFunction.fromDeclOf: the first parameter of \"{s}\" of {s} is not a fat pointer, checking if it's proxyable",
        //         .{ name, @typeName(Of) },
        //     );

        //     const stripped = StrippedPointer.fromType(params[0].type);

        //     comptime if (impl == null) {
        //         if (config.log_everything) util.fmtLog(
        //             "VirtualFunction.fromDeclOf: the function wasn't proxyable as there's no implementation",
        //             .{ name, @typeName(Of) },
        //         );
        //         return null;
        //     };

        //     if (stripped.type != Of) {
        //         comptime if (config.log_everything) util.fmtLog(
        //             "VirtualFunction.fromDeclOf: the function wasn't proxyable as the first parameter isn't a self-argument",
        //             .{ name, @typeName(Of) },
        //         );
        //         return null;
        //     }

        //     const proxied_impl = &proxy.proxied(IFace, Of, name);

        //     break :blk .{ @ptrCast(proxied_impl), stripped.kind != .ptr };
        // } else if (params[0].type.IFace != IFace) {
        //     comptime if (config.log_everything) util.fmtLog(
        //         "VirtualFunction.fromDeclOf: the first parameter of \"{s}\" of {s} is a fat pointer for {s} (expected {s})",
        //         .{
        //             name,
        //             @typeName(Of),
        //             @typeName(params[0].Iface),
        //             @typeName(Of),
        //         },
        //     );
        //     return null;
        // } else blk: {
        //     break :blk .{ impl, params[0].type.iface_kind != .ptr };
        // },
    };

    return .{
        .name = name,
        .impl = acutal_impl,

        .is_const = is_const,

        .params = params[1..],
        .return_type = ReturnType,
    };
}

pub fn isCompatibleWith(self: Self, other: Self) bool {
    return true //
    and std.mem.eql(u8, self.name, other.name) //
    and self.is_const == other.is_const //
    and self.params.len == other.params.len //
    and (for (0..self.params.len) |i| blk: {
        if (self.params[i].type != other.params[i].type)
            break :blk false;

        if (self.params[i].is_noalias != other.params[i].is_noalias)
            break :blk false;
    } else true) //
    and self.return_type == other.return_type;
}

test Self {
    const decl_foo = Self.fromDeclOf(testing_stuff.IFoo, testing_stuff.IFoo, "foo", false).?;
    try std.testing.expectEqual("foo", decl_foo.name);
    try std.testing.expectEqual(
        @as(*const fn () void, @ptrCast(&testing_stuff.IFoo.foo)),
        decl_foo.impl,
    );
    try std.testing.expectEqual(false, decl_foo.is_const);
    try std.testing.expectEqual(0, decl_foo.params.len);
    try std.testing.expectEqual(void, decl_foo.return_type);

    const decl_bar = Self.fromDeclOf(testing_stuff.IFoo, testing_stuff.IFoo, "bar", false).?;
    try std.testing.expectEqual("bar", decl_bar.name);
    try std.testing.expectEqual(null, decl_bar.impl);
    try std.testing.expectEqual(true, decl_bar.is_const);
    try std.testing.expectEqual(1, decl_bar.params.len);
    try std.testing.expectEqual(i32, decl_bar.params[0].type);
    try std.testing.expectEqual(false, decl_bar.params[0].is_noalias);
    try std.testing.expectEqual(void, decl_bar.return_type);

    // const decl_foo_concrete = Self.fromDeclOf(testing_stuff.Foo, testing_stuff.IFoo, "bar", false).?;
    // try std.testing.expectEqual("bar", decl_foo_concrete.name);
}

pub fn FunctionType(self: Self, comptime IFace: type) type {
    comptime var converted_params: [self.params.len + 1]std.builtin.Type.Fn.Param = undefined;
    converted_params[0] = std.builtin.Type.Fn.Param{
        .type = dyn.Fat(if (self.is_const) *const IFace else *IFace),
        .is_generic = false,
        .is_noalias = false,
    };

    for (self.params, 0..) |param, i| {
        converted_params[i + 1] = std.builtin.Type.Fn.Param{
            .type = param.type,
            .is_generic = false,
            .is_noalias = false,
        };
    }

    const @"fn": std.builtin.Type.Fn = .{
        .params = &converted_params,
        .is_generic = false,
        .is_var_args = false,
        .return_type = self.return_type,
        .calling_convention = .auto,
    };

    return @Type(.{ .@"fn" = @"fn" });
}

pub inline fn fromOpaque(
    self: Self,
    comptime IFace: type,
    ptr: *const fn () void,
) *const self.FunctionType(IFace) {
    return @ptrCast(ptr);
}

name: [:0]const u8,
impl: ?*const fn () void = null,

is_const: bool,

params: []const Param,
return_type: type,
