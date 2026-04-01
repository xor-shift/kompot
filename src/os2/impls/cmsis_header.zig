const std = @import("std");

const reference = @import("single_threaded.zig");

/// pass something like:
///
/// ```zig
/// @cImport({
///     @cInclude("cmsis_os2.h");
/// });
/// ```
///
/// as `c`
pub fn Impl(comptime c: type) type {
    return struct {
        pub const Error = reference.Error;
        pub const TimeoutNS = reference.TimeoutNS;

        fn handleError(ret: c_int) Error!c_int {
            if (ret < 0) return switch (ret) {
                c.osError => Error.Unspecified,
                c.osErrorTimeout => Error.Timeout,
                c.osErrorResource => Error.Resource,
                c.osErrorParameter => Error.Parameter,
                c.osErrorNoMemory => Error.NoMemory,
                c.osErrorISR => Error.Isr,
                else => unreachable,
            };

            return ret;
        }

        fn splitNanosecs(nanoseconds: u64) struct {
            ticks: u32,
            leftover_ticks: u32,
            leftover_ns: u64,
        } {
            const ticks_per_sec: u128 = @intCast(c.osKernelGetTickFreq());
            const nsec_per_tick = std.time.ns_per_s / ticks_per_sec;

            const raw_ticks = nanoseconds / nsec_per_tick;

            const max_delay: u128 = std.math.maxInt(u32) - 1;
            const actual_ticks = @min(max_delay, raw_ticks);

            const leftover_ticks = raw_ticks - actual_ticks;
            const leftover_ns = nanoseconds - raw_ticks * nsec_per_tick;

            return .{
                .ticks = @intCast(actual_ticks),
                .leftover_ticks = @intCast(leftover_ticks),
                .leftover_ns = @intCast(leftover_ns),
            };
        }

        fn delayImpl(nanoseconds: u64, comptime precise: bool) Error!void {
            const split = splitNanosecs(nanoseconds);

            _ = try handleError(c.osDelay(@intCast(split.ticks)));

            // TODO
            if (precise) {
                _ = split.leftover_ns;
            }
        }

        pub fn delay(nanoseconds: u64) Error!void {
            return delayImpl(nanoseconds, false);
        }

        pub const kernel = struct {
            pub const State = enum {
                inactive,
                ready,
                running,
                locked,
                suspended,
            };

            pub fn initialize() Error!void {
                _ = try handleError(c.osKernelInitialize());
            }

            pub fn start() Error!noreturn {
                _ = try handleError(c.osKernelStart());
                unreachable;
            }

            /// The return value represents the previous lock state.
            ///
            /// If `true` is returned, it means that the kernel was previously locked.
            ///
            /// If `false` is returned, it means that the kernel was previously
            /// unlocked.
            pub fn lock() Error!bool {
                const res = try handleError(c.osKernelLock());

                if (res == 0) return false;
                if (res == 1) return true;

                unreachable;
            }

            /// The return value represents the previous lock state.
            ///
            /// If `true` is returned, it means that the kernel was previously locked.
            ///
            /// If `false` is returned, it means that the kernel was previously
            /// unlocked.
            pub fn unlock() Error!bool {
                const res = try handleError(c.osKernelUnlock());

                if (res == 0) return false;
                if (res == 1) return true;

                unreachable;
            }

            pub fn restoreLock(previously_locked: bool) Error!bool {
                const res = try handleError(c.osKernelRestoreLock(@intCast(@intFromBool(previously_locked))));

                if (res == 0) return false;
                if (res == 1) return true;

                unreachable;
            }

            pub fn getState() Error!State {
                const state_raw = c.osKernelGetState();
                const state: State = switch (state_raw) {
                    c.osKernelInactive => State.inactive,
                    c.osKernelReady => State.ready,
                    c.osKernelRunning => State.running,
                    c.osKernelLocked => State.locked,
                    c.osKernelSuspended => State.suspended,
                    else => return Error.Unspecified,
                };
                return state;
            }
        };

        pub const Thread = struct {
            pub const Settings = reference.Thread.Settings;
            pub const Id = c.osThreadId_t;
            pub const sentinel_id: Id = null;

            handle: Id,

            fn makeAttrBits(flags: Settings.Flags) @FieldType(c.osThreadAttr_t, "attr_bits") {
                var ret: @FieldType(c.osThreadAttr_t, "attr_bits") = 0;

                if (flags.joinable) ret |= c.osThreadJoinable;
                if (flags.privileged) ret |= c.osThreadPrivileged;
                if (flags.unprivileged) ret |= c.osThreadUnprivileged;

                return ret;
            }

            pub fn yield() Error!void {
                _ = try handleError(c.osThreadYield());
            }

            pub fn getId() Error!Id {
                const res = c.osThreadGetId();
                if (res == null) return Error.Unspecified;

                return res;
            }

            pub fn initRaw(
                settings: Settings,
                fun: *const fn (arg: ?*anyopaque) callconv(.c) void,
                arg: ?*anyopaque,
            ) Error!Thread {
                var attrs: c.osThreadAttr_t = .{
                    .name = if (settings.name) |name| name.ptr else null,
                    .attr_bits = makeAttrBits(settings.flags),
                    .cb_mem = null,
                    .cb_size = 0,
                    .stack_mem = undefined,
                    .stack_size = undefined,
                    .priority = @intCast(@intFromEnum(settings.priority)),
                    .tz_module = 0,
                    .affinity_mask = 0,
                };

                if (settings.static_memory) |static_memory| {
                    attrs.cb_mem = @ptrCast(static_memory.ptr);
                    attrs.cb_size = @intCast(static_memory.len);
                }

                switch (settings.stack) {
                    .manual => |slice| {
                        attrs.stack_mem = @ptrCast(slice.ptr);
                        attrs.stack_size = @intCast(slice.len);
                    },
                    .automatic => |size| {
                        attrs.stack_mem = null;
                        attrs.stack_size = @intCast(size);
                    },
                }

                const handle = c.osThreadNew(fun, arg, &attrs) orelse {
                    return Error.Unspecified;
                };

                return .{
                    .handle = handle,
                };
            }

            pub fn deinit(self: Thread) !void {
                _ = try handleError(c.osThreadTerminate(self.handle));
            }

            pub fn exit() noreturn {
                return c.osThreadExit();
            }

            pub fn join(self: Thread) void {
                _ = self;
                @panic("NYI");
                // c.osThreadJoin(self.handle);
            }
        };

        pub const Semaphore = struct {
            pub const Settings = reference.Semaphore.Settings;

            handle: c.osSemaphoreId_t,

            pub fn init(max_count: usize, initial_count: usize, settings: Settings) Error!Semaphore {
                const attr: c.osSemaphoreAttr_t = .{
                    .name = if (settings.name) |name| name.ptr else null,
                    .attr_bits = 0,

                    .cb_mem = if (settings.static_memory) |static_memory|
                        @as(*anyopaque, @ptrCast(static_memory.ptr))
                    else
                        null,

                    .cb_size = if (settings.static_memory) |static_memory|
                        @as(@FieldType(c.osSemaphoreAttr_t, "cb_size"), @intCast(static_memory.len))
                    else
                        0,
                };

                const maybe_handle = c.osSemaphoreNew(@intCast(max_count), @intCast(initial_count), &attr);
                const handle = maybe_handle orelse {
                    @panic("unhandled error");
                };

                return .{
                    .handle = handle,
                };
            }

            pub fn deinit(self: Semaphore) Error!void {
                _ = try handleError(c.osSemaphoreDelete(self.handle));
            }

            pub fn getName(self: Semaphore) [:0]const u8 {
                const maybe_name = c.osSemaphoreGetName(self.handle);
                const name_improper = maybe_name orelse {
                    @panic("unhandled error");
                };

                const name: [*:0]const u8 = @ptrCast(name_improper);

                return std.mem.span(name);
            }

            pub fn acquire(self: *Semaphore, timeout_ns: TimeoutNS) Error!void {
                switch (timeout_ns) {
                    .dont_wait => _ = try handleError(c.osSemaphoreAcquire(self.handle, 0)),
                    .wait_forever => _ = try handleError(c.osSemaphoreAcquire(self.handle, c.osWaitForever)),
                    else => |v| {
                        const split = splitNanosecs(@intFromEnum(v));
                        const ticks = if (split.ticks == 0) 1 else split.ticks;
                        _ = try handleError(c.osSemaphoreAcquire(self.handle, ticks));
                    },
                }
            }

            pub fn release(self: *Semaphore) Error!void {
                _ = try handleError(c.osSemaphoreRelease(self.handle));
            }

            pub fn getCount(self: Semaphore) usize {
                return @intCast(c.osSemaphoreGetCount(self.handle));
            }
        };

        const MutexImpl = struct {
            pub const Settings = reference.Mutex.Settings;

            handle: c.osMutexId_t,

            const MutexFlags = packed struct {
                const Bits = @FieldType(c.osMutexAttr_t, "attr_bits");

                recursive: bool = false,
                priority_inherit: bool = false,
                robust: bool = false,

                fn toBits(self: MutexFlags) Bits {
                    var ret: Bits = 0;

                    if (self.recursive) ret |= c.osMutexRecursive;
                    if (self.priority_inherit) ret |= c.osMutexPrioInherit;
                    if (self.robust) ret |= c.osMutexRobust;

                    return ret;
                }
            };

            pub fn init(settings: Settings, flags: MutexFlags) Error!MutexImpl {
                const attrs: c.osMutexAttr_t = .{
                    .name = if (settings.name) |name| name.ptr else null,
                    .attr_bits = flags.toBits(),

                    .cb_mem = if (settings.static_memory) |static_memory|
                        @as(*anyopaque, @ptrCast(static_memory.ptr))
                    else
                        null,

                    .cb_size = if (settings.static_memory) |static_memory|
                        @as(@FieldType(c.osMutexAttr_t, "cb_size"), @intCast(static_memory.len))
                    else
                        0,
                };

                const res = c.osMutexNew(&attrs) orelse {
                    return Error.Unspecified;
                };

                return .{
                    .handle = res,
                };
            }

            pub fn deinit(self: MutexImpl) Error!void {
                _ = try handleError(c.osMutexDelete(self.handle));
            }

            pub fn getName(self: MutexImpl) [:0]const u8 {
                const maybe_name = c.osMutexGetName(self.handle);
                const name_improper = maybe_name orelse {
                    @panic("unhandled error");
                };

                const name: [*:0]const u8 = @ptrCast(name_improper);

                return std.mem.span(name);
            }

            pub fn acquire(self: MutexImpl, timeout_ns: TimeoutNS) Error!void {
                switch (timeout_ns) {
                    .dont_wait => _ = try handleError(c.osMutexAcquire(self.handle, 0)),
                    .wait_forever => _ = try handleError(c.osMutexAcquire(self.handle, c.osWaitForever)),
                    else => |v| {
                        const split = splitNanosecs(@intFromEnum(v));
                        const ticks = if (split.ticks == 0) 1 else split.ticks;
                        _ = try handleError(c.osMutexAcquire(self.handle, ticks));
                    },
                }
            }

            pub fn release(self: MutexImpl) Error!void {
                _ = try handleError(c.osMutexRelease(self.handle));
            }

            pub fn getOwner(self: MutexImpl) Error!?Thread {
                // TODO: errors can't be detected here
                const owner = c.osMutexGetOwner(self.handle);

                return .{
                    .handle = owner,
                };
            }
        };

        pub const Mutex = struct {
            pub const Settings = reference.Mutex.Settings;

            inner: MutexImpl,

            pub fn init(settings: Settings) Error!Mutex {
                return .{
                    .inner = try .init(settings, .{}),
                };
            }

            pub fn deinit(self: Mutex) Error!void {
                return self.inner.deinit();
            }

            pub fn getName(self: Mutex) [:0]const u8 {
                return self.inner.getName();
            }

            pub fn acquire(self: Mutex, timeout_ns: TimeoutNS) Error!void {
                return self.inner.acquire(timeout_ns);
            }

            pub fn release(self: Mutex) Error!void {
                return self.inner.release();
            }

            pub fn getOwner(self: Mutex) Error!?Thread {
                return self.inner.release();
            }
        };

        pub const RecursiveMutex = struct {
            pub const Settings = reference.Mutex.Settings;

            inner: MutexImpl,

            pub fn init(settings: Settings) Error!Mutex {
                return .{
                    .inner = try .init(settings, .{
                        .recursive = true,
                    }),
                };
            }

            pub fn deinit(self: Mutex) Error!void {
                return self.inner.deinit();
            }

            pub fn getName(self: Mutex) [:0]const u8 {
                return self.inner.getName();
            }

            pub fn acquire(self: Mutex, timeout_ns: TimeoutNS) Error!void {
                return self.inner.acquire(timeout_ns);
            }

            pub fn release(self: Mutex) Error!void {
                return self.inner.release();
            }

            pub fn getOwner(self: Mutex) Error!?Thread {
                return self.inner.release();
            }
        };
    };
}
