const std = @import("std");

const Canary = [16]u8;

const util = struct {
    // Returns the space available between `start` and `end` (`end` not
    // inclusive) after aligning to `byte_alignmnt` as a slice.
    fn spaceAfterAlignment(
        start: [*]u8,
        end: [*]u8,
        comptime byte_alignment: usize,
    ) ?[]align(byte_alignment) u8 {
        const offset_to_start = std.mem.alignPointerOffset(start, byte_alignment) orelse return null;
        const header_start: [*]align(byte_alignment) u8 = @alignCast(start + offset_to_start);

        const space = end - start;
        const skipped = header_start - start;
        if (skipped > space) return null;

        return header_start[0 .. space - skipped];
    }

    test spaceAfterAlignment {
        var asd: [256]u8 align(16) = undefined;
        const start = asd[0..].ptr;
        const end = asd[0..].ptr + asd.len;

        try std.testing.expectEqual(asd[0..], spaceAfterAlignment(start, end, 1));
        try std.testing.expectEqual(asd[0..], spaceAfterAlignment(start, end, 2));
        try std.testing.expectEqual(asd[0..], spaceAfterAlignment(start, end, 16));

        try std.testing.expectEqual(asd[1..], spaceAfterAlignment(start + 1, end, 1));
        try std.testing.expectEqual(asd[2..], spaceAfterAlignment(start + 1, end, 2));
        try std.testing.expectEqual(asd[16..], spaceAfterAlignment(start + 1, end, 16));

        try std.testing.expectEqual(asd[15..], spaceAfterAlignment(start + 15, end, 1));
        try std.testing.expectEqual(asd[16..], spaceAfterAlignment(start + 15, end, 2));
        try std.testing.expectEqual(asd[16..], spaceAfterAlignment(start + 15, end, 16));
    }
};

