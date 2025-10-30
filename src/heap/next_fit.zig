const std = @import("std");

const Canary = [16]u8;

pub const Config = struct {
    /// Bytes gotten from https://random.org/bytes. Change these if you will.
    canary_value: Canary = .{
        0xf1, 0x5f, 0x7b, 0xdf,
        0xb2, 0x80, 0x61, 0x1f,
        0x34, 0xaf, 0x5d, 0x90,
        0xcd, 0x6e, 0x31, 0x10,
    },

    /// Only this one is used if `decaying_free_marks` is false
    free_mark_lo: u8 = 0x40,
    free_mark_hi: u8 = 0x50,

    padding_mark_header: u8 = 0xFD,
    padding_mark_data: u8 = 0xFC,

    check_canaries: enum {
        never,
        self_on_dealloc,
        everyone_on_dealloc,
        everyone_on_alloc_and_dealloc,
    } = .self_on_dealloc,

    check_padding_marks: enum {
        never,
        self_on_dealloc,
        everyone_on_dealloc,
        everyone_on_alloc_and_dealloc,
    } = .self_on_dealloc,

    // Large performance impact
    check_free_marks: enum {
        never,
        self_on_alloc,
        everyone_on_alloc,
    } = .never,

    // HUGE performance impact
    decaying_free_marks: bool = false,
};

