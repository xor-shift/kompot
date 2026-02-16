const std = @import("std");

const kompot = @import("../root.zig");

const Self = @This();

const Canary = [16]u8;

const constants = struct {
    const posterior_canary: Canary = .{
        0x27, 0x98, 0x99, 0xca,
        0xf9, 0xfd, 0x27, 0x2b,
        0xb9, 0x55, 0xc1, 0x87,
        0x17, 0x91, 0x0e, 0xe7,
    };

    const anterior_canary: Canary = .{
        0xd7, 0x3c, 0xcc, 0x22,
        0x29, 0x8b, 0xf3, 0x39,
        0x19, 0xbf, 0x7f, 0x06,
        0x41, 0x69, 0xb4, 0x88,
    };

    const padding: u8 = 0x44;
    const data_fill: u8 = 0x55;
    const free_fill: u8 = 0x55;
};

const Header = struct {
    list_node: AllocationList.Node = .{},

    length: usize,
    alignment: std.mem.Alignment,
    allocated_by: usize,
    deallocated_by: usize,

    fn fromPtr(data_ptr: [*]u8) *align(1) Header {
        const header_start = data_ptr - @sizeOf(Canary) - @sizeOf(Header);
        return @ptrCast(header_start);
    }
};

const AllocationList = kompot.UnalignedDoublyLinkedList;

inner: std.mem.Allocator,

race_detector: std.atomic.Value(bool) = .init(false),
allocation_list: AllocationList = .{},

