const std = @import("std");

const kompot = @import("../root.zig");

pub const strategy = struct {
    pub const CandidateAllocation = struct {
        free_block_length: usize,

        /// private data
        header_ptr: [*]u8,

        /// private data
        prev_ptr: ?[*]u8,

        /// private data
        next_ptr: ?[*]u8,
    };

    pub const Consideration = enum {
        hollup,
        ok_im_done,
    };
};

pub const strategies = struct {
    pub const FirstFit = struct {
        const Strat = @This();

        candidate: ?strategy.CandidateAllocation = null,

        pub fn consider(self: *Strat, candidate: strategy.CandidateAllocation) strategy.Consideration {
            std.debug.assert(self.candidate == null);
            self.candidate = candidate;

            return .ok_im_done;
        }

        pub fn chosenCandidate(self: *Strat) strategy.CandidateAllocation {
            return self.candidate.?;
        }
    };

    pub const BestFit = struct {
        const Strat = @This();

        candidate: ?strategy.CandidateAllocation = null,

        pub fn consider(self: *Strat, candidate: strategy.CandidateAllocation) strategy.Consideration {
            const old_condidate = self.candidate orelse {
                self.candidate = candidate;
                return .hollup;
            };

            if (candidate.free_block_length < old_condidate.free_block_length) {
                self.candidate = candidate;
            }

            return .hollup;
        }

        pub fn chosenCandidate(self: *Strat) strategy.CandidateAllocation {
            return self.candidate.?;
        }
    };
};