/// Use this allocator only if you've got nothing else. It's terrible and a
/// substitute for nothing.
pub fn NextFitAllocator(config: Config) type {
    return struct {
        const Self = @This();

        const VTable = struct {
            fn alloc(
                self_opaque: *anyopaque,
                length: usize,
                alignment: std.mem.Alignment,
                ret_addr: usize,
            ) ?[*]u8 {
                const self: *Self = @ptrCast(@alignCast(self_opaque));
                _ = ret_addr;

                return self.allocateBytes(length, alignment);
            }

            fn resize(
                self_opaque: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                ret_addr: usize,
            ) bool {
                const self: *Self = @ptrCast(@alignCast(self_opaque));
                _ = self;
                _ = memory;
                _ = alignment;
                _ = new_len;
                _ = ret_addr;

                return false;
            }

            fn remap(
                self_opaque: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                ret_addr: usize,
            ) ?[*]u8 {
                const self: *Self = @ptrCast(@alignCast(self_opaque));
                _ = self;
                _ = memory;
                _ = alignment;
                _ = new_len;
                _ = ret_addr;

                return null;
            }

            fn free(
                self_opaque: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                ret_addr: usize,
            ) void {
                const self: *Self = @ptrCast(@alignCast(self_opaque));
                _ = ret_addr;
                return self.deallocateBytes(memory, alignment);
            }
        };

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = &VTable.alloc,
            .resize = &VTable.resize,
            .remap = &VTable.remap,
            .free = &VTable.free,
        };

        pub fn init(heap: []u8) Self {
            return .{
                .heap = heap,
            };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = @ptrCast(self),
                .vtable = &Self.vtable,
            };
        }

        const Allocation = struct {
            const Header = struct {
                length: usize,
                alignment: std.mem.Alignment,

                prev: ?[*]align(@alignOf(Header)) u8 = null,
                next: ?[*]align(@alignOf(Header)) u8 = null,
            };

            const Pointers = struct {
                header_start: [*]align(@alignOf(Header)) u8,
                header_end: [*]u8,

                anterior_canary_start: [*]u8,
                anterior_canary_end: [*]u8,

                data_start: [*]u8,
                data_end: [*]u8,

                posterior_canary_start: [*]u8,
                posterior_canary_end: [*]u8,
            };

            header_ptr: [*]align(@alignOf(Header)) u8,

            fn fromDataPtr(data_ptr: [*]u8) Allocation {
                const aligned_usize = std.mem.alignBackward(
                    usize,
                    @intFromPtr(data_ptr) - @sizeOf(Header) + 1 - if (config.check_canaries != .never)
                        @sizeOf(Canary)
                    else
                        @as(usize, 0),
                    @alignOf(Header),
                );

                return .{
                    .header_ptr = @ptrFromInt(aligned_usize),
                };
            }

            fn getPointersGivenHeader(self: Allocation, header: Header) Pointers {
                const header_start = self.header_ptr;
                const header_end = header_start + @sizeOf(Header);

                const anterior_canary_start = header_end;
                const anterior_canary_end = if (config.check_canaries != .never)
                    anterior_canary_start + @sizeOf(Canary)
                else
                    anterior_canary_start;

                const data_start_offset = std.mem.alignPointerOffset(anterior_canary_end, header.alignment.toByteUnits()).?;
                const data_start = anterior_canary_end + data_start_offset;
                const data_end = data_start + header.length;

                const posterior_canary_start = data_end;
                const posterior_canary_end = if (config.check_canaries != .never)
                    posterior_canary_start + @sizeOf(Canary)
                else
                    posterior_canary_start;

                return .{
                    .header_start = header_start,
                    .header_end = header_end,

                    .anterior_canary_start = anterior_canary_start,
                    .anterior_canary_end = anterior_canary_end,

                    .data_start = data_start,
                    .data_end = data_end,

                    .posterior_canary_start = posterior_canary_start,
                    .posterior_canary_end = posterior_canary_end,
                };
            }

            fn getHeader(self: Allocation) *Header {
                return @ptrCast(self.header_ptr);
            }

            fn getPointers(self: Allocation) Pointers {
                return self.getPointersGivenHeader(self.getHeader().*);
            }

            fn getData(self: Allocation) []u8 {
                const pointers = self.getPointersGivenHeader(self.getHeader().*);
                return pointers.data_start[0..self.getHeader().length];
            }

            fn firstPtrAfter(self: Allocation) [*]u8 {
                return self.getPointersGivenHeader(self.getHeader().*).posterior_canary_end;
            }

            fn firstPtrAfterGivenHeader(self: Allocation, header: Header) [*]u8 {
                const pointers = self.getPointersGivenHeader(header);
                return pointers.anterior_canary_end;
            }

            fn getCanary(self: Allocation, kind: enum { anterior, posterior }) []u8 {
                const pointers = self.getPointers();

                const start = switch (kind) {
                    .anterior => pointers.anterior_canary_start,
                    .posterior => pointers.posterior_canary_start,
                };

                const end = switch (kind) {
                    .anterior => pointers.anterior_canary_end,
                    .posterior => pointers.posterior_canary_end,
                };

                return start[0 .. end - start];
            }

            fn setMarksAndCanaries(self: Allocation) void {
                if (config.check_canaries != .never) {
                    @memcpy(self.getCanary(.anterior), &config.canary_value);
                    @memcpy(self.getCanary(.posterior), &config.canary_value);
                }
            }

            fn checkHeaderConsistency(self: Allocation, given_data: []u8, given_alignment: std.mem.Alignment) void {
                const header = self.getHeader().*;

                if (header.length != given_data.len) @panic("data length mismatch");
                if (header.alignment != given_alignment) @panic("alignment mismatch");
            }

            fn checkCanaries(self: Allocation) void {
                const pointers = self.getPointers();

                const anterior_canary = pointers.anterior_canary_start[0 .. pointers.anterior_canary_end - pointers.anterior_canary_start];
                if (anterior_canary.len != @sizeOf(Canary)) @panic("anterior canary is smaller than expected (how?)");
                if (!std.mem.eql(u8, anterior_canary, &config.canary_value)) @panic("bad anterior canary");

                const posterior_canary = pointers.posterior_canary_start[0 .. pointers.posterior_canary_end - pointers.posterior_canary_start];
                if (posterior_canary.len != @sizeOf(Canary)) @panic("posterior canary is smaller than expected (how?)");
                if (!std.mem.eql(u8, posterior_canary, &config.canary_value)) @panic("bad posterior canary");
            }

            fn checkMarks(self: Allocation) void {
                _ = self;
            }
        };

        const Iterator = struct {
            curr: ?[*]align(@alignOf(Allocation.Header)) u8 = null,

            pub fn next(self: *Iterator) ?Allocation {
                const curr: Allocation = .{
                    .header_ptr = self.curr orelse return null,
                };
                self.curr = curr.getHeader().next;

                return curr;
            }
        };

        fn iterate(self: Self) Iterator {
            return .{
                .curr = self.first_allocation_at,
            };
        }

        fn findFit(self: Self, length: usize, alignment: std.mem.Alignment) ?struct {
            raw_allocation: Allocation,
            prev: ?Allocation,
            next: ?Allocation,
        } {
            var iterator = self.iterate();

            const maxAlignedSpace = struct {
                fn aufruf(start: [*]u8, end: [*]u8, comptime byte_alignment: usize) ?[]align(byte_alignment) u8 {
                    const offset_to_start = std.mem.alignPointerOffset(start, byte_alignment) orelse return null;
                    const header_start: [*]align(byte_alignment) u8 = @alignCast(start + offset_to_start);

                    const space = end - start;
                    const skipped = header_start - start;
                    if (skipped > space) return null;

                    return header_start[0 .. space - skipped];
                }
            }.aufruf;

            const tryFit = struct {
                fn aufruf(
                    empty_space_start: [*]u8,
                    empty_space_end: [*]u8,
                    length_: usize,
                    alignment_: std.mem.Alignment,
                ) ?Allocation {
                    const aligned_space: []align(@alignOf(Allocation.Header)) u8 = maxAlignedSpace(
                        empty_space_start,
                        empty_space_end,
                        @alignOf(Allocation.Header),
                    ) orelse return null;

                    const start: [*]align(@alignOf(Allocation.Header)) u8 = aligned_space.ptr;
                    const allocation: Allocation = .{
                        .header_ptr = start,
                    };
                    const end = allocation.firstPtrAfterGivenHeader(.{
                        .length = length_,
                        .alignment = alignment_,
                    });

                    const used_space = end - start;
                    if (used_space > aligned_space.len) return null;

                    return allocation;
                }
            }.aufruf;

            var prev = iterator.next() orelse {
                const allocation = tryFit(
                    self.heap.ptr,
                    self.heap.ptr + self.heap.len,
                    length,
                    alignment,
                ) orelse return null;

                return .{
                    .raw_allocation = allocation,
                    .prev = null,
                    .next = null,
                };
            };

            while (iterator.next()) |curr| {
                defer prev = curr;

                const allocation = tryFit(
                    prev.firstPtrAfter(),
                    curr.header_ptr,
                    length,
                    alignment,
                ) orelse continue;

                return .{
                    .raw_allocation = allocation,
                    .prev = prev,
                    .next = curr,
                };
            }

            const allocation = tryFit(
                prev.firstPtrAfter(),
                self.heap.ptr + self.heap.len,
                length,
                alignment,
            ) orelse return null;

            return .{
                .raw_allocation = allocation,
                .prev = prev,
                .next = null,
            };
        }

        pub fn allocateBytes(self: *Self, length: usize, alignment: std.mem.Alignment) ?[*]u8 {
            const fit_result = self.findFit(length, alignment) orelse return null;

            const allocation = fit_result.raw_allocation;

            if (fit_result.prev) |prev| prev.getHeader().next = allocation.header_ptr;
            if (fit_result.next) |next| next.getHeader().prev = allocation.header_ptr;

            allocation.getHeader().* = .{
                .length = length,
                .alignment = alignment,

                .prev = if (fit_result.prev) |v| v.header_ptr else null,
                .next = if (fit_result.next) |v| v.header_ptr else null,
            };
            allocation.setMarksAndCanaries();

            if (fit_result.prev == null and fit_result.next == null) {
                std.debug.assert(self.first_allocation_at == null);
                self.first_allocation_at = allocation.header_ptr;
            }

            return allocation.getData().ptr;
        }

        pub fn deallocateBytes(self: *Self, data: []u8, alignment: std.mem.Alignment) void {
            const allocation = Allocation.fromDataPtr(data.ptr);
            const header = allocation.getHeader().*;

            allocation.checkHeaderConsistency(data, alignment);
            if (!std.mem.isAligned(@intFromPtr(data.ptr), alignment.toByteUnits())) {
                @panic("bad alignment");
            }

            switch (config.check_canaries) {
                .never => {},
                .self_on_dealloc => allocation.checkCanaries(),
                .everyone_on_dealloc, .everyone_on_alloc_and_dealloc => {
                    var iterator = self.iterate();
                    while (iterator.next()) |allocation_| allocation_.checkCanaries();
                },
            }

            if (header.prev) |prev| (Allocation{ .header_ptr = prev }).getHeader().next = header.next;
            if (header.next) |next| (Allocation{ .header_ptr = next }).getHeader().prev = header.prev;

            // if header.next is null, this was the only allocation.
            if (header.prev == null) self.first_allocation_at = header.next;
        }

        pub fn debug(self: Self) void {
            const log = std.log.scoped(.nfa_debug);

            log.debug("====   nfa_debug   ====", .{});
            log.debug("  heap start      : {*}", .{self.heap.ptr});
            log.debug("  heap end        : {*} (heap start + {d})", .{ self.heap.ptr + self.heap.len, self.heap.len });
            log.debug("  first alloc at  : {*} (heap start + {?d})", .{
                self.first_allocation_at,
                if (self.first_allocation_at) |v| v - self.heap.ptr else null,
            });
            log.debug("  ====   allocations   ====", .{});

            var prev_allocation: ?Allocation = null;
            var iterator = self.iterate();

            var alloc_no: usize = 0;
            while (iterator.next()) |allocation| {
                defer prev_allocation = allocation;
                defer alloc_no += 1;

                if (prev_allocation) |prev| {
                    std.debug.assert(prev.getHeader().next == allocation.header_ptr);
                    std.debug.assert(prev.header_ptr == allocation.getHeader().prev);
                }

                const skipped_bytes = if (prev_allocation) |prev|
                    allocation.header_ptr - prev.firstPtrAfter()
                else
                    allocation.header_ptr - self.heap.ptr;

                log.debug("    ... {d} skipped bytes ...", .{skipped_bytes});
                log.debug("    ====   allocation #{:02}   ====", .{alloc_no});
                log.debug("      start      : {*}", .{allocation.header_ptr});
                log.debug("      true length: {d}", .{allocation.firstPtrAfter() - allocation.header_ptr});
                log.debug("      length     : {d}", .{allocation.getHeader().length});
                log.debug("      alignment  : {d}", .{allocation.getHeader().alignment.toByteUnits()});
                log.debug("      prev       : {*}", .{allocation.getHeader().prev});
                log.debug("      next       : {*}", .{allocation.getHeader().next});
                log.debug("    ==== allocation #{:02} end ====", .{alloc_no});
            }

            log.debug("    ... {d} more bytes ...", .{
                if (prev_allocation) |prev|
                    (self.heap.ptr + self.heap.len) - prev.firstPtrAfter()
                else
                    self.heap.len,
            });
            log.debug("  ==== allocations end ====", .{});
            log.debug("==== nfa_debug end ====", .{});
        }

        heap: []u8,

        first_allocation_at: ?[*]align(@alignOf(Allocation.Header)) u8 = null,
    };
}

test NextFitAllocator {
    var heap: [512]u8 = undefined;

    const NFA = NextFitAllocator(.{});
    var nfa: NFA = .{
        .heap = &heap,
    };

    // try std.testing.expectEqual(nfa.heap, nfa.findEmptySpace(null));
    // try std.testing.expectEqual(nfa.heap[1..], nfa.findEmptySpace(nfa.heap[1..].ptr));
    // try std.testing.expect(NFA.isFit(nfa.heap[0..], 16, .@"4") != null);

    const alloc = nfa.allocator();
    // nfa.debug();
    const foo = try alloc.alloc(u32, 4);
    // nfa.debug();
    const bar = try alloc.alloc(u32, 4);
    // nfa.debug();
    const baz = try alloc.alloc(u32, 4);
    // nfa.debug();
    alloc.free(bar);
    // nfa.debug();
    alloc.free(foo);
    // nfa.debug();
    alloc.free(baz);
    // nfa.debug();
}