pub const Config = struct {
    /// Bytes gotten from https://random.org/bytes. Change these if you will.
    canary_value: Canary = .{
        0xf1, 0x5f, 0x7b, 0xdf,
        0xb2, 0x80, 0x61, 0x1f,
        0x34, 0xaf, 0x5d, 0x90,
        0xcd, 0x6e, 0x31, 0x10,
    },

    free_mark: u8 = 0x41,

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

        pub fn init(heap: []u8) Self {
            return .{
                .heap = heap,
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

        pub fn allocationInfo(self: Self, ptr: *const anyopaque) ?struct {
            length: usize,
            alignment: std.mem.Alignment,
        } {
            _ = self;

            const allocation: Allocation = .fromDataPtr(@ptrCast(@constCast(ptr)));
            const header = allocation.getHeader();

            return .{
                .length = header.length,
                .alignment = header.alignment,
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
                return pointers.posterior_canary_end;
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

        pub const Statistics = struct {
            num_active_allocations: usize,
            num_free_regions: usize,
            largest_free_region: usize,

            bytes_data: usize,
            bytes_total: usize,
            bytes_free_upto_last_alloc: usize,
            bytes_free_after_last_alloc: usize,
        };

        pub fn stats(self: Self) Statistics {
            var ret = std.mem.zeroes(Statistics);

            var iter = self.iterate();
            var maybe_prev_allocation: ?Allocation = null;
            while (iter.next()) |allocation| {
                defer maybe_prev_allocation = allocation;

                const ptrs = allocation.getPointers();

                if (maybe_prev_allocation) |prev_allocation| {
                    const free_bytes_before = allocation.header_ptr - prev_allocation.firstPtrAfter();

                    ret.num_free_regions += 1;
                    ret.bytes_free_upto_last_alloc += free_bytes_before;
                    ret.largest_free_region = @max(ret.largest_free_region, free_bytes_before);
                } else if (allocation.header_ptr != self.heap.ptr) {
                    const free_bytes_before = allocation.header_ptr - self.heap.ptr;

                    ret.num_free_regions += 1;
                    ret.bytes_free_upto_last_alloc += free_bytes_before;
                    ret.largest_free_region = @max(ret.largest_free_region, free_bytes_before);
                }

                ret.num_active_allocations += 1;

                ret.bytes_data += ptrs.data_end - ptrs.data_start;
                ret.bytes_total += ptrs.posterior_canary_end - ptrs.header_start;
            }

            ret.bytes_free_after_last_alloc = if (maybe_prev_allocation) |last_allocation|
                self.heap.ptr + self.heap.len - last_allocation.firstPtrAfter()
            else
                self.heap.len;

            return ret;
        }

        fn findFit(self: Self, length: usize, alignment: std.mem.Alignment) ?struct {
            raw_allocation: Allocation,
            prev: ?Allocation,
            next: ?Allocation,
        } {
            var iterator = self.iterate();

            const tryFit = struct {
                fn aufruf(
                    empty_space_start: [*]u8,
                    empty_space_end: [*]u8,
                    length_: usize,
                    alignment_: std.mem.Alignment,
                ) ?Allocation {
                    const aligned_space: []align(@alignOf(Allocation.Header)) u8 = util.spaceAfterAlignment(
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

                    const space_that_would_be_used_by_allocation_had_we_used_the_candidate = end - start;
                    const the_space_that_we_actually_have_available_after_alignment = aligned_space.len;

                    const subjunctive = space_that_would_be_used_by_allocation_had_we_used_the_candidate;
                    const indicative = the_space_that_we_actually_have_available_after_alignment;

                    // std.log.debug("length_: {}, indicative: {}, subjunctive: {}", .{
                    //     length_,
                    //     indicative,
                    //     subjunctive,
                    // });

                    if (subjunctive > indicative) return null;

                    // std.log.debug("asd", .{});

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

                // std.log.debug("asdf", .{});

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
            std.debug.assert(self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
            defer self.race_detector.store(false, .release);

            const fit_result = self.findFit(length, alignment) orelse return null;

            const allocation = fit_result.raw_allocation;

            if (fit_result.prev) |prev| {
                if (fit_result.next) |next| {
                    std.debug.assert(prev.getHeader().next == next.header_ptr);
                    std.debug.assert(next.getHeader().prev == prev.header_ptr);

                    // const after_prev = prev.firstPtrAfter();
                    // const space = next.getPointers().posterior_canary_start - after_prev;
                    // std.log.debug("have {}, need {}", .{ space, length });
                }
            }

            if (fit_result.prev) |prev| prev.getHeader().next = allocation.header_ptr;
            if (fit_result.next) |next| next.getHeader().prev = allocation.header_ptr;

            // if (fit_result.prev) |prev| {
            //     std.log.debug("prev allocation: {*}", .{prev.getPointers().header_start});
            //     std.log.debug("prev.next      : {*}", .{prev.getHeader().next});
            // } else std.log.debug("no prev allocation", .{});

            // if (fit_result.next) |next| {
            //     std.log.debug("next allocation: {*}", .{next.getPointers().header_start});
            //     std.log.debug("next.prev      : {*}", .{next.getHeader().prev});
            // } else std.log.debug("no next allocation", .{});

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

        pub fn deallocateBytesImpl(self: *Self, data: [*]u8, maybe_check_info: ?struct {
            length: usize,
            alignment: std.mem.Alignment,
        }) void {
            std.debug.assert(self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
            defer self.race_detector.store(false, .release);

            const allocation = Allocation.fromDataPtr(data);
            const header = allocation.getHeader().*;

            if (maybe_check_info) |check_info| {
                allocation.checkHeaderConsistency(data[0..check_info.length], check_info.alignment);

                if (!std.mem.isAligned(@intFromPtr(data), check_info.alignment.toByteUnits())) {
                    @panic("bad alignment");
                }
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

        pub fn deallocateBytes(self: *Self, data: []u8, alignment: std.mem.Alignment) void {
            self.deallocateBytesImpl(data.ptr, .{
                .length = data.len,
                .alignment = alignment,
            });
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

                const skipped_bytes = if (prev_allocation) |prev|
                    allocation.header_ptr - prev.firstPtrAfter()
                else
                    allocation.header_ptr - self.heap.ptr;

                const pointers = allocation.getPointers();

                log.debug("    ... {d} skipped bytes ...", .{skipped_bytes});
                log.debug("    ====   allocation #{:02}   ====", .{alloc_no});
                log.debug("      ====   pointers   ====", .{});
                log.debug("        header_start          : {*}", .{pointers.header_start});
                log.debug("        header_end            : {*}", .{pointers.header_end});
                log.debug("        anterior_canary_start : {*}", .{pointers.anterior_canary_start});
                log.debug("        anterior_canary_end   : {*}", .{pointers.anterior_canary_end});
                log.debug("        data_start            : {*}", .{pointers.data_start});
                log.debug("        data_end              : {*}", .{pointers.data_end});
                log.debug("        posterior_canary_start: {*}", .{pointers.posterior_canary_start});
                log.debug("        posterior_canary_end  : {*}", .{pointers.posterior_canary_end});
                log.debug("      ==== pointers end ====", .{});
                log.debug("      start      : {*}", .{allocation.header_ptr});
                log.debug("      true length: {d}", .{allocation.firstPtrAfter() - allocation.header_ptr});
                log.debug("      length     : {d}", .{allocation.getHeader().length});
                log.debug("      alignment  : {d}", .{allocation.getHeader().alignment.toByteUnits()});
                log.debug("      prev       : {*}", .{allocation.getHeader().prev});
                log.debug("      next       : {*}", .{allocation.getHeader().next});
                log.debug("    ==== allocation #{:02} end ====", .{alloc_no});

                if (prev_allocation) |prev| {
                    std.debug.assert(prev.getHeader().next == allocation.header_ptr);
                    std.debug.assert(prev.header_ptr == allocation.getHeader().prev);
                }
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

        race_detector: std.atomic.Value(bool) = .init(false),

        heap: []u8,
        first_allocation_at: ?[*]align(@alignOf(Allocation.Header)) u8 = null,
    };
}

test NextFitAllocator {
    const heap = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(heap);

    const NFA = NextFitAllocator(.{});
    var nfa: NFA = .{
        .heap = heap,
    };

    // try std.testing.expectEqual(nfa.heap, nfa.findEmptySpace(null));
    // try std.testing.expectEqual(nfa.heap[1..], nfa.findEmptySpace(nfa.heap[1..].ptr));
    // try std.testing.expect(NFA.isFit(nfa.heap[0..], 16, .@"4") != null);

    const alloc = nfa.allocator();

    // nfa.debug();
    const foo = try alloc.alloc(u8, 127);
    // nfa.debug();
    const bar = try alloc.alloc(u8, 127);
    // nfa.debug();
    const baz = try alloc.alloc(u8, 127);
    // nfa.debug();
    alloc.free(bar);
    // nfa.debug();
    const qux = try alloc.alloc(u8, 256);
    // nfa.debug();
    alloc.free(foo);
    // nfa.debug();
    alloc.free(baz);
    // nfa.debug();
    alloc.free(qux);
    // nfa.debug();

    try std.testing.expectEqual(0, nfa.stats().num_active_allocations);
    try std.testing.expectEqual(0, nfa.stats().bytes_data);
    try std.testing.expectEqual(0, nfa.stats().bytes_total);
    // try std.testing.expectEqual(0, nfa.stats().bytes_free_upto_last_alloc);
    // try std.testing.expectEqual(0, nfa.stats().bytes_free_after_last_alloc);
}

test "known failure condition for NextFitAllocator" {
    var heap: [2048]u8 align(16) = undefined;

    const NFA = NextFitAllocator(.{});
    var nfa: NFA = .{
        .heap = &heap,
    };

    const alloc = nfa.allocator();

    var allocations: [3][]u8 = .{
        try alloc.alloc(u8, 127),
        try alloc.alloc(u8, 127),
        try alloc.alloc(u8, 127),
    };

    alloc.free(allocations[1]);
    allocations[1] = try alloc.alloc(u8, 256);

    // nfa.debug();
    alloc.free(allocations[2]);
    // nfa.debug();

    allocations[2] = try alloc.alloc(u8, 256);
}

test "stress test of NextFitAllocator" {
    const heap = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(heap);

    const NFA = NextFitAllocator(.{});
    var nfa: NFA = .{
        .heap = heap,
    };

    const alloc = nfa.allocator();

    var test_allocations: [1024][]u8 = undefined;
    for (0..test_allocations.len) |i| test_allocations[i] = try alloc.alloc(u8, 1);

    var xoshiro = std.Random.Xoshiro256.init(@intCast(std.testing.random_seed));
    const random = xoshiro.random();

    for (0..test_allocations.len / 2) |_| {
        const i = random.intRangeLessThan(usize, 0, test_allocations.len);
        const l = random.intRangeLessThan(usize, 128, 255);
        // const l = 255;

        alloc.free(test_allocations[i]);
        test_allocations[i] = try alloc.alloc(u8, l);
    }
}
