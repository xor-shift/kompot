const std = @import("std");

pub const RotatingArenaConfig = struct {
    /// When true, the next pool will be poisoned. That is, it will become
    /// unreadable and unwritable for a frame (if possible (only on Linux rn)).
    use_barriers: bool = true,

    /// Whether pools that are rotated into should be cleared out.
    clear_new: bool = false,

    /// Whether the oldest pool should be cleared out.
    /// Only relevant if `use_barriers` is `true` and poisoning isn't
    /// supported. It is assumed to be `false` otherwise.
    clear_old: bool = false,

    no_pools: usize,

    bytes_per_pool: usize,

    fn pool_size(self: RotatingArenaConfig) usize {
        return std.mem.alignForward(usize, self.bytes_per_pool, std.mem.page_size);
    }
};

pub fn RotatingArena(comptime config: RotatingArenaConfig) type {
    return struct {
        const Self = @This();

        const Arena = struct {
            pub const vtable = std.mem.Allocator.VTable{
                .alloc = Arena.valloc,
                .resize = Arena.vresize,
                .free = Arena.vfree,
            };

            pool_start: [*]align(std.mem.page_size) u8,
            pool_ptr: usize,

            fn init() !Arena {
                const pool = try std.heap.page_allocator.alignedAlloc(
                    u8,
                    std.mem.page_size,
                    config.pool_size(),
                );

                var ret: Arena = .{
                    .pool_start = pool.ptr,
                    .pool_ptr = undefined,
                };
                ret.invalidate();

                return ret;
            }

            fn deinit(self: *Arena) void {
                self.reset();
                std.heap.page_allocator.free(self.get_pool_slice());
            }

            fn get_pool_slice(self: *Arena) []align(std.mem.page_size) u8 {
                return self.pool_start[0..config.pool_size()];
            }

            fn invalidate(self: *Arena) void {
                std.posix.mprotect(self.get_pool_slice(), std.posix.PROT.NONE) catch @panic("mprotect");

                @atomicStore(usize, &self.pool_ptr, config.pool_size(), .release);
            }

            fn reset(self: *Arena) void {
                std.posix.mprotect(self.get_pool_slice(), std.posix.PROT.READ | std.posix.PROT.WRITE) catch @panic("mprotect");

                @atomicStore(usize, &self.pool_ptr, 0, .release);
            }

            fn valloc(
                self_arg: *anyopaque,
                len: usize,
                log2_align: u8,
                return_address: usize,
            ) ?[*]u8 {
                _ = return_address;

                const self: *Arena = @ptrCast(@alignCast(self_arg));

                // Note for my future self:
                //
                // Per n3220 §6.5.7 p9, the only pointer that can be used in
                // arithmetic operations outside of the valid range of an
                // array is the one-past-the-end pointer. That is, the first
                // two conditionals below are well-defined behaviour but the
                // last one is UB:
                //
                // ```c
                // char* foo = malloc(2);
                // if (foo + 1 < foo + 2) { /* ... */ }
                // if (foo + 2 < foo + 3) { /* ... */ }
                // if (foo + 3 < foo + 4) { /* ... */ } // UB!! overflow!
                // ```
                //
                // Moral of the story: don't change `pool_ptr` to a `[*]u8`.

                const alignment = @as(usize, 1) << @intCast(log2_align);
                const real_len = len + alignment - 1;

                const ptr: usize = @atomicRmw(usize, &self.pool_ptr, .Add, real_len, .acq_rel);

                if (ptr + real_len >= config.pool_size()) {
                    return null;
                }

                const aligned = std.mem.alignPointer(self.pool_start + ptr, alignment);

                return aligned;
            }

            fn vresize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
                return false;
            }

            fn vfree(_: *anyopaque, _: []u8, _: u8, _: usize) void {}

            pub fn allocator(self: *Arena) std.mem.Allocator {
                return std.mem.Allocator{
                    .ptr = @ptrCast(self),
                    .vtable = &Arena.vtable,
                };
            }
        };

        no_rotations: usize = 0,

        // i think that they need to be separate allocations for mprotect
        arenas: [config.no_pools + @intFromBool(config.use_barriers)]Arena,

        /// Pools are allocated from `std.heap.page_allocator`
        pub fn init() !Self {
            var arenas: [config.no_pools + @intFromBool(config.use_barriers)]Arena = undefined;

            var managed_to_allocate: usize = 0;
            errdefer for (0..managed_to_allocate) |i| arenas[i].deinit();

            for (0..arenas.len) |i| {
                arenas[i] = try Arena.init();
                // std.log.debug("arena {d} @ {any}", .{i, arenas[i].pool_start});
                managed_to_allocate = i;
            }

            return .{
                .arenas = arenas,
            };
        }

        pub fn deinit(self: *Self) void {
            for (0..self.arenas.len) |i| {
                self.arenas[i].deinit();
            }
        }

        pub fn rotate(self: *Self) std.mem.Allocator {
            // std.log.debug("rotating {any} ({d})", .{
            //     @as(*anyopaque, @ptrCast(self)),
            //     self.arenas.len,
            // });

            if (config.use_barriers) {
                const idx = (self.no_rotations + 1) % self.arenas.len;
                const next = &self.arenas[idx];
                //std.log.debug("invalidating {any} ([{d}], {d}, {any})", .{
                //    @as(*anyopaque, @ptrCast(next)),
                //    idx,
                //    self.arenas.len,
                //    @as(*anyopaque, @ptrCast(next.pool_start)),
                //});
                next.invalidate();
            }

            const idx = self.no_rotations % self.arenas.len;
            const cur = &self.arenas[idx];
            cur.reset();

            // std.log.debug("cur: {any} ([{d}] {d}, {any})", .{
            //     @as(*anyopaque, @ptrCast(cur)),
            //     idx,
            //     self.arenas.len,
            //     @as(*anyopaque, @ptrCast(cur.pool_start)),
            // });

            self.no_rotations += 1;

            return cur.allocator();
        }
    };
}
