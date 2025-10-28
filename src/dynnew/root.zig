const std = @import("std");

const proxy = @import("proxy.zig");
const util = @import("util.zig");
const interface = @import("Interface.zig");

pub const InterfaceFunction = @import("InterfaceFunction.zig");
const StrippedPointer = @import("StrippedPointer.zig");

pub const Config = struct {
    /// Whether to log everything that happens. Useful for debugging or
    /// learning how this library works.
    log_everything: bool = false,

    runtime_log: bool = false,

    /// Whether to raise a compile-time error if there a concrete type
    /// implementing an interface contains a function whose name is also
    /// present in the interface but with an incompatible type.
    strict_compatibility: bool = true,

    /// Whether to include type names. If false, hashes will be stored in a
    /// deterministic manner. It might be useful to set this to `false` in
    /// release binaries to hide type names.
    use_type_names: bool = true,

    pub fn get() Config {
        if (@hasDecl(@import("root"), "dyn_config")) {
            return @import("root").dyn_config;
        } else {
            return .{};
        }
    }
};

/// `ISelf` must be like one of:
///  - `T`
///  - `*T`
///  - `*const T`
/// where `T` is equivalent to `*const T`.
/// where `T` is some concrete object that implements `ISelf`
///
/// or it must be an `InterfaceType` instance
pub fn Fat(comptime ISelf: type) type {
    const IStripped = StrippedPointer.fromType(ISelf);

    return struct {
        pub const fat_ptr_tag = {};

        pub const IFace = IStripped.type;
        pub const iface_kind = IStripped.kind;

        const Self = @This();

        this_ptr: *const anyopaque,
        vtable_ptr: [*]const VTableEntry,

        pub fn init(concrete: anytype) Self {
            const ConcretePtr = @TypeOf(concrete);

            const Concrete = switch (@typeInfo(ConcretePtr)) {
                .pointer => |v| blk: {
                    const Concrete = v.child;

                    if (v.size != .one) {
                        @compileError("can't use arrays or c-pointers to construct fat pointers.");
                    }

                    if (v.is_volatile) {
                        @compileError("can't use volatile pointers to construct fat pointers.");
                    }

                    if (v.is_allowzero) {
                        @compileError("can't use allowzero pointers to construct fat pointers.");
                    }

                    if (v.sentinel_ptr != null) {
                        @compileError("can't use pointers with sentinels to construct fat pointers.");
                    }

                    if (v.alignment != @alignOf(Concrete)) {
                        util.fmtErr("can't use pointers with unnatural alignment to construct fat pointers. the natural alignment of {s} is {d}, got a pointer with an alignment of {d}", .{
                            @typeName(Concrete),
                            @alignOf(Concrete),
                            v.alignment,
                        });
                    }

                    if (v.address_space != .generic) {
                        util.fmtErr("pointers to concrete objects must be in the generic address space. got passed a pointer in the address space \"{s}\"", .{
                            @tagName(v.address_space),
                        });
                    }

                    const iface_is_const = iface_kind != .ptr;
                    if (!iface_is_const and v.is_const) {
                        @compileError("this fat pointer is of non-const type. can't use a const-qualified pointer to a concrete object to construct it");
                    }

                    break :blk Concrete;
                },
                else => util.fmtErr("the argument to Fat({s}).init must be a pointer type (found {s})", .{
                    @typeName(ISelf),
                    @typeName(ConcretePtr),
                }),
            };

            return .{
                .this_ptr = @ptrCast(concrete),
                .vtable_ptr = vtable_utils.getVtableFor(IFace, &Concrete.DynStatic.vtable) orelse {
                    util.fmtPanic("{s} does not implement {s}", .{ @typeName(Concrete), @typeName(IFace) });
                },
            };
        }

        fn ConcreteTypeReturn(comptime RawType: type) type {
            const rts = StrippedPointer.fromType(RawType);
            if (IStripped.kind != .ptr and rts.kind == .ptr) {
                util.fmtErr("can't obtain a mutable reference from an immutable fat pointer", .{});
            }

            return switch (iface_kind) {
                .value => rts.type,
                .ptr => *rts.type,
                .const_ptr => *const rts.type,
            };
        }

        pub fn get_concrete(self: Self, comptime ConcreteType: type) ConcreteTypeReturn(ConcreteType) {
            const const_ptr: *const ConcreteType = @ptrCast(@alignCast(self.this_ptr));

            return switch (iface_kind) {
                .value => const_ptr.*,
                .ptr => @constCast(const_ptr),
                .const_ptr => const_ptr,
            };
        }

        fn indexByName(comptime function_name: [:0]const u8) usize {
            const FunEnum = interface.Enum(IFace);

            if (!@hasField(FunEnum, function_name)) {
                util.fmtErr("interface {s} has no function called \"{s}\"", .{
                    @typeName(IFace),
                    function_name,
                });
            }

            const idx = @intFromEnum(@field(FunEnum, function_name));

            return idx;
        }

        fn ReturnByIndex(comptime idx: usize) type {
            return interface.ifaceFor(IFace).functions[idx].return_type;
        }

        pub inline fn d(
            self: Self,
            comptime fun: interface.ifaceFor(IFace).Enum(),
            args: anytype,
        ) ReturnByIndex(@intFromEnum(fun)) {
            @setEvalBranchQuota(10000);
            return self.dispatchByEnum(fun, args);
        }

        pub fn dispatchByEnum(
            self: Self,
            comptime fun: interface.ifaceFor(IFace).Enum(),
            args: anytype,
        ) ReturnByIndex(@intFromEnum(fun)) {
            return self.dispatchByIdx(@intFromEnum(fun), args);
        }

        pub fn dispatchByName(
            self: Self,
            comptime function_name: [:0]const u8,
            args: anytype,
        ) ReturnByIndex(indexByName(function_name)) {
            const idx = comptime indexByName(function_name);

            return self.dispatchByIdx(idx, args);
        }

        pub fn dispatchByIdx(self: Self, comptime idx: usize, args: anytype) ReturnByIndex(idx) {
            const opaque_ptr = vtable_utils.getNthVirtual(self.vtable_ptr, idx);
            // _ = opaque_ptr;
            // _ = args;
            // return undefined;
            const ifun = interface.ifaceFor(IFace).functions[idx];
            const proper_ptr = ifun.fromOpaque(IFace, opaque_ptr);

            comptime if (ifun.params.len != args.len) {
                util.fmtErr("the function \"{s}\" of {s} expects {d} arguments, got {d}", .{
                    ifun.name,
                    @typeName(IFace),
                    ifun.params.len,
                    args.len,
                });
            };

            return @call(.auto, proper_ptr, .{self} ++ args);
        }
    };
}

