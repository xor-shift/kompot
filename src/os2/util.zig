const std = @import("std");

const kompot = @import("kompot");

pub fn KernelMutex(comptime os2: type) type {
    return struct {
        const Self = @This();

        state_after_locking: ?bool = null,

        pub fn lock(self: *Self) void {
            _ = self.tryLock();
        }

        pub fn tryLock(self: *Self) bool {
            std.debug.assert(self.state_after_locking == null);

            const old_state = os2.kernel.lock() catch false;
            self.state_after_locking = old_state;

            return true;
        }

        pub fn unlock(self: *Self) void {
            if (self.state_after_locking) |old_state| {
                self.state_after_locking = null;
                _ = old_state;
                _ = os2.kernel.unlock() catch true;
                // _ = os2.kernel.restoreLock(old_state);
            } else {
                unreachable;
            }
        }
    };
}

pub fn SimpleMutex(comptime os2: type) type {
    return struct {
        const Self = @This();

        const k_unlocked = 0;
        const k_locked = 1;

        state: usize = k_unlocked,

        pub fn lock(self: *Self) void {
            if (self.tryLock()) return;

            while (true) {
                const is_locked = @atomicLoad(usize, &self.state, .acquire) == k_locked;
                if (is_locked) continue;

                if (self.tryLock()) return;

                os2.Thread.yield() catch @panic("unhandled error");
            }
        }

        pub fn tryLock(self: *Self) bool {
            if (@cmpxchgStrong(usize, &self.state, k_unlocked, k_locked, .acq_rel, .acquire) == null) {
                return true;
            }

            return false;
        }

        pub fn unlock(self: *Self) void {
            @atomicStore(usize, &self.state, k_unlocked, .release);
        }
    };
}

pub fn LockedAllocator(comptime Mutex: type) type {
    return struct {
        const Self = @This();

        mutex: Mutex = .{},
        child: std.mem.Allocator,

        const VTable = struct {
            fn alloc(
                self_opaque: *anyopaque,
                length: usize,
                alignment: std.mem.Alignment,
                ret_addr: usize,
            ) ?[*]u8 {
                const self: *Self = @ptrCast(@alignCast(self_opaque));

                self.mutex.lock();
                const ret = self.child.vtable.alloc(self.child.ptr, length, alignment, ret_addr);
                self.mutex.unlock();

                return ret;
            }

            fn resize(
                self_opaque: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                ret_addr: usize,
            ) bool {
                const self: *Self = @ptrCast(@alignCast(self_opaque));

                self.mutex.lock();
                const ret = self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
                self.mutex.unlock();

                return ret;
            }

            fn remap(
                self_opaque: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                ret_addr: usize,
            ) ?[*]u8 {
                const self: *Self = @ptrCast(@alignCast(self_opaque));

                self.mutex.lock();
                const ret = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
                self.mutex.unlock();

                return ret;
            }

            fn free(
                self_opaque: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                ret_addr: usize,
            ) void {
                const self: *Self = @ptrCast(@alignCast(self_opaque));

                self.mutex.lock();
                const ret = self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
                self.mutex.unlock();

                return ret;
            }
        };

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = &VTable.alloc,
            .resize = &VTable.resize,
            .remap = &VTable.remap,
            .free = &VTable.free,
        };

        pub fn init(child: std.mem.Allocator) Self {
            return .{
                .child = child,
            };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = @ptrCast(self),
                .vtable = &Self.vtable,
            };
        }
    };
}

