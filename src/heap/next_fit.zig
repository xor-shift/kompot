const std = @import("std");

const Canary = [16]u8;

const util = struct {
    // Returns the space available between `start` and `end` (`end` not
    // inclusive) after aligning to `byte_alignmnt` as a slice.
    fn spaceAfterAlignment(
        start: [*]u8,
        end: [*]u8,
        byte_alignment: usize,
    ) ?[]u8 {
        const offset_to_align = std.mem.alignPointerOffset(start, byte_alignment) orelse return null;
        const actual_start: [*]u8 = @alignCast(start + offset_to_align);

        const space = end - start;
        const skipped = actual_start - start;
        if (skipped > space) return null;

        return actual_start[0 .. space - skipped];
    }
};

test "util.spaceAfterAlignment" {
    var asd: [256]u8 align(16) = undefined;
    const start = asd[0..].ptr;
    const end = asd[0..].ptr + asd.len;

    try std.testing.expectEqual(asd[0..], util.spaceAfterAlignment(start, end, 1));
    try std.testing.expectEqual(asd[0..], util.spaceAfterAlignment(start, end, 2));
    try std.testing.expectEqual(asd[0..], util.spaceAfterAlignment(start, end, 16));

    try std.testing.expectEqual(asd[1..], util.spaceAfterAlignment(start + 1, end, 1));
    try std.testing.expectEqual(asd[2..], util.spaceAfterAlignment(start + 1, end, 2));
    try std.testing.expectEqual(asd[16..], util.spaceAfterAlignment(start + 1, end, 16));

    try std.testing.expectEqual(asd[15..], util.spaceAfterAlignment(start + 15, end, 1));
    try std.testing.expectEqual(asd[16..], util.spaceAfterAlignment(start + 15, end, 2));
    try std.testing.expectEqual(asd[16..], util.spaceAfterAlignment(start + 15, end, 16));
}