test Fat {
    const testing_stuff = @import("testing_stuff.zig");
    const foo: testing_stuff.Foo = .{};
    const fat_ptr: Fat(*const testing_stuff.IFoo) = .init(&foo);
    const res = fat_ptr.dispatchByEnum(.bar, .{123});
    _ = res;
}

pub const TypeInfo = struct {
    type_name: [:0]const u8,
    type_hash: u64,

    pub fn equals(self: TypeInfo, other: TypeInfo) bool {
        const hashes_equal = self.type_hash == other.type_hash;
        const names_equal = std.mem.eql(u8, self.type_name, other.type_name);

        if (hashes_equal != names_equal) {
            @panic("what?");
        }

        return hashes_equal;
    }
};

pub const VTableEntry = union {
    no_interfaces: usize,
    no_virtuals: usize,
    offset_to_top: usize,
    type_info: *const TypeInfo,
    function: *const fn () void,
};

/// Returns a struct with a single declaration called `info` containing the
/// type info for a given type.
fn TypeInfoWrapperFor(comptime T: type) type {
    const type_name = @typeName(T);
    const type_hash = std.hash.Murmur2_64.hash(type_name);

    return struct {
        const info: TypeInfo = .{
            .type_name = if (Config.get().use_type_names) type_name else "",
            .type_hash = type_hash,
        };
    };
}

