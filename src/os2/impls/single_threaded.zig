const std = @import("std");

pub const DummySupportFunctions = struct {
    pub fn getNanos() u64 {
        @panic("not implemented");
    }

    pub fn delay(nanoseconds: u64) void {
        _ = nanoseconds;
        @panic("not implemented");
    }

    pub fn wfi() void {
        @panic("not implemented");
    }
};

pub fn Impl(comptime support_functions: type) type {
    return struct {
        pub const Error = error{
            /// Unspecified RTOS error: run-time error but no other error
            /// message fits.
            Unspecified,

            /// Operation not completed within the timeout period.
            Timeout,

            /// Resource not available.
            Resource,

            /// Parameter error.
            Parameter,

            /// System is out of memory: it was impossible to allocate or
            /// reserve memory for the operation.
            NoMemory,

            /// Not allowed in ISR context: the function cannot be called from
            /// interrupt service routines.
            Isr,
        };

        /// A timeout value of `dont_wait` will make the function the timeout
        /// value is given to return instantly and `wait_forever` will make it
        /// wait forever. All other values are in nanoseconds.
        ///
        /// The normal timeout value gets rounded down to the nearest
        /// tick. Timeout values that would have gotten rounded down to 0 ticks
        /// will get rounded up to 1 tick.
        pub const TimeoutNS = enum(u64) {
            dont_wait = 0,
            wait_forever = std.math.maxInt(u64),
            _,
        };

        /// This function is best-effort and might over- or undershoot the
        /// given nanoseconds value.
        ///
        /// A return value of `Error.Parameter` means that the time can't be
        /// handled (0 ticks).
        ///
        /// A return value of `Error.Unspecified` could mean that the kernel is
        /// not running or that no *READY* thread exists.
        pub fn delay(nanoseconds: u64) Error!void {
            support_functions.delay(nanoseconds);
        }

        pub const kernel = struct {
            pub const State = enum {
                inactive,
                ready,
                running,
                locked,
                suspended,
            };

            const ThreadData = struct {
                name: ?[:0]const u8,
                fun: *const fn (arg: ?*anyopaque) callconv(.c) void,
                arg: ?*anyopaque,
            };

            var pending_threads_arr: [16]ThreadData = undefined;
            var num_pending_threads: usize = 0;
            var active_thread_idx: ?usize = null;

            var state: State = .inactive;

            pub fn initialize() Error!void {
                state = .ready;
            }

            pub fn start() Error!noreturn {
                for (0..num_pending_threads) |i| {
                    state = .suspended;
                    active_thread_idx = null;

                    const data = pending_threads_arr[i];

                    active_thread_idx = i;
                    state = .running;
                    data.fun(data.arg);
                }

                active_thread_idx = null;
                state = .suspended;

                @panic("ran out of work");
            }

            var kernel_lock_nesting: usize = 0;

            pub fn lock() Error!bool {
                if (state == .inactive or state == .ready or state == .suspended) return false;

                defer kernel_lock_nesting += 1;
                state = .locked;
                return kernel_lock_nesting == 0;
            }

            pub fn unlock() Error!bool {
                if (state == .inactive or state == .ready or state == .suspended) return true;

                defer if (kernel_lock_nesting == 0) {
                    state = .running;
                };

                defer kernel_lock_nesting -= 1;

                return kernel_lock_nesting != 0;
            }

            pub fn restoreLock(previously_locked: bool) Error!bool {
                if (previously_locked) return lock();
                return unlock();
            }

            pub fn getState() Error!State {
                return state;
            }
        };

        pub const Thread = struct {
            pub const Id = ?*anyopaque;
            pub const sentinel_id: Id = null;

            pub const Settings = struct {
                pub const Flags = packed struct {
                    joinable: bool = false,
                    unprivileged: bool = false,
                    privileged: bool = false,
                };

                pub const Priority = enum(u32) {
                    none = 0,
                    idle = 1,
                    low = 8,
                    low_1 = 8 + 1,
                    low_2 = 8 + 2,
                    low_3 = 8 + 3,
                    low_4 = 8 + 4,
                    low_5 = 8 + 5,
                    low_6 = 8 + 6,
                    low_7 = 8 + 7,
                    below_normal = 16,
                    below_normal_1 = 16 + 1,
                    below_normal_2 = 16 + 2,
                    below_normal_3 = 16 + 3,
                    below_normal_4 = 16 + 4,
                    below_normal_5 = 16 + 5,
                    below_normal_6 = 16 + 6,
                    below_normal_7 = 16 + 7,
                    normal = 24,
                    normal_1 = 24 + 1,
                    normal_2 = 24 + 2,
                    normal_3 = 24 + 3,
                    normal_4 = 24 + 4,
                    normal_5 = 24 + 5,
                    normal_6 = 24 + 6,
                    normal_7 = 24 + 7,
                    above_normal = 32,
                    above_normal_1 = 32 + 1,
                    above_normal_2 = 32 + 2,
                    above_normal_3 = 32 + 3,
                    above_normal_4 = 32 + 4,
                    above_normal_5 = 32 + 5,
                    above_normal_6 = 32 + 6,
                    above_normal_7 = 32 + 7,
                    high = 40,
                    high_1 = 40 + 1,
                    high_2 = 40 + 2,
                    high_3 = 40 + 3,
                    high_4 = 40 + 4,
                    high_5 = 40 + 5,
                    high_6 = 40 + 6,
                    high_7 = 40 + 7,
                    realtime = 48,
                    realtime_1 = 48 + 1,
                    realtime_2 = 48 + 2,
                    realtime_3 = 48 + 3,
                    realtime_4 = 48 + 4,
                    realtime_5 = 48 + 5,
                    realtime_6 = 48 + 6,
                    realtime_7 = 48 + 7,
                    isr = 56,
                    _,
                };

                pub const State = enum(u32) {
                    inactive = 0,
                    ready = 1,
                    running = 2,
                    blocked = 3,
                    terminated = 4,
                };

                name: ?[:0]const u8 = null,
                static_memory: ?[]u8 = null,

                stack: union(enum) {
                    manual: []u8,
                    automatic: usize,
                },

                priority: Priority = .normal,
                flags: Flags = .{},
            };

            pub fn initRaw(
                settings: Settings,
                fun: *const fn (arg: ?*anyopaque) callconv(.c) void,
                arg: ?*anyopaque,
            ) Error!Thread {
                kernel.pending_threads_arr[kernel.num_pending_threads] = .{
                    .name = settings.name,
                    .fun = fun,
                    .arg = arg,
                };
                kernel.num_pending_threads += 1;

                return .{
                    .idx = kernel.num_pending_threads - 1,
                };
            }

            pub fn getId() Error!Id {
                return @ptrFromInt((kernel.active_thread_idx orelse return Thread.sentinel_id) + 1);
            }

            idx: usize,
        };

        pub const Semaphore = struct {
            pub const Settings = struct {
                name: ?[:0]const u8 = null,
                static_memory: ?[]u8 = null,
            };

            pub fn init(max_count: usize, initial_count: usize, settings: Settings) Error!Semaphore {
                return .{
                    .name = settings.name,
                    .count = initial_count,
                    .max_count = max_count,
                };
            }

            /// A return value of `Error.Resource` means that the semaphore is
            /// in an invalid state.
            ///
            /// A return value of `Error.Parameter` means that the semaphore
            /// handle is invalid.
            ///
            /// A panic should ideally take place if this function returns an
            /// error.
            pub fn deinit(self: *Semaphore) Error!void {
                _ = self;
            }

            pub fn getName(self: Semaphore) [:0]const u8 {
                return self.name orelse "";
            }

            /// A return value of `Error.Timeout` means that the semaphore
            /// couldn't be acquired in the timeout given.
            ///
            /// A return value of `Error.Resource` means that the semaphore
            /// couldn't be acquired despite there being no timeout.
            ///
            /// A return value of `Error.Parameter` means that the semaphore
            /// handle is invalid.
            pub fn acquire(self: *Semaphore, timeout_ns: TimeoutNS) Error!void {
                while (true) {
                    const count = @atomicLoad(usize, &self.count, .acquire);
                    if (count == 0) {
                        if (timeout_ns == .dont_wait) return Error.Resource;
                        support_functions.wfi();
                        continue;
                    }

                    const res = @cmpxchgWeak(usize, &self.count, count, count - 1, .acq_rel, .acquire);

                    if (res == null) return;
                }
            }

            /// A return value of `Error.Resource` means that the semaphore
            /// couldn't be released as the token count has reached the upper
            /// limit.
            ///
            /// A return value of `Error.Parameter` means that the semaphore
            /// handle is invalid.
            pub fn release(self: *Semaphore) Error!void {
                while (true) {
                    const count = @atomicLoad(usize, &self.count, .acquire);
                    if (count == self.max_count) return Error.Resource;

                    const res = @cmpxchgWeak(usize, &self.count, count, count + 1, .acq_rel, .acquire);

                    if (res == null) return;
                }
            }

            name: ?[:0]const u8,
            count: usize,
            max_count: usize,
        };

        pub const Mutex = struct {
            pub const Settings = struct {
                name: ?[:0]const u8 = null,
                static_memory: ?[]u8 = null,
            };

            name: ?[:0]const u8,
            owner: ?Thread.Id = null,

            pub fn init(settings: Settings) Error!Mutex {
                return .{
                    .name = settings.name,
                };
            }

            pub fn deinit(self: Mutex) Error!void {
                std.debug.assert(self.owner == null);
            }

            pub fn getName(self: Mutex) [:0]const u8 {
                return self.name orelse "";
            }

            pub fn acquire(self: *Mutex, timeout_ns: TimeoutNS) Error!void {
                _ = timeout_ns;

                std.debug.assert(self.owner == null);
                self.owner = try Thread.getId();
            }

            pub fn release(self: *Mutex) Error!void {
                std.debug.assert(self.owner == try Thread.getId());
                self.owner = null;
            }

            pub fn getOwner(self: Mutex) Error!?Thread {
                _ = self;
                return Error.Unspecified;
            }
        };

        pub const RecursiveMutex = struct {
            pub const Settings = Mutex.Settings;
        };
    };
}
