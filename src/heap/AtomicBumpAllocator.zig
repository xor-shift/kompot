const std = @import("std");

const Self = @This();

const VTable = struct {
    fn alloc(
        self_opaque: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(self_opaque));

        return self.allocateBytes(length, alignment, ret_addr);
    }

    fn free(
        self_opaque: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(self_opaque));
        return self.deallocateBytes(memory, alignment, ret_addr);
    }
};

pub fn init(heap: []u8) Self {
    return .{
        .heap = heap,
        .next_ptr = heap.ptr,
    };
}

pub fn allocator(self: *Self) std.mem.Allocator {
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

pub fn allocateBytes(
    self: *Self,
    length: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    _ = ret_addr;

    while (true) {
        const cur_next_ptr = @atomicLoad([*]u8, &self.next_ptr, .acquire);
        const aligned_forward = std.mem.alignPointer(cur_next_ptr, alignment.toByteUnits()) orelse return null;
        // ^ the space between cur_next_ptr aligned_forward will be wasted even if we can free this allocation

        const next_next_ptr = aligned_forward + length;

        const oom = blk: {
            const a: usize = @intFromPtr(next_next_ptr);
            const b: usize = @intFromPtr(self.heap.ptr + self.heap.len);
            break :blk a > b;
        };

        if (oom) return null;

        if (@cmpxchgWeak([*]u8, &self.next_ptr, cur_next_ptr, next_next_ptr, .acq_rel, .acquire) == null) {
            return aligned_forward;
        }
    }
}

pub fn deallocateBytes(self: *Self, data: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;

    const expected_next_ptr = data.ptr + data.len;
    _ = @cmpxchgStrong([*]u8, &self.next_ptr, expected_next_ptr, data.ptr, .acq_rel, .acquire);
}

heap: []u8,
next_ptr: [*]u8,

test {
    var asd: [128]u8 = undefined;
    var aba: Self = .init(&asd);
    const alloc = aba.allocator();

    _ = try alloc.alloc(u8, 1);
}
