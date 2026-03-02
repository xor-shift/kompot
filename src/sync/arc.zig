const std = @import("std");

const kompot = @import("kompot");

pub fn Arc(comptime T: type, comptime Deleter: type) type {
    return struct {
        const Self = @This();

        const CB = struct {
            refcount: usize,
        };

        alloc: std.mem.Allocator,
        cb: *CB,

        deleter: Deleter,

        child: *T,

        pub fn init(alloc: std.mem.Allocator, v: T, deleter: Deleter) !Self {
            const cb = try alloc.create(CB);
            errdefer alloc.destroy(cb);
            cb.* = .{ .refcount = 1 };

            const child = try alloc.create(T);
            errdefer alloc.destroy(child);
            child.* = v;

            return .{
                .alloc = alloc,
                .cb = cb,
                .deleter = deleter,
                .child = child,
            };
        }

        pub fn deinit(self: Self) void {
            // ordering taken from rust's Arc
            if (@atomicRmw(usize, &self.cb.refcount, .Sub, 1, .release) != 1) {
                return;
            }

            self.alloc.destroy(self.cb);

            self.deleter.delete(self.child);
            self.alloc.destroy(self.child);
        }

        pub fn clone(self: Self) Self {
            // relaxed, ordering taken from rust's Arc
            _ = @atomicRmw(usize, &self.cb.refcount, .Add, 1, .monotonic);
            return self;
        }
    };
}

pub fn ArcTrivial(comptime T: type) type {
    return Arc(T, kompot.deleter.Trivial(T));
}

pub fn ArcSlice(comptime T: type, comptime as_const: bool) type {
    return Arc(if (as_const) []const T else []T, kompot.deleter.Slice(u8));
}