pub fn init(inner: std.mem.Allocator) Self {
    return .{
        .inner = inner,
    };
}

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

        fn resize(
            self_opaque: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self_: *Self = @ptrCast(@alignCast(self_opaque));
            return self_.vResize(memory, alignment, new_len, ret_addr);
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

/// - a "block" is an alignment-sized span in an allocation
///
/// - the "excess" is additional bytes that need to be allocated for use in
/// this wrapper
///
/// data layout:
///
/// [anterior padding][header][anterior canary]
/// [data]
/// [posterior canary]
const Sizes = struct {
    semi_anterior_size: usize,
    full_anterior_blocks: usize,
    full_anterior_size: usize,
    anterior_padding_size: usize,

    full_posterior_size: usize = @sizeOf(Canary),

    fn totalLength(self: Sizes, data_length: usize) usize {
        return self.full_anterior_size + data_length + self.full_posterior_size;
    }

    fn init(alignment: std.mem.Alignment) Sizes {
        const alignment_bytes = alignment.toByteUnits();

        const semi_anterior_size = @sizeOf(Header) + @sizeOf(Canary);
        const full_anterior_blocks = (semi_anterior_size + alignment_bytes - 1) / alignment_bytes;
        const full_anterior_size = full_anterior_blocks * alignment_bytes;
        const anterior_padding_size = full_anterior_size - semi_anterior_size;

        return .{
            .semi_anterior_size = semi_anterior_size,
            .full_anterior_blocks = full_anterior_blocks,
            .full_anterior_size = full_anterior_size,
            .anterior_padding_size = anterior_padding_size,
        };
    }
};

const Slices = struct {
    anterior_padding: []u8,
    header: []u8,
    anterior_canary: []u8,
    data: []u8,
    posterior_canary: []u8,

    fn init(
        sizes: Sizes,
        data_length: usize,
        full_data_ptr: [*]u8,
    ) Slices {
        const full_data = full_data_ptr[0..sizes.totalLength(data_length)];

        const anterior_padding = full_data[0..sizes.anterior_padding_size];
        const after_anterior_padding = full_data[anterior_padding.len..];

        const header = after_anterior_padding[0..@sizeOf(Header)];
        const after_header = after_anterior_padding[header.len..];

        const anterior_canary = after_header[0..@sizeOf(Canary)];
        const after_anterior_canary = after_header[anterior_canary.len..];

        const data = after_anterior_canary[0..data_length];
        const after_data = after_anterior_canary[data.len..];

        const posterior_canary = after_data[0..@sizeOf(Canary)];
        const after_posterior_canary = posterior_canary[posterior_canary.len..];

        std.debug.assert(after_posterior_canary.len == 0);

        return .{
            .anterior_padding = anterior_padding,
            .header = header,
            .anterior_canary = anterior_canary,
            .data = data,
            .posterior_canary = posterior_canary,
        };
    }

    fn fromHeader(header: *align(1) Header) Slices {
        const sizes: Sizes = .init(header.alignment);

        const offsetable_ptr: [*]u8 = @ptrCast(header);
        const full_data_ptr = offsetable_ptr - sizes.anterior_padding_size;

        return .init(sizes, header.length, full_data_ptr);
    }

    fn structuredHeader(self: Slices) *align(1) Header {
        std.debug.assert(self.header.len == @sizeOf(Header));
        return @ptrCast(self.header.ptr);
    }

    fn begin(self: Slices) [*]u8 {
        return self.anterior_padding.ptr;
    }
};

fn initialiseAllocation(
    comptime fill_data: bool,
    slices: Slices,
    data_length: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    @memset(slices.anterior_padding, constants.padding);
    @memcpy(slices.anterior_canary, &constants.anterior_canary);
    @memcpy(slices.posterior_canary, &constants.posterior_canary);

    const header = slices.structuredHeader();
    header.* = .{
        .length = data_length,
        .alignment = alignment,
        .allocated_by = ret_addr,
        .deallocated_by = 0,
    };

    if (fill_data) {
        @memset(slices.data, constants.data_fill);
    }
}

fn criticalStart(self: *Self) void {
    if (self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        @panic("race detected!");
    }
}

fn criticalEnd(self: *Self) void {
    self.race_detector.store(false, .release);
}

fn vAlloc(
    self: *Self,
    length: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    self.criticalStart();
    defer self.criticalEnd();

    const sizes: Sizes = .init(alignment);
    const total_length = sizes.totalLength(length);

    const full_data_ptr = self.inner.rawAlloc(total_length, alignment, ret_addr) orelse return null;
    const slices: Slices = .init(sizes, length, full_data_ptr);

    initialiseAllocation(true, slices, length, alignment, ret_addr);

    self.allocation_list.append(&slices.structuredHeader().list_node);

    return slices.data.ptr;
}

fn isAllocationOwned(self: Self, memory: []u8) bool {
    var maybe_list_node = self.allocation_list.first;
    while (true) {
        const list_node = maybe_list_node orelse break;
        defer maybe_list_node = list_node.next;

        const header: *align(1) Header = @fieldParentPtr("list_node", list_node);
        const slices: Slices = .fromHeader(header);

        if (slices.data.ptr != memory.ptr) continue;
        if (slices.data.len != memory.len) continue;

        return true;
    }

    return false;
}

fn checkAllocation(
    self: *Self,
    memory: []u8,
    alignment: std.mem.Alignment,
) void {
    const header: *align(1) Header = Header.fromPtr(memory.ptr);
    const slices: Slices = .fromHeader(header);

    if (header.deallocated_by != 0) {
        @panic("allocation is not owned by us or a double free is being made");
    }

    if (!std.mem.eql(u8, &constants.posterior_canary, slices.posterior_canary)) {
        @panic("bad posterior canary, overflow?");
    }

    if (!std.mem.eql(u8, &constants.anterior_canary, slices.anterior_canary)) {
        @panic("bad anterior canary, underflow?");
    }

    if (!self.isAllocationOwned(memory)) {
        @panic("attempted to free an allocation not made by this allocator");
    }

    if (header.length != memory.len) {
        @panic("size mismatch between the allocated and the freed memory");
    }

    if (header.alignment != alignment) {
        @panic("size mismatch between the allocated and the freed memory");
    }
}

fn vFree(
    self: *Self,
    memory: []u8,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    self.criticalStart();
    defer self.criticalEnd();

    const header: *align(1) Header = Header.fromPtr(memory.ptr);
    self.checkAllocation(memory, alignment);

    const sizes: Sizes = .init(alignment);
    const total_length = sizes.totalLength(memory.len);

    const slices: Slices = .fromHeader(header);
    const full_data = slices.begin()[0..total_length];

    header.deallocated_by = ret_addr;

    self.allocation_list.remove(&header.list_node);

    self.inner.rawFree(full_data, alignment, ret_addr);
}

fn vResize(
    self: *Self,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_length: usize,
    ret_addr: usize,
) bool {
    self.criticalStart();
    defer self.criticalEnd();

    const header: *align(1) Header = Header.fromPtr(memory.ptr);
    self.checkAllocation(memory, alignment);

    const sizes: Sizes = .init(alignment);
    const total_length = sizes.totalLength(memory.len);

    const slices: Slices = .fromHeader(header);
    const full_data = slices.begin()[0..total_length];

    const new_total_length = sizes.totalLength(new_length);

    if (!self.inner.rawResize(full_data, alignment, new_total_length, ret_addr)) {
        return false;
    }

    header.length = new_length;
}

test Self {
    const tester = @import("allocator_tester.zig");

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    var safe_gpa: Self = .{ .inner = gpa.allocator() };
    const alloc = safe_gpa.allocator();

    const context = struct {
        fn checkEmpty(alloc_: std.mem.Allocator) bool {
            const safe_gpa_: *Self = @ptrCast(@alignCast(alloc_.ptr));
            return safe_gpa_.allocation_list.isEmpty();
        }

        fn onFailure(alloc_: std.mem.Allocator) void {
            const safe_gpa_: *Self = @ptrCast(@alignCast(alloc_.ptr));

            _ = safe_gpa_;
        }
    };

    try tester.testAllocator(std.testing.allocator, alloc, context.checkEmpty, context.onFailure);
}
