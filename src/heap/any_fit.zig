const std = @import("std");

const kompot = @import("../root.zig");

pub const strategies = struct {
    pub const FirstFit = struct {
        const Strat = @This();
    };

    pub const BestFit = struct {
        const Strat = @This();
    };
};

pub fn AnyFitAllocator(comptime Strat: type) type {
    return struct {
        const Self = @This();

        pub fn init(heap: []u8) Self {
            return .{
                .heap = heap,
            };
        }

        pub const Header = struct {
            list_node: *kompot.UnalignedDoublyLinkedList.Node,
            length: usize,
        };

        pub fn allocator(self: *Self) std.mem.Allocator {
            const VTable = struct {
                fn alloc(
                    self_opaque: *anyopaque,
                    length: usize,
                    alignment: std.mem.Alignment,
                    ret_addr: usize,
                ) ?[*]u8 {
                    const self_: *Self = @ptrCast(@alignCast(self_opaque));

                    return self_.vAlloc(length, alignment, ret_addr);
                }

                fn free(
                    self_opaque: *anyopaque,
                    memory: []u8,
                    alignment: std.mem.Alignment,
                    ret_addr: usize,
                ) void {
                    const self_: *Self = @ptrCast(@alignCast(self_opaque));
                    return self_.vFree(memory, alignment, ret_addr);
                }
            };

            return .{
                .ptr = @ptrCast(self),
                .vtable = &std.mem.Allocator.VTable{
                    .alloc = &VTable.alloc,
                    .resize = std.mem.Allocator.noResize,
                    .remap = std.mem.Allocator.noRemap,
                    .free = &VTable.free,
                },
            };
        }

        fn vAlloc(
            self: *Self,
            length: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            //
        }

        fn vFree(
            self: *Self,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) void {
            //
        }

        heap: []u8,
        allocation_list: kompot.UnalignedDoublyLinkedList = .{},
    };
}

pub const FirstFitAllocator = AnyFitAllocator(strategies.FirstFit);
pub const BestFitAllocator = AnyFitAllocator(strategies.BestFit);
