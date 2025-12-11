const std = @import("std");
const kompot = @import("root.zig");

const poly = @This();

pub const VTableListEntry = union {
    // this is the leader entry
    no_vtables: usize,
    // these make up sub entries
    index: usize,
    type_id: usize,
    offset_into_parent: usize,

    pub fn getSub(leader: *const VTableListEntry, comptime For: type) ?*const VTableListEntry {
        const as_arr: [*]const VTableListEntry = @ptrCast(leader);

        const no_vtables = as_arr[0].no_vtables;

        for (0..no_vtables) |i| {
            const got_type_id = as_arr[1 + i * 3 + 1].type_id;

            if (got_type_id != kompot.meta.typeID(For)) continue;

            const ret = as_arr + (1 + i * 3);

            return @ptrCast(ret);
        }

        return null;
    }

    pub fn getLeader(sub: *const VTableListEntry) *const VTableListEntry {
        const as_arr: [*]const VTableListEntry = @ptrCast(sub);

        const idx = as_arr[0].index;
        const ret = as_arr - (idx * 3 + 1);

        return @ptrCast(ret);
    }

    pub fn getTypeID(sub: *const VTableListEntry) usize {
        const as_arr: [*]const VTableListEntry = @ptrCast(sub);

        return as_arr[1].type_id;
    }

    pub fn getOffsetIntoParent(sub: *const VTableListEntry) usize {
        const as_arr: [*]const VTableListEntry = @ptrCast(sub);

        return as_arr[2].offset_into_parent;
    }
};

pub const PtrKind = enum {
    mutable,
    immutable,
};

pub fn Fat(comptime kind: PtrKind, comptime IFace: type) type {
    return struct {
        const Self = @This();

        vtable_list: *const VTableListEntry,
        ptr: if (kind == .mutable) *IFace else *const IFace,

        pub fn init(concrete: anytype) Self {
            const ConcretePtr = @TypeOf(concrete);

            comptime std.debug.assert(@typeInfo(ConcretePtr) == .pointer);

            const type_info = @typeInfo(ConcretePtr).pointer;
            const Concrete = type_info.child;

            comptime std.debug.assert(type_info.size == .one);
            comptime std.debug.assert(!type_info.is_volatile);
            comptime std.debug.assert(type_info.alignment == @alignOf(Concrete));
            comptime std.debug.assert(type_info.address_space == .generic);
            comptime std.debug.assert(!type_info.is_allowzero);
            comptime std.debug.assert(type_info.sentinel_ptr == null);

            comptime std.debug.assert(@hasDecl(Concrete, "PolyStatic"));

            const Static = Concrete.PolyStatic;

            const sub = comptime Static.vlist[0].getSub(IFace).?;
            const initial_offset = comptime sub.getOffsetIntoParent();

            return .{
                .vtable_list = sub,
                .ptr = kompot.meta.getFieldFromOffset(concrete, IFace, initial_offset),
            };
        }

        pub fn addConst(self: Self) Fat(.immutable, IFace) {
            return .init(self.vtable, self.ptr);
        }

        pub fn getConcrete(
            self: Self,
            comptime Concrete: type,
        ) ?if (kind == .mutable) *Concrete else *const Concrete {
            const opaque_parent = kompot.meta.getOpaqueParent(self.ptr, self.vtable_list.getOffsetIntoParent());
            return @ptrCast(@alignCast(opaque_parent));
        }

        pub fn dynamicCast(self: Self, comptime IOther: type) ?Fat(kind, IOther) {
            const leader = self.vtable_list.getLeader();
            const new_sub = leader.getSub(IOther) orelse return null;

            const new_offset = new_sub.getOffsetIntoParent();
            const curr_offset = self.vtable_list.getOffsetIntoParent();

            const parent = kompot.meta.getOpaqueParent(self.ptr, curr_offset);
            const new_ptr = kompot.meta.getFieldFromOffset(parent, IOther, new_offset);

            return .{
                .vtable_list = new_sub,
                .ptr = new_ptr,
            };
        }
    };
}

pub fn StaticStuff(comptime vtable_list: []const struct { type, usize }) type {
    const vlist_ = comptime blk: {
        var vlist: [vtable_list.len * 3 + 1]VTableListEntry = undefined;

        vlist[0] = VTableListEntry{ .no_vtables = vtable_list.len };

        for (vtable_list, 0..) |entry, i| {
            const IFace = entry.@"0";
            const offset_into_parent = entry.@"1";

            vlist[1 + i * 3 + 0] = VTableListEntry{ .index = i };
            vlist[1 + i * 3 + 1] = VTableListEntry{ .type_id = kompot.meta.typeID(IFace) };
            vlist[1 + i * 3 + 2] = VTableListEntry{ .offset_into_parent = offset_into_parent };
        }

        break :blk vlist;
    };

    return struct {
        const vlist = vlist_;
    };
}

test {
    const IFoo = struct {
        const IFoo = @This();

        const VTable = struct {
            foo: *const fn (*IFoo) i32,
        };

        vtable: *const VTable,

        pub fn foo(self: *IFoo) i32 {
            return self.vtable.foo(self);
        }
    };

    const IBar = struct {
        const IBar = @This();

        const VTable = struct {
            bar: *const fn (*const IBar) i32,
        };

        vtable: *const VTable,

        pub fn bar(self: *const IBar) i32 {
            return self.vtable.bar(self);
        }
    };

    const Baz = struct {
        const Baz = @This();

        const PolyStatic = poly.StaticStuff(&.{
            .{ IFoo, @offsetOf(Baz, "foo") },
            .{ IBar, @offsetOf(Baz, "bar") },
        });

        foo: IFoo = .{
            .vtable = &IFoo.VTable{
                .foo = &Baz.vFoo,
            },
        },

        bar: IBar = .{
            .vtable = &IBar.VTable{
                .bar = &Baz.vBar,
            },
        },

        vals: [2]i32 = .{ 2, 3 },

        fn vFoo(foo: *IFoo) i32 {
            const self: *Baz = @fieldParentPtr("foo", foo);

            return self.vals[0];
        }

        fn vBar(bar: *const IBar) i32 {
            const self: *const Baz = @fieldParentPtr("bar", bar);

            return self.vals[1];
        }
    };

    var baz: Baz = .{};

    const fat_foo: poly.Fat(.mutable, IFoo) = .init(&baz);
    const foo_v = fat_foo.ptr.foo();
    try std.testing.expectEqual(2, foo_v);
    try std.testing.expectEqual(&baz, fat_foo.getConcrete(Baz));

    const fat_bar = fat_foo.dynamicCast(IBar).?;
    const bar_v = fat_bar.ptr.bar();
    try std.testing.expectEqual(3, bar_v);
    try std.testing.expectEqual(&baz, fat_bar.getConcrete(Baz));
}
