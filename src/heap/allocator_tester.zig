const std = @import("std");
const kompot = @import("kompot");

const do_log = false;

const util = struct {
    fn assertedAlloc(
        alloc: std.mem.Allocator,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ![*]u8 {
        const res = try (alloc.rawAlloc(len, alignment, ret_addr) orelse std.mem.Allocator.Error.OutOfMemory);

        const modulo = @intFromPtr(res) % alignment.toByteUnits();
        try std.testing.expectEqual(0, modulo);

        return res;
    }

    fn doAllocAdvanced(
        alloc: std.mem.Allocator,
        comptime T: type,
        comptime alignment_arg: ?std.mem.Alignment,
        len: usize,
        ret_addr: usize,
    ) ![]T {
        const alignment = comptime (alignment_arg orelse std.mem.Alignment.fromByteUnits(@alignOf(T)));
        const mem = try assertedAlloc(alloc, len * @sizeOf(T), alignment, ret_addr);
        const ptr: [*]align(alignment.toByteUnits()) T = @ptrCast(@alignCast(mem));
        return ptr[0..len];
    }

    fn doAlloc(
        alloc: std.mem.Allocator,
        comptime T: type,
        len: usize,
    ) ![]T {
        return doAllocAdvanced(alloc, T, null, len, @returnAddress());
    }

    fn getXoshiro(iter_ct: usize) std.Random.Xoshiro256 {
        const base_seed = std.testing.random_seed;
        var seed_shuffler: std.Random.SplitMix64 = .init(base_seed);
        for (0..iter_ct) |_| _ = seed_shuffler.next();
        const actual_seed = seed_shuffler.next();

        const xoshiro: std.Random.Xoshiro256 = .init(actual_seed);

        return xoshiro;
    }

    const SavedAlloc = struct {
        const FreeFun = fn (allocation: SavedAlloc, allocator: std.mem.Allocator) void;

        allocation: *anyopaque,
        // the number of elements, not the size in bytes of `allocation`
        len: usize,

        free_fun: *const FreeFun,

        fn shuffle(list: *std.ArrayListUnmanaged(SavedAlloc)) void {
            var xoshiro = getXoshiro(16);
            const random = xoshiro.random();

            std.Random.shuffle(random, SavedAlloc, list.items);
        }

        fn freeLastN(
            list: *std.ArrayListUnmanaged(SavedAlloc),
            alloc: std.mem.Allocator,
            n: usize,
        ) void {
            var it = std.mem.reverseIterator(list.items);
            for (0..n) |_| {
                const allocation: SavedAlloc = it.next().?;
                allocation.free_fun(allocation, alloc);
            }

            list.resize(undefined, list.items.len - n) catch unreachable;
        }

        fn freeAll(
            list: *std.ArrayListUnmanaged(SavedAlloc),
            alloc: std.mem.Allocator,
        ) void {
            freeLastN(list, alloc, list.items.len);
        }

        fn shuffleAndFreeLastN(
            list: *std.ArrayListUnmanaged(SavedAlloc),
            alloc: std.mem.Allocator,
            n: usize,
        ) void {
            shuffle(list);
            freeLastN(list, alloc, n);
        }

        fn shuffleAndFreeAll(
            list: *std.ArrayListUnmanaged(SavedAlloc),
            alloc: std.mem.Allocator,
        ) void {
            shuffle(list);
            freeAll(list, alloc);
        }

        fn makeFreeFun(comptime T: type) *const FreeFun {
            return struct {
                fn aufruf(allocation: SavedAlloc, allocator: std.mem.Allocator) void {
                    const ptr: [*]T = @ptrCast(@alignCast(allocation.allocation));
                    const slice = ptr[0..allocation.len];

                    if (do_log) std.log.debug("freeing {d} of {s} ({d} bytes)...", .{ allocation.len, @typeName(T), allocation.len * @sizeOf(T) });
                    allocator.free(slice);
                }
            }.aufruf;
        }
    };

    fn doAndSaveAlloc(
        known_good: std.mem.Allocator,
        into: *std.ArrayListUnmanaged(SavedAlloc),
        alloc: std.mem.Allocator,
        comptime T: type,
        len: usize,
    ) !void {
        if (do_log) std.log.debug("allocating {d} of {s} ({d} bytes)...", .{ len, @typeName(T), len * @sizeOf(T) });
        const allocation = try doAlloc(alloc, T, len);

        try into.append(known_good, SavedAlloc{
            .allocation = allocation.ptr,
            .len = len,
            .free_fun = SavedAlloc.makeFreeFun(T),
        });
    }
};

const cases = struct {
    fn previousEdgeCases(
        known_good: std.mem.Allocator,
        alloc: std.mem.Allocator,
    ) !void {
        _ = known_good;
        _ = alloc;

        // const alloc_0 =
    }

    fn basicIndividualCases(
        known_good: std.mem.Allocator,
        alloc: std.mem.Allocator,
    ) !void {
        var list: std.ArrayListUnmanaged(util.SavedAlloc) = try .initCapacity(known_good, 0);
        defer list.deinit(known_good);
        defer util.SavedAlloc.shuffleAndFreeAll(&list, alloc);

        try util.doAndSaveAlloc(known_good, &list, alloc, u8, 1);
        try util.doAndSaveAlloc(known_good, &list, alloc, u16, 1);
        try util.doAndSaveAlloc(known_good, &list, alloc, u32, 1);
        try util.doAndSaveAlloc(known_good, &list, alloc, u64, 1);
    }

    fn someRanges(
        known_good: std.mem.Allocator,
        alloc: std.mem.Allocator,
    ) !void {
        var list: std.ArrayListUnmanaged(util.SavedAlloc) = try .initCapacity(known_good, 0);
        defer list.deinit(known_good);
        defer util.SavedAlloc.shuffleAndFreeAll(&list, alloc);

        inline for (3..7) |len_log_2| {
            const Int = std.meta.Int(.unsigned, 1 << len_log_2);
            for (1..64) |i| {
                try util.doAndSaveAlloc(known_good, &list, alloc, Int, i);
            }
        }
    }

    fn randomised(
        known_good: std.mem.Allocator,
        alloc: std.mem.Allocator,
    ) !void {
        var list: std.ArrayListUnmanaged(util.SavedAlloc) = try .initCapacity(known_good, 0);
        defer list.deinit(known_good);
        defer util.SavedAlloc.shuffleAndFreeAll(&list, alloc);

        var xoshiro = util.getXoshiro(32);
        const random = xoshiro.random();

        for (0..8) |_| {
            for (0..1024) |_| {
                const Closure = struct {
                    known_good: std.mem.Allocator,
                    list: *std.ArrayListUnmanaged(util.SavedAlloc),
                    alloc: std.mem.Allocator,
                    len: usize,

                    fn aufruf(ctx: @This(), comptime T: type) !void {
                        try util.doAndSaveAlloc(
                            ctx.known_good,
                            ctx.list,
                            ctx.alloc,
                            T,
                            ctx.len,
                        );
                    }
                };

                const ctx: Closure = .{
                    .known_good = known_good,
                    .list = &list,
                    .alloc = alloc,
                    .len = random.intRangeAtMost(usize, 1, 1024),
                };

                const int_size = random.intRangeAtMost(usize, 0, 3);
                try switch (int_size) {
                    0 => ctx.aufruf(u8),
                    1 => ctx.aufruf(u16),
                    2 => ctx.aufruf(u32),
                    3 => ctx.aufruf(u64),
                    else => unreachable,
                };
            }
            util.SavedAlloc.shuffleAndFreeLastN(&list, alloc, list.items.len / 2);
        }
    }
};

pub fn testAllocator(
    known_good: std.mem.Allocator,
    alloc_to_be_tested: std.mem.Allocator,
    check_empty: *const fn (alloc: std.mem.Allocator) bool,
    on_failure: *const fn (alloc: std.mem.Allocator) void,
    // assert_consistency: *const fn (alloc: std.mem.Allocator) void,
) !void {
    inline for (.{
        // cases.previousEdgeCases,
        // cases.basicIndividualCases,
        // cases.someRanges,
        cases.randomised,
    }) |case_fun| {
        try case_fun(known_good, alloc_to_be_tested);
        _ = check_empty;
        _ = on_failure;
        // std.testing.expect(check_empty(alloc_to_be_tested)) catch |e| {
        //     on_failure(alloc_to_be_tested);
        //     return e;
        // };
    }
}