pub fn AnyFitAllocator(comptime Strat: type) type {
    const util = struct {
        fn byteSplat(comptime T: type, v: u8) T {
            var ret: [@sizeOf(T)]u8 = .{0} ** @sizeOf(T);
            @memset(&ret, v);
            return @bitCast(ret);
        }

        fn mkSlice(start: [*]u8, end: [*]u8) []u8 {
            return start[0 .. @intFromPtr(end) - @intFromPtr(start)];
        }

        pub fn rangeContains(range: []u8, ptr: [*]u8) bool {
            const start = @intFromPtr(range.ptr);
            const end = @intFromPtr(range.ptr + range.len);

            const p = @intFromPtr(ptr);

            return p >= start and p < end;
        }
    };

    const play_it_safe: bool = switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => true,
        else => false,
    };

    return struct {
        const Self = @This();

        pub const Statistics = struct {
            num_allocations: usize,
            used_bytes: usize,
            overhead_bytes: usize,

            /// this field is an indicator of fragmentation
            ///
            /// [0] is the number of free spots smaller than or equal to 4 bytes
            ///
            /// [1] is the number of free spots between 5 and 8 bytes
            ///
            /// [2] is the number of free spots between 9 and 16 bytes
            ///
            /// [n] is the number of free spots between (4 * 2 ^ (n - 1) + 1) and (4 * 2 ^ n) bytes
            free_spot_stats: [8]usize,
        };

        const Header = struct {
            prev: ?[*]u8,
            next: ?[*]u8,
            length: usize,
        };

        pub fn init(heap: []u8) Self {
            if (play_it_safe) {
                @memset(heap, 0x55);
            }

            return .{
                .heap = heap,
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

        const FreelistIterator = struct {
            const Elem = struct {
                prev: ?[*]u8,
                next: ?[*]u8,
                space: []u8,
            };

            free_space_start: [*]u8,
            maybe_prev_allocation_at: ?[*]u8 = null,
            maybe_next_allocation_at: ?[*]u8,
            end: [*]u8,

            pub fn next(self: *FreelistIterator) ?Elem {
                const next_allocation_at = self.maybe_next_allocation_at orelse {
                    const space_at_the_end = util.mkSlice(self.free_space_start, self.end);
                    if (space_at_the_end.len == 0) return null;

                    defer self.free_space_start = self.end;

                    return .{
                        .prev = self.maybe_prev_allocation_at,
                        .next = null,
                        .space = space_at_the_end,
                    };
                };

                const next_allocation_header: *align(1) Header = @ptrCast(next_allocation_at);
                const next_allocation_total_space = @sizeOf(Header) + next_allocation_header.length;
                const next_free_space_start = next_allocation_at + next_allocation_total_space;

                const space = util.mkSlice(self.free_space_start, next_allocation_at);
                const ret: Elem = .{
                    .prev = self.maybe_prev_allocation_at,
                    .next = next_allocation_at,
                    .space = space,
                };

                self.free_space_start = next_free_space_start;
                self.maybe_prev_allocation_at = next_allocation_at;
                self.maybe_next_allocation_at = next_allocation_header.next;

                if (space.len == 0) return self.next();
                return ret;
            }
        };

        fn iterateFreelist(self: Self) FreelistIterator {
            return .{
                .free_space_start = self.heap.ptr,
                .maybe_prev_allocation_at = null,
                .maybe_next_allocation_at = self.first_allocation_at,
                .end = self.heap.ptr + self.heap.len,
            };
        }

        const AllocationIterator = struct {
            ptr: ?[*]u8,

            fn next(self: *AllocationIterator) ?[*]u8 {
                const ptr = self.ptr orelse return null;

                const header: *align(1) Header = @ptrCast(ptr);
                defer self.ptr = header.next;

                return ptr;
            }
        };

        fn iterateAllocations(self: Self) AllocationIterator {
            return .{
                .ptr = self.first_allocation_at,
            };
        }

        /// checks allocations for consistency, optionally
        ///  - asserts that a given slice is free
        ///  - asserts that an allocation is owned
        fn checkFun(self: Self, maybe_assert_free: ?[]u8, maybe_assert_owned: ?[*]u8) void {
            var overlap_with: ?*align(1) Header = null;
            var owned: bool = false;

            var iter = self.iterateAllocations();
            var maybe_prev: ?*align(1) Header = null;
            while (iter.next()) |ptr| {
                const curr_header_ptr: *align(1) Header = @ptrCast(ptr);
                defer maybe_prev = curr_header_ptr;

                if (maybe_prev) |prev| {
                    std.debug.assert(prev.next.? == ptr);
                    std.debug.assert(curr_header_ptr.prev.? == @as([*]u8, @ptrCast(prev)));
                }

                const curr_data_ptr = ptr + @sizeOf(Header);
                const curr_end_ptr = curr_data_ptr + curr_header_ptr.length;

                const complete_iterated_allocation = util.mkSlice(ptr, curr_end_ptr);

                if (maybe_assert_owned) |assert_owned| {
                    if (assert_owned == ptr) {
                        std.debug.assert(!owned);
                        owned = true;
                    }
                }

                if (maybe_assert_free) |assert_free| {
                    if (util.rangeContains(complete_iterated_allocation, assert_free.ptr)) {
                        overlap_with = curr_header_ptr;
                    }

                    if (util.rangeContains(complete_iterated_allocation, assert_free.ptr + assert_free.len - 1)) {
                        overlap_with = curr_header_ptr;
                    }
                }
            }

            if (maybe_assert_free != null) std.debug.assert(overlap_with == null);
            if (maybe_assert_owned != null) std.debug.assert(owned);
        }

        fn insertAllocationUnchecked(
            self: *Self,
            maybe_prev: ?*align(1) Header,
            maybe_next: ?*align(1) Header,
            at: [*]u8,
            length: usize,
        ) []u8 {
            const header: *align(1) Header = @ptrCast(at);
            const data_ptr = at[@sizeOf(Header)..];
            const data_slice = data_ptr[0..length];
            const end_ptr = data_ptr + length;

            if (play_it_safe) {
                std.debug.assert(header.prev == @as(?[*]u8, @ptrFromInt(util.byteSplat(usize, 0x55))));
                std.debug.assert(header.next == @as(?[*]u8, @ptrFromInt(util.byteSplat(usize, 0x55))));
                std.debug.assert(header.length == util.byteSplat(usize, 0x55));

                self.checkFun(util.mkSlice(at, end_ptr), null);
            }

            header.* = .{
                .prev = @ptrCast(maybe_prev),
                .next = @ptrCast(maybe_next),
                .length = length,
            };

            if (maybe_prev) |prev_header| {
                std.debug.assert(maybe_next == @as(?*align(1) Header, @ptrCast(prev_header.next)));

                prev_header.next = at;
            } else {
                self.first_allocation_at = at;
            }

            if (maybe_next) |next_header| {
                std.debug.assert(maybe_prev == @as(?*align(1) Header, @ptrCast(next_header.prev)));

                next_header.prev = at;
            }

            return data_slice;
        }

        pub fn allocationSize(self: Self, ptr: [*]u8) usize {
            const header: *align(1) Header = @ptrCast(ptr - @sizeOf(Header));

            if (play_it_safe) {
                self.checkFun(null, @ptrCast(header));
            }

            return header.length;
        }

        pub fn stats(self: Self) Statistics {
            var ret: Statistics = .{
                .num_allocations = 0,
                .used_bytes = 0,
                .overhead_bytes = 0,

                .free_spot_stats = undefined,
            };

            {
                var iterator = self.iterateAllocations();
                while (iterator.next()) |ptr| {
                    const header: *align(1) Header = @ptrCast(ptr);
                    const overhead = @sizeOf(Header);

                    ret.num_allocations += 1;
                    ret.used_bytes += overhead + header.length;
                    ret.overhead_bytes += overhead;
                }
            }

            {
                for (0..ret.free_spot_stats.len) |i| ret.free_spot_stats[i] = 0;
                var iterator = self.iterateFreelist();
                while (iterator.next()) |elem| {
                    for (0..ret.free_spot_stats.len) |i| {
                        const spot_max_len = 4 * (@as(usize, 1) << @intCast(i));
                        if (spot_max_len < elem.space.len) continue;

                        ret.free_spot_stats[i] += 1;
                        break;
                    }
                }
            }

            return ret;
        }

        fn vAlloc(
            self: *Self,
            length: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            _ = ret_addr;

            // std.log.debug("before alloc", .{});
            // self.logAllocations();

            // defer self.logAllocations();
            // defer std.log.debug("after alloc", .{});

            var strat: Strat = .{};
            var got_at_least_one_candidate = false;

            var iter = self.iterateFreelist();
            while (iter.next()) |elem| {
                const data_ptr = blk: {
                    const first_ptr_after_alignment = std.mem.alignPointer(
                        elem.space.ptr,
                        alignment.toByteUnits(),
                    ) orelse continue;

                    var num_blocks_to_offset: usize = 0;
                    while (true) {
                        const ptr = first_ptr_after_alignment + num_blocks_to_offset * alignment.toByteUnits();

                        const space_before_alloc = @intFromPtr(ptr) - @intFromPtr(elem.space.ptr);
                        if (space_before_alloc >= @sizeOf(Header)) break :blk ptr;

                        num_blocks_to_offset += 1;
                    }
                };

                const header_ptr = data_ptr - @sizeOf(Header);
                const end_of_data = data_ptr + length;

                if (@intFromPtr(end_of_data) > @intFromPtr(elem.space.ptr + elem.space.len)) continue;
                if (@intFromPtr(data_ptr) < @intFromPtr(elem.space.ptr)) continue;
                // std.log.debug("space: {X:016}..{X:016}", .{
                //     @intFromPtr(elem.space.ptr),
                //     @intFromPtr(elem.space.ptr + elem.space.len),
                // });
                // std.log.debug("alloc: {X:016}..{X:016}", .{
                //     @intFromPtr(header_ptr),
                //     @intFromPtr(end_of_data),
                // });

                const candidate: strategy.CandidateAllocation = .{
                    .free_block_length = elem.space.len,
                    .header_ptr = header_ptr,
                    .prev_ptr = elem.prev,
                    .next_ptr = elem.next,
                };

                const consideration: strategy.Consideration = strat.consider(candidate);
                got_at_least_one_candidate = true;

                if (consideration == .ok_im_done) break;
            }

            if (!got_at_least_one_candidate) return null;

            const chosen_candidate: strategy.CandidateAllocation = strat.chosenCandidate();
            return self.insertAllocationUnchecked(
                @ptrCast(chosen_candidate.prev_ptr),
                @ptrCast(chosen_candidate.next_ptr),
                chosen_candidate.header_ptr,
                length,
            ).ptr;
        }

        fn vFree(
            self: *Self,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) void {
            _ = alignment;
            _ = ret_addr;

            // std.log.debug("before free", .{});
            // self.logAllocations();

            // defer self.logAllocations();
            // defer std.log.debug("after free", .{});

            const header: *align(1) Header = @ptrCast(memory.ptr - @sizeOf(Header));
            const actual_ptr: [*]u8 = @ptrCast(header);

            if (play_it_safe) self.checkFun(null, actual_ptr);
            defer if (play_it_safe) self.checkFun(null, null);

            if (play_it_safe) {
                std.debug.assert(header.length == memory.len);
            }

            if (header.prev) |prev| {
                const prev_header: *align(1) Header = @ptrCast(prev);
                std.debug.assert(prev_header.next == actual_ptr);
                prev_header.next = header.next;
            } else {
                self.first_allocation_at = header.next;
            }

            if (header.next) |next| {
                const next_header: *align(1) Header = @ptrCast(next);
                std.debug.assert(next_header.prev == actual_ptr);

                next_header.prev = header.prev;
            }

            if (play_it_safe) {
                header.* = .{
                    .prev = @ptrFromInt(util.byteSplat(usize, 0x55)),
                    .next = @ptrFromInt(util.byteSplat(usize, 0x55)),
                    .length = util.byteSplat(usize, 0x55),
                };
                @memset(memory, 0x55);
            }
        }

        fn logFreelist(a: Self) void {
            const h = a.heap;
            std.log.debug("====   freelist   ==== ", .{});

            var iterator = a.iterateFreelist();
            var i: usize = 0;
            while (iterator.next()) |elem| : (i += 1) {
                std.log.debug("free space #{d} {d} {d}", .{ i, @intFromPtr(elem.space.ptr) - @intFromPtr(h.ptr), elem.space.len });

                if (elem.prev) |prev| std.log.debug("prev: {d}", .{@intFromPtr(prev) - @intFromPtr(h.ptr)}) else std.log.debug("prev: null", .{});

                if (elem.next) |next| std.log.debug("next: {d}", .{@intFromPtr(next) - @intFromPtr(h.ptr)}) else std.log.debug("next: null", .{});
            }

            std.log.debug("==== freelist end ==== ", .{});
        }

        fn logAllocations(a: Self) void {
            const h = a.heap;
            std.log.debug("====   allocations   ==== ", .{});

            var iterator = a.iterateAllocations();
            var i: usize = 0;
            while (iterator.next()) |ptr| : (i += 1) {
                const header: *align(1) FirstFitAllocator.Header = @ptrCast(ptr);

                std.log.debug("allocation #{d} {d} {d}", .{ i, @intFromPtr(ptr) - @intFromPtr(h.ptr), header.length });

                if (header.prev) |prev| std.log.debug("prev: {d}", .{@intFromPtr(prev) - @intFromPtr(h.ptr)}) else std.log.debug("prev: null", .{});

                if (header.next) |next| std.log.debug("next: {d}", .{@intFromPtr(next) - @intFromPtr(h.ptr)}) else std.log.debug("next: null", .{});
            }

            std.log.debug("==== allocations end ==== ", .{});
        }

        heap: []u8,
        first_allocation_at: ?[*]u8 = null,
    };
}

test {
    const known_good = std.testing.allocator;

    const heap = try known_good.alloc(u8, 1024 * 1024 * 16);
    defer known_good.free(heap);

    var ffa: FirstFitAllocator = .init(heap);

    if (false) {
        ffa.logFreelist();
        ffa.logAllocations();
        const a0 = ffa.vAlloc(65, .@"16", 0).?;
        const a1 = ffa.vAlloc(66, .@"16", 0).?;
        const a2 = ffa.vAlloc(67, .@"16", 0).?;
        const a3 = ffa.vAlloc(68, .@"16", 0).?;
        const a4 = ffa.vAlloc(69, .@"16", 0).?;
        ffa.logAllocations();

        ffa.vFree(a1[0..66], .@"16", 0);
        ffa.vFree(a2[0..67], .@"16", 0);
        ffa.vFree(a3[0..68], .@"16", 0);
        ffa.logAllocations();

        const a5 = ffa.vAlloc(33, .@"16", 0).?;
        const a6 = ffa.vAlloc(34, .@"16", 0).?;
        const a7 = ffa.vAlloc(35, .@"16", 0).?;
        const a8 = ffa.vAlloc(512, .@"16", 0).?;
        ffa.logAllocations();

        ffa.vFree(a7[0..35], .@"16", 0);
        ffa.vFree(a6[0..34], .@"16", 0);
        ffa.vFree(a5[0..33], .@"16", 0);
        ffa.logAllocations();

        ffa.vFree(a0[0..65], .@"16", 0);

        const a9 = ffa.vAlloc(127, .@"64", 0).?;

        ffa.vFree(a4[0..69], .@"16", 0);
        ffa.vFree(a8[0..512], .@"16", 0);
        ffa.vFree(a9[0..127], .@"64", 0);

        ffa.logFreelist();
        ffa.logAllocations();
    } else {
        const checkEmpty = struct {
            fn aufruf(alloc: std.mem.Allocator) bool {
                const ffa_: *FirstFitAllocator = @ptrCast(@alignCast(alloc.ptr));
                return ffa_.first_allocation_at == null;
            }
        }.aufruf;

        const onFailure = struct {
            fn aufruf(alloc: std.mem.Allocator) void {
                _ = alloc;
            }
        }.aufruf;

        try @import("allocator_tester.zig").testAllocator(known_good, ffa.allocator(), checkEmpty, onFailure);
    }
}

pub const FirstFitAllocator = AnyFitAllocator(strategies.FirstFit);
pub const BestFitAllocator = AnyFitAllocator(strategies.BestFit);
