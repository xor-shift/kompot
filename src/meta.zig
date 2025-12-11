const std = @import("std");

pub const ValueKind = enum {
    value,
    immutable_pointer,
    mutable_pointer,

    fn init(comptime Type: type) ?ValueKind {
        const type_info = @typeInfo(Type);

        return switch (type_info) {
            .pointer => |v| switch (Type) {
                *v.child => .mutable_pointer,
                *const v.child => .immutable_pointer,
                else => null,
            },
            .@"struct" => .value,
            else => null,
        };
    }
};

pub fn typeID(comptime T: type) usize {
    const S = struct {};
    _ = S;

    const Hash = switch (@bitSizeOf(usize)) {
        32 => std.hash.CityHash32,
        64 => std.hash.CityHash64,
        else => unreachable,
    };

    return Hash.hash(@typeName(T));
}

pub fn PointerWithSizeLike(
    comptime T: type,
    comptime size: std.builtin.Type.Pointer.Size,
    comptime Like: type,
) type {
    const like = @typeInfo(Like);
    if (like != .pointer) @compileError("PointerLike's `Like` argument must be a pointer type");

    var ptr = like.pointer;
    ptr.child = T;
    ptr.alignment = @alignOf(T);
    ptr.size = size;

    return @Type(.{ .pointer = ptr });
}

pub fn PointerLike(comptime T: type, comptime Like: type) type {
    return PointerWithSizeLike(T, .one, Like);
}

test PointerLike {
    try std.testing.expectEqual(*u8, PointerLike(u8, *i64));
    try std.testing.expectEqual(*i64, PointerLike(i64, *u8));
    try std.testing.expectEqual(*anyopaque, PointerLike(anyopaque, *[]const struct {}));
    try std.testing.expectEqual(*const anyopaque, PointerLike(anyopaque, *const []const struct {}));
    try std.testing.expectEqual(*const volatile anyopaque, PointerLike(anyopaque, *const volatile struct {}));
}

pub fn getOpaqueParent(field_ptr: anytype, field_offset: usize) PointerLike(anyopaque, @TypeOf(field_ptr)) {
    const Field = @TypeOf(field_ptr);
    if (@typeInfo(Field).pointer.size != .one) {
        @compileError("getOpaqueParent expects a one-pointer to a field");
    }

    const Offsetable = PointerWithSizeLike(u8, .many, Field);
    const offsetable: Offsetable = @ptrCast(field_ptr);

    return @ptrCast(offsetable - field_offset);
}

pub fn getFieldFromOffset(
    parent_ptr: anytype,
    comptime Field: type,
    field_offset: usize,
) PointerLike(Field, @TypeOf(parent_ptr)) {
    const ParentPtr = @TypeOf(parent_ptr);
    const Offsetable = PointerWithSizeLike(u8, .many, ParentPtr);
    const offsetable: Offsetable = @ptrCast(parent_ptr);

    return @ptrCast(@alignCast(offsetable + field_offset));
}

test getOpaqueParent {
    const Parent = struct {
        a: i32 = 3,
        b: u64 = 5,
        c: []const u8 = "Hello, world!",
    };

    const parent: Parent = .{};

    const recovered_parent = getOpaqueParent(&parent.b, @offsetOf(Parent, "b"));
    try std.testing.expectEqual(@as(*const anyopaque, &parent), recovered_parent);

    const c_ptr = getFieldFromOffset(recovered_parent, []const u8, @offsetOf(Parent, "c"));
    try std.testing.expectEqualSlices(u8, "Hello, world!", c_ptr.*);
}