pub fn ConditionVariable(comptime os2: type) type {
    return struct {
        const Self = @This();

        const WaitNode = struct {
            dl_node: std.DoublyLinkedList.Node = .{},

            sema: os2.Semaphore,
        };

        mutex: os2.Mutex,
        waitlist: std.DoublyLinkedList = .{},

        pub fn init() !Self {
            var mutex = try os2.Mutex.init(.{ .name = "a CV internal mutex" });
            errdefer mutex.deinit() catch unreachable;

            return .{
                .mutex = mutex,
            };
        }

        pub fn deinit(self: *Self) void {
            var old_self = blk: {
                self.mutex.acquire(.wait_forever) catch unreachable;
                var old_self = self.*;
                defer old_self.mutex.release() catch unreachable;

                self.* = undefined;

                break :blk old_self;
            };

            old_self.mutex.deinit() catch unreachable;
            _ = wakeAllUp(old_self.waitlist); // no-op in debug builds
        }

        /// Atomically unlocks a mutex and starts waiting for a `notify` or `notify_all` call.
        ///
        /// if `timeout_ns` is null, this function will wait forever.
        pub fn wait(self: *Self, mutex: os2.Mutex, timeout: os2.TimeoutNS) !void {
            var sema = try os2.Semaphore.init(1, 0, .{});

            var node: WaitNode = .{
                .sema = sema,
            };

            {
                self.mutex.acquire(.wait_forever) catch unreachable;
                defer self.mutex.release() catch unreachable;

                self.waitlist.append(&node.dl_node);

                mutex.release() catch unreachable;
            }

            _ = timeout;
            sema.acquire(.wait_forever) catch unreachable;
            mutex.acquire(.wait_forever) catch unreachable;

            sema.deinit() catch unreachable;

            return;
        }

        pub fn notifyOne(self: *Self) bool {
            const maybe_extracted_dl_node = blk: {
                self.mutex.acquire(.wait_forever) catch unreachable;
                defer self.mutex.release() catch unreachable;

                const maybe_extracted_dl_node = self.waitlist.popFirst();

                break :blk maybe_extracted_dl_node;
            };

            if (maybe_extracted_dl_node) |dl_node| {
                wakeOneUp(dl_node);

                return true;
            }

            return false;
        }

        pub fn notifyAll(self: *Self) usize {
            const the_waitlist = blk: {
                self.mutex.acquire(.wait_forever) catch unreachable;
                self.mutex.release() catch unreachable;

                const the_waitlist = self.waitlist;
                self.waitlist = .{};

                break :blk the_waitlist;
            };

            return wakeAllUp(the_waitlist);
        }

        fn wakeOneUp(dl_node: *std.DoublyLinkedList.Node) void {
            const node: *WaitNode = @fieldParentPtr("dl_node", dl_node);

            node.sema.release() catch unreachable;
        }

        fn wakeAllUp(dl: std.DoublyLinkedList) usize {
            var woken_up: usize = 0;

            var mut_dl = dl;

            var no_woken_up: usize = 0;
            while (mut_dl.popFirst()) |dl_node| : (no_woken_up += 1) {
                defer woken_up += 1;

                const node: *WaitNode = @fieldParentPtr("dl_node", dl_node);

                node.sema.release() catch unreachable;
            }

            return no_woken_up;
        }
    };
}

pub fn WaitGroup(comptime os2: type) type {
    return struct {
        const Self = @This();

        cplt_sema: os2.Semaphore,
        count: u32 align(std.atomic.cache_line) = 0,

        pub fn init() !Self {
            var cplt_sema = try os2.Semaphore.init(1, 0, .{});
            errdefer cplt_sema.deinit() catch unreachable;

            return .{
                .cplt_sema = cplt_sema,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cplt_sema.deinit() catch unreachable;
        }

        pub fn add(self: *Self, delta: u32) void {
            _ = @atomicRmw(u32, &self.count, .Add, delta, .acq_rel);
        }

        pub fn done(self: *Self, delta: u32) void {
            const prev = @atomicRmw(u32, &self.count, .Sub, delta, .acq_rel);
            const remaining = prev - delta;

            if (remaining == 0) {
                self.cplt_sema.release() catch unreachable;
            }
        }

        pub fn wait(self: *Self) void {
            self.cplt_sema.acquire(.wait_forever) catch unreachable;
        }
    };
}

pub fn Channel(comptime os2: type, comptime T: type, comptime n: usize) type {
    return struct {
        const Self = @This();

        mutex: os2.Mutex,

        ring_buffer: kompot.RingBuffer(T) = .{
            .storage = undefined,
        },
        buffer: [n]T = undefined,

        pub fn recv(self: *Self) T {
            self.mutex.lock() catch unreachable;
            defer self.mutex.unlock() catch unreachable;

            self.ring_buffer.storage = &self.buffer;

            {
                var elem: T = undefined;
                const num_read = self.ring_buffer.read(&elem[0..1]);
                if (num_read != 0) {
                    return elem;
                }
            }
        }
    };
}