const vtable_utils = struct {
    fn getTypeInfo(any_level_ptr: [*]const VTableEntry) TypeInfo {
        return any_level_ptr[0].type_info.*;
    }

    fn getNoVirtuals(iface_level_ptr: [*]const VTableEntry) usize {
        return iface_level_ptr[1].no_virtuals;
    }

    fn getNoInterfaces(top_level_ptr: [*]const VTableEntry) usize {
        return top_level_ptr[1].no_interfaces;
    }

    fn getNthVirtual(iface_level_ptr: [*]const VTableEntry, n: usize) *const fn () void {
        return iface_level_ptr[3 + n].function;
    }

    fn getVtableFor(comptime IFor: type, top_level_ptr: [*]const VTableEntry) ?[*]const VTableEntry {
        const no_interfaces = getNoInterfaces(top_level_ptr);

        const desired_type_info = TypeInfoWrapperFor(IFor).info;

        if (comptime Config.get().runtime_log) {
            std.log.debug("getVtableFor call on {*} for the interface {s} (looking for hash {X:016})", .{
                top_level_ptr,
                @typeName(IFor),
                desired_type_info.type_hash,
            });
        }

        var cur_ptr = top_level_ptr + 2;
        for (0..no_interfaces) |iface_no| {
            const type_info = getTypeInfo(cur_ptr);

            if (comptime Config.get().runtime_log) {
                std.log.debug("interface #{d} ({s}) has a hash of {X:016} ({s} a match)", .{
                    iface_no,
                    type_info.type_name,
                    type_info.type_hash,
                    if (type_info.equals(desired_type_info)) "got" else "not",
                });
            }

            const found = type_info.equals(desired_type_info);
            if (found) return cur_ptr;

            cur_ptr += 3 + cur_ptr[2].no_virtuals;
        }

        return null;
    }
};

test vtable_utils {
    const testing_stuff = @import("testing_stuff.zig");
    _ = vtable_utils.getVtableFor(testing_stuff.IFoo, &testing_stuff.Foo.DynStatic.vtable);
}

pub fn StaticForConcrete(comptime Concrete: type, comptime interfaces: anytype) type {
    @setEvalBranchQuota(10000);
    const vtable_ = comptime blk: {
        // const no_function_pointers = blk2: {
        //     var sum: usize = 0;
        //     for (interfaces) |IFace| sum += Interface.init(IFace).functions.len;
        //     break :blk2 sum;
        // };

        // TypeInfo for Concrete
        // no_interfaces for Concrete
        //
        // TypeInfo for IFace0
        // offset_to_top for IFace0
        // no_virtuals for IFace0
        // pointer 0 for IFace0
        // ...
        // pointer n_0 for IFace0
        //
        // ...
        //
        // TypeInfo for IFaceM
        // offset_to_top for IFaceM
        // no_virtuals for IFaceM
        // pointer 0 for IFaceM
        // ...
        // pointer m_0 for IFaceM

        var blocks: [1 + interfaces.len][]const VTableEntry = undefined;
        blocks[0] = &.{
            VTableEntry{ .type_info = &TypeInfoWrapperFor(Concrete).info },
            VTableEntry{ .no_interfaces = interfaces.len },
        };

        for (interfaces, 0..) |IFace, i| {
            const offset_to_top = blk2: {
                var sum: usize = 0;
                for (blocks[0 .. i + 1]) |block| sum += block.len;
                break :blk2 sum;
            };

            const pointer_entries = blk2: {
                const concrete_for_iface = interface.ifaceForThrough(Concrete, IFace, true);
                const combined = interface.ifaceFor(IFace).extendWith(concrete_for_iface);
                const ptrs = combined.pointerList();

                var pointer_entries: [ptrs.len]VTableEntry = undefined;
                for (ptrs, 0..) |v, j| {
                    pointer_entries[j] = .{ .function = v };
                }

                break :blk2 pointer_entries;
            };

            const base = .{
                VTableEntry{ .type_info = &TypeInfoWrapperFor(IFace).info },
                VTableEntry{ .offset_to_top = offset_to_top },
                VTableEntry{ .no_virtuals = pointer_entries.len },
            };

            blocks[i + 1] = &(base ++ pointer_entries);
        }

        const no_entries = blk2: {
            var sum: usize = 0;
            for (blocks) |block| sum += block.len;
            break :blk2 sum;
        };

        var ctr: usize = 0;
        var combined: [no_entries]VTableEntry = undefined;
        for (blocks) |block| {
            @memcpy(combined[ctr .. ctr + block.len], block);
            ctr += block.len;
        }

        break :blk combined;
    };

    return struct {
        const vtable = vtable_;
    };
}

/// Serves no purpose yet but you should be putting this in interfaces regardless.
pub fn StaticForInterface(comptime IFace: type) type {
    return struct {
        const type_info: TypeInfo = .{
            .name = @typeName(IFace),
            .no_virtuals = interface.ifaceFor(IFace).functions.len,
        };
    };
}

test {
    std.testing.refAllDecls(proxy);

    std.testing.refAllDecls(interface);
    std.testing.refAllDecls(InterfaceFunction);
    std.testing.refAllDecls(StrippedPointer);
}
