const std = @import("std");

const testing_stuff = @import("testing_stuff.zig");
const util = @import("util.zig");

const InterfaceFunction = @import("InterfaceFunction.zig");

/// Returns the `Interface` for `Type` where functions of `Type` with
/// `Fat(IFace)` as the first parameter are treated as a part of the interface
/// if `proxy_if_needed` is false. if `proxy_if_needed` is true, all functions
/// where the first parameter is `Type` will be proxied by a function of the
/// aforementioned kind.
///
/// TODO: proxies via sideways casts for interface implementations through
/// interfaces. i.e. `impl T for U where U: V`, or: blanket implementations.
pub fn Interface(comptime no_functions: usize) type {
    return struct {
        const Self = @This();

        functions: [no_functions]InterfaceFunction,

        fn find(self: Self, name: []const u8) ?InterfaceFunction {
            return for (self.functions) |fun| {
                if (std.mem.eql(u8, fun.name, name)) {
                    break fun;
                }
            } else null;
        }

        pub fn extendWith(self: Self, other: anytype) Self {
            const ret = comptime blk: {
                var ret: [self.functions.len]InterfaceFunction = undefined;

                for (self.functions, 0..) |base, i| {
                    ret[i] = if (other.find(base.name)) |extended| inner: {
                        if (!base.isCompatibleWith(extended)) {
                            util.fmtErr("function \"{s}\" has conflicting declarations", .{base.name});
                        }
                        break :inner extended;
                    } else base;
                }

                break :blk ret;
            };

            return .{
                .functions = ret,
            };
        }

        fn pureVirtual() void {
            @panic("pure virtual called");
        }

        pub inline fn pointerList(self: Self) [self.functions.len]*const fn () void {
            // TODO: figure out why the compiler crashes when this function isnt inline

            const ret = comptime blk: {
                var ret: [self.functions.len]*const fn () void = undefined;

                for (self.functions, 0..) |base, i| {
                    ret[i] = base.impl orelse &pureVirtual;
                }

                break :blk ret;
            };

            return ret;
        }

        pub fn Enum(self: Self) type {
            return comptime blk: {
                var fields: [self.functions.len]std.builtin.Type.EnumField = undefined;
                for (self.functions, 0..) |v, i| {
                    fields[i].name = v.name;
                    fields[i].value = i;
                }

                break :blk @Type(std.builtin.Type{ .@"enum" = .{
                    .tag_type = usize,
                    .fields = &fields,
                    .decls = &.{},
                    .is_exhaustive = true,
                } });
            };
        }
    };
}

fn writeFunctionsOfTypeThroughIFace(
    comptime Type: type,
    comptime IFace: type,
    comptime proxy_if_needed: bool,
    comptime write_ctx: anytype,
    comptime write_fun: fn (ctx: @TypeOf(write_ctx), fun: InterfaceFunction) void,
) usize {
    const struct_info = @typeInfo(IFace).@"struct";
    const decls = comptime struct_info.decls;

    var candidates: [decls.len]?InterfaceFunction = undefined;
    for (decls, 0..) |decl, i| {
        if (std.mem.eql(u8, decl.name, "DynStatic")) {
            candidates[i] = null;
            continue;
        }

        candidates[i] = InterfaceFunction.fromDeclOf(Type, IFace, decl.name, proxy_if_needed);
    }

    // // compact the array
    // var virtuals_tmp: [candidates.len]InterfaceFunction = undefined;
    var write_head: usize = 0;
    for (candidates) |candidate| {
        if (candidate) |v| {
            write_fun(write_ctx, v);
            // virtuals_tmp[write_head] = v;
            write_head += 1;
        }
    }

    // var virtuals: [write_head]InterfaceFunction = undefined;
    // @memcpy(&virtuals, virtuals_tmp[0..write_head]);

    return write_head;
}

fn noVirtualsOfTypeThroughIFace(
    comptime Type: type,
    comptime IFace: type,
    comptime proxy_if_needed: bool,
) usize {
    const Context = struct {
        fn aufruf(ctx: @This(), fun: InterfaceFunction) void {
            _ = ctx;
            _ = fun;
        }
    };
    const context: Context = .{};

    return writeFunctionsOfTypeThroughIFace(Type, IFace, proxy_if_needed, context, Context.aufruf);
}

fn virtualsOfTypeThroughIFace(
    comptime Type: type,
    comptime IFace: type,
    comptime proxy_if_needed: bool,
) [noVirtualsOfTypeThroughIFace(Type, IFace, proxy_if_needed)]InterfaceFunction {
    const Context = struct {
        head: usize = 0,
        ret: [noVirtualsOfTypeThroughIFace(Type, IFace, proxy_if_needed)]InterfaceFunction = undefined,

        fn aufruf(ctx: *@This(), fun: InterfaceFunction) void {
            ctx.ret[ctx.head] = fun;
            ctx.head += 1;
        }
    };

    var context: Context = .{};

    _ = writeFunctionsOfTypeThroughIFace(Type, IFace, proxy_if_needed, &context, Context.aufruf);

    return context.ret;
}

pub fn ifaceForThrough(
    comptime Type: type,
    comptime IFace: type,
    comptime proxy_if_needed: bool,
) Interface(noVirtualsOfTypeThroughIFace(Type, IFace, proxy_if_needed)) {
    return .{
        .functions = virtualsOfTypeThroughIFace(Type, IFace, proxy_if_needed),
    };
}

pub fn ifaceFor(
    comptime IFace: type,
) Interface(noVirtualsOfTypeThroughIFace(IFace, IFace, false)) {
    return ifaceForThrough(IFace, IFace, false);
}

test Interface {
    const iface = ifaceFor(testing_stuff.IFoo);
    try std.testing.expectEqual(2, iface.functions.len);

    const concrete = ifaceForThrough(testing_stuff.Foo, testing_stuff.IFoo, true);

    const merged = iface.extendWith(concrete);
    // @compileLog(merged.functions[0]);
    // @compileLog(merged.functions[1]);
    // @compileLog(merged.functions[1].params[0]);

    const pointer_list = merged.pointerList();
    _ = pointer_list;

    //const Fat = @import("root.zig").Fat;

    // const bar_opaque = pointer_list[1];
    // const bar = @as(*const fn (Fat(testing_stuff.IFoo), i32) void, @ptrCast(bar_opaque));
    // bar(Fat(testing_stuff.IFoo){ .this_ptr = &concrete, .vtable_ptr = undefined }, 1337);
}

pub fn Enum(comptime IFace: type) type {
    return ifaceForThrough(IFace, IFace, false).Enum();
}