pub const Config = struct {
    /// Bytes gotten from https://random.org/bytes. Change these if you will.
    canary_value: Canary = .{
        0xf1, 0x5f, 0x7b, 0xdf,
        0xb2, 0x80, 0x61, 0x1f,
        0x34, 0xaf, 0x5d, 0x90,
        0xcd, 0x6e, 0x31, 0x10,
    },

    check_canaries: enum {
        never,
        self_on_dealloc,
        everyone_on_dealloc,
        everyone_on_alloc_and_dealloc,
    } = .self_on_dealloc,
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

        pub fn allocationInfo(self: *Self, ptr: *const anyopaque) ?struct {
            length: usize,
            alignment: std.mem.Alignment,
        } {
            std.debug.assert(self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
            defer self.race_detector.store(false, .release);
            // ^ we don't really need this here but oh well

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
                allocated_by: usize = undefined,
                deallocated_by: usize = 0,

                prev: ?[*]u8 = null,
                next: ?[*]u8 = null,
            };

            /// *_end pointers are one-past-the-end pointers
            const Pointers = struct {
                header_start: [*]u8,
                header_end: [*]u8,

                anterior_canary_start: [*]u8,
                anterior_canary_end: [*]u8,

                data_start: [*]u8,
                data_end: [*]u8,

                posterior_canary_start: [*]u8,
                posterior_canary_end: [*]u8,

                pub fn start(self: Pointers) [*]u8 {
                    return self.header_start;
                }

                pub fn headerBytes(self: Pointers) []u8 {
                    return self.header_start[0 .. self.header_end - self.header_start];
                }

                pub fn anteriorCanaryBytes(self: Pointers) []u8 {
                    return self.data_start[0 .. self.anterior_canary_end - self.anterior_canary_start];
                }

                pub fn dataBytes(self: Pointers) []u8 {
                    return self.data_start[0 .. self.data_end - self.data_start];
                }

                pub fn posteriorCanaryBytes(self: Pointers) []u8 {
                    return self.data_start[0 .. self.posterior_canary_end - self.posterior_canary_start];
                }

                pub fn end(self: Pointers) [*]u8 {
                    return self.posterior_canary_end;
                }
            };

            header_ptr: [*]u8,

            fn fromDataPtr(data_ptr: [*]u8) Allocation {
                const aligned_usize = @intFromPtr(data_ptr) - @sizeOf(Header) - @sizeOf(Canary);

                return .{
                    .header_ptr = @ptrFromInt(aligned_usize),
                };
            }

            fn removeThisFromTheMiddle(self: Allocation) void {
                const header = self.getHeader();

                if (header.prev) |prev| {
                    const prev_alloc = Allocation{ .header_ptr = prev };
                    const prev_header = prev_alloc.getHeader();

                    prev_header.next = header.next;
                }

                if (header.next) |next| {
                    const next_alloc = Allocation{ .header_ptr = next };
                    const next_header = next_alloc.getHeader();

                    next_header.prev = header.prev;
                }
            }

            fn insertThisIntoTheMiddle(
                self: Allocation,
                maybe_prev: ?Allocation,
                maybe_next: ?Allocation,
            ) void {
                if (maybe_prev) |prev_alloc| {
                    const prev_header = prev_alloc.getHeader();
                    prev_header.next = self.header_ptr;
                }

                if (maybe_next) |next_alloc| {
                    const next_header = next_alloc.getHeader();
                    next_header.prev = self.header_ptr;
                }
            }

            fn getPointersGivenHeader(self: Allocation, header: Header) Pointers {
                const header_start = self.header_ptr;
                const header_end = header_start + @sizeOf(Header);

                const anterior_canary_start = header_end;
                const anterior_canary_end = anterior_canary_start + @sizeOf(Canary);

                const data_start = anterior_canary_end;
                const data_end = data_start + header.length;

                const posterior_canary_start = data_end;
                const posterior_canary_end = posterior_canary_start + @sizeOf(Canary);

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

            fn getHeader(self: Allocation) *align(1) Header {
                const actual_ptr: *align(1) Header = @ptrCast(self.header_ptr);
                return actual_ptr;
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
                @memcpy(self.getCanary(.anterior), &config.canary_value);
                @memcpy(self.getCanary(.posterior), &config.canary_value);
            }

            fn checkHeaderConsistency(self: Allocation, given_data: []u8, given_alignment: std.mem.Alignment) void {
                const header = self.getHeader();

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
            curr: ?[*]u8 = null,

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

        pub fn stats(self: *Self) Statistics {
            std.debug.assert(self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
            defer self.race_detector.store(false, .release);

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
                    const space_before_data = @sizeOf(Allocation.Header) + @sizeOf(Canary);
                    const space_after_data = @sizeOf(Canary);
                    _ = space_after_data;

                    const aligned_space_for_data_and_posterior_canary: []u8 = util.spaceAfterAlignment(
                        empty_space_start + space_before_data,
                        empty_space_end,
                        alignment_.toByteUnits(),
                    ) orelse return null;

                    const allocation: Allocation = .{
                        .header_ptr = aligned_space_for_data_and_posterior_canary.ptr - space_before_data,
                    };

                    const pointers = allocation.getPointersGivenHeader(.{
                        .length = length_,
                        .alignment = alignment_,
                    });

                    const overflown = @intFromPtr(pointers.end()) > @intFromPtr(empty_space_end);

                    if (overflown) return null;

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

        pub fn allocateBytes(
            self: *Self,
            length: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            if (length == 0) {
                const ptr = std.mem.alignBackward(usize, std.math.maxInt(usize), alignment.toByteUnits());
                return @ptrFromInt(ptr);
            }

            defer self.check();

            std.debug.assert(self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
            defer self.race_detector.store(false, .release);

            const fit_result = self.findFit(length, alignment) orelse return null;

            const allocation = fit_result.raw_allocation;

            if (fit_result.prev) |prev| {
                if (fit_result.next) |next| {
                    std.debug.assert(prev.getHeader().next == next.header_ptr);
                    std.debug.assert(next.getHeader().prev == prev.header_ptr);
                }
            }

            allocation.insertThisIntoTheMiddle(fit_result.prev, fit_result.next);

            allocation.getHeader().* = .{
                .length = length,
                .alignment = alignment,
                .allocated_by = ret_addr,

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

        pub fn deallocateBytesImpl(self: *Self, data: [*]u8, ret_addr: usize, maybe_check_info: ?struct {
            length: usize,
            alignment: std.mem.Alignment,
        }) void {
            if (maybe_check_info) |info| {
                if (info.length == 0) return;
            }

            // if (true) return;

            defer self.check();
            self.check();

            std.debug.assert(self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
            defer self.race_detector.store(false, .release);

            const allocation = Allocation.fromDataPtr(data);
            const header = allocation.getHeader();

            if (@import("builtin").mode == .Debug) {
                const found_allocation = self.assertAllocationIsValid(data);
                const found_header = found_allocation.getHeader();
                _ = found_header;

                std.debug.assert(allocation.header_ptr == found_allocation.header_ptr);
            }

            // double free
            std.debug.assert(header.deallocated_by == 0);
            header.deallocated_by = ret_addr;

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

            allocation.removeThisFromTheMiddle();
            @memset(allocation.getData(), 0);

            if (header.prev == null) self.first_allocation_at = header.next;
        }

        pub fn deallocateBytes(self: *Self, data: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            self.deallocateBytesImpl(data.ptr, ret_addr, .{
                .length = data.len,
                .alignment = alignment,
            });
        }

        /// Checks whether an allocation belongs to this NFA
        pub fn assertAllocationIsValid(self: *Self, data_ptr: [*]u8) Allocation {
            var iterator = self.iterate();
            while (iterator.next()) |curr| {
                const curr_data_ptr = curr.getData().ptr;
                if (curr_data_ptr == data_ptr) return curr;

                const curr_data_uintptr = @intFromPtr(curr_data_ptr);
                const data_uintptr = @intFromPtr(data_ptr);
                if (curr_data_uintptr > data_uintptr) @panic("this allocation does not belong here");
            }

            unreachable;
        }

        /// Checks all of the allocations for consistency
        pub fn check(self: *Self) void {
            std.debug.assert(self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
            defer self.race_detector.store(false, .release);

            var iterator = self.iterate();
            var maybe_prev: ?Allocation = null;
            while (iterator.next()) |curr| {
                defer maybe_prev = curr;

                curr.checkMarks();
                curr.checkCanaries();

                const curr_header_ptr = curr.getHeader();
                const curr_pointers = curr.getPointers();

                if (curr_header_ptr.deallocated_by != 0) {
                    @panic("freed allocation still in the list");
                }

                if (maybe_prev) |prev| {
                    const prev_header_ptr = prev.getHeader();
                    const prev_pointers = prev.getPointers();

                    if (curr_header_ptr.prev) |curr_prev| {
                        if (curr_prev != prev_pointers.start()) {
                            @panic("curr.prev != prev");
                        }
                    } else @panic("curr must have a prev");

                    if (prev_header_ptr.next) |prev_next| {
                        if (prev_next != curr_pointers.start()) {
                            @panic("prev.next != curr");
                        }
                    } else @panic("prev must have a next");
                }
            }
        }

        pub fn debug(self: *Self) void {
            const log = std.log.scoped(.nfa_debug);
            self.debugImpl(log, struct {
                fn aufruf(ctx: anytype, comptime fmt: []const u8, args: anytype) void {
                    ctx.debug(fmt, args);
                }
            }.aufruf);
        }

        pub fn debugImpl(
            self: *Self,
            log_ctx: anytype,
            comptime log_fn: anytype,
        ) void {
            std.debug.assert(self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
            defer self.race_detector.store(false, .release);

            log_fn(log_ctx, "====   nfa_debug   ====", .{});
            log_fn(log_ctx, "  heap start      : {*}", .{self.heap.ptr});
            log_fn(log_ctx, "  heap end        : {*} (heap start + {d})", .{ self.heap.ptr + self.heap.len, self.heap.len });
            log_fn(log_ctx, "  first alloc at  : {*} (heap start + {?d})", .{
                self.first_allocation_at,
                if (self.first_allocation_at) |v| v - self.heap.ptr else null,
            });
            log_fn(log_ctx, "  ====   allocations   ====", .{});

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

                log_fn(log_ctx, "    ... {d} skipped bytes ...", .{skipped_bytes});
                log_fn(log_ctx, "    ====   allocation #{:02}   ====", .{alloc_no});
                log_fn(log_ctx, "      ====   pointers   ====", .{});
                log_fn(log_ctx, "        header_start          : {*}", .{pointers.header_start});
                log_fn(log_ctx, "        header_end            : {*}", .{pointers.header_end});
                log_fn(log_ctx, "        anterior_canary_start : {*}", .{pointers.anterior_canary_start});
                log_fn(log_ctx, "        anterior_canary_end   : {*}", .{pointers.anterior_canary_end});
                log_fn(log_ctx, "        data_start            : {*}", .{pointers.data_start});
                log_fn(log_ctx, "        data_end              : {*}", .{pointers.data_end});
                log_fn(log_ctx, "        posterior_canary_start: {*}", .{pointers.posterior_canary_start});
                log_fn(log_ctx, "        posterior_canary_end  : {*}", .{pointers.posterior_canary_end});
                log_fn(log_ctx, "      ==== pointers end ====", .{});
                log_fn(log_ctx, "      start      : {*}", .{allocation.header_ptr});
                log_fn(log_ctx, "      true length: {d}", .{allocation.firstPtrAfter() - allocation.header_ptr});
                log_fn(log_ctx, "      length     : {d}", .{allocation.getHeader().length});
                log_fn(log_ctx, "      alignment  : {d}", .{allocation.getHeader().alignment.toByteUnits()});
                log_fn(log_ctx, "      alloc by   : {X:016}", .{allocation.getHeader().allocated_by});
                log_fn(log_ctx, "      dealloc by : {X:016}", .{allocation.getHeader().deallocated_by});
                log_fn(log_ctx, "      prev       : {*}", .{allocation.getHeader().prev});
                log_fn(log_ctx, "      next       : {*}", .{allocation.getHeader().next});
                log_fn(log_ctx, "    ==== allocation #{:02} end ====", .{alloc_no});

                if (prev_allocation) |prev| {
                    std.debug.assert(prev.getHeader().next == allocation.header_ptr);
                    std.debug.assert(prev.header_ptr == allocation.getHeader().prev);
                }
            }

            log_fn(log_ctx, "    ... {d} more bytes ...", .{
                if (prev_allocation) |prev|
                    (self.heap.ptr + self.heap.len) - prev.firstPtrAfter()
                else
                    self.heap.len,
            });
            log_fn(log_ctx, "  ==== allocations end ====", .{});
            log_fn(log_ctx, "==== nfa_debug end ====", .{});
        }

        pub fn isEmpty(self: *Self) bool {
            std.debug.assert(self.race_detector.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
            defer self.race_detector.store(false, .release);

            return self.first_allocation_at == null;
        }

        race_detector: std.atomic.Value(bool) = .init(false),

        heap: []u8,
        first_allocation_at: ?[*]u8 = null,
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
        const l = random.intRangeLessThan(usize, 128, 256);
        // const l = 255;

        alloc.free(test_allocations[i]);
        test_allocations[i] = try alloc.alloc(u8, l);
    }
}

test "better stress test" {
    if (true) return;

    const heap = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(heap);

    const allocations = try std.testing.allocator.alloc(?[]u8, 1024);
    defer std.testing.allocator.free(allocations);
    @memset(allocations, null);

    const NFA = NextFitAllocator(.{});
    var nfa: NFA = .{
        .heap = heap,
    };

    const alloc = nfa.allocator();

    var xoshiro = std.Random.Xoshiro256.init(@intCast(std.testing.random_seed));
    const random = xoshiro.random();

    for (0..16) |_| {
        var num_alloc_loops: usize = 0;
        while (true) : (num_alloc_loops += 1) {
            const i = random.intRangeLessThan(usize, 0, allocations.len);
            const l = random.intRangeAtMost(usize, 512 - 128, 512 + 128);

            const new_allocation = alloc.alloc(u8, l) catch break;

            if (allocations[i]) |allocation| {
                alloc.free(allocation);
                allocations[i] = null;
            }

            allocations[i] = new_allocation;
        }

        try std.testing.expect(num_alloc_loops > 32); // sanity check

        var num_dealloc_loops: usize = 0;
        for (0..allocations.len / 2) |_| {
            num_dealloc_loops += 1;

            const i = random.intRangeLessThan(usize, 0, allocations.len);

            if (allocations[i]) |allocation| {
                alloc.free(allocation);
                allocations[i] = null;
            }
        }

        try std.testing.expect(num_dealloc_loops > 32); // sanity check
    }
}

test "NextFitAllocator thru allocator_tester" {
    const heap = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(heap);

    const NFA = NextFitAllocator(.{});
    var nfa: NFA = .{
        .heap = heap,
    };

    const alloc = nfa.allocator();

    const tester = @import("allocator_tester.zig");
    try tester.testAllocator(
        std.testing.allocator,
        alloc,
        struct {
            fn aufruf(alloc_: std.mem.Allocator) bool {
                const alloc_ptr: *NFA = @ptrCast(@alignCast(alloc_.ptr));
                return alloc_ptr.isEmpty();
            }
        }.aufruf,
        struct {
            fn aufruf(alloc_: std.mem.Allocator) void {
                const alloc_ptr: *NFA = @ptrCast(@alignCast(alloc_.ptr));
                alloc_ptr.debug();
            }
        }.aufruf,
    );
}
