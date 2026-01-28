const std = @import("std");

pub fn TearingAtomicUint(comptime bits: usize) type {
    return struct {
        const Self = @This();

        pub const Int = std.meta.Int(.unsigned, bits);

        const Atomic = usize;
        const k_num_atomic = (bits + @bitSizeOf(Atomic) - 1) / @bitSizeOf(Atomic);

        const Data = [k_num_atomic]Atomic;
        const Meta = packed struct(usize) {
            generation: std.meta.Int(.unsigned, @bitSizeOf(usize) - 1) = 0,
            is_being_edited: bool = false,

            fn load(from: *usize) Meta {
                const as_usize = @atomicLoad(usize, from, .acquire);
                return @bitCast(as_usize);
            }

            fn store(self: Meta, to: *usize) void {
                const as_usize: usize = @bitCast(self);
                @atomicStore(usize, to, as_usize, .release);
            }

            /// Returns `null` if `expected` was the value stored in `to_and_from`, the old value otherwise.
            fn cmpxchg(
                comptime strong: bool,
                to_and_from: *usize,
                expected: Meta,
                new: Meta,
            ) ?Meta {
                const maybe_old_value_as_usze = if (strong)
                    @cmpxchgStrong(usize, to_and_from, @bitCast(expected), @bitCast(new), .acq_rel, .acquire)
                else
                    @cmpxchgWeak(usize, to_and_from, @bitCast(expected), @bitCast(new), .acq_rel, .acquire);

                if (maybe_old_value_as_usze) |old_value_as_usize| {
                    return @bitCast(old_value_as_usize);
                }

                return null;
            }
        };

        meta: usize = 0,
        data: Data = .{0} ** k_num_atomic,

        pub fn init(v: Int) Self {
            return .{
                .data = Self.dataFromInt(v),
            };
        }

        fn intFromData(data: Data) Int {
            var ret: Int = undefined;

            const ret_bytes = std.mem.asBytes(&ret);
            const data_bytes = std.mem.asBytes(&data);

            @memcpy(ret_bytes, data_bytes);

            return ret;
        }

        fn dataFromInt(int: Int) Data {
            var ret: Data = undefined;

            const ret_bytes = std.mem.asBytes(&ret);
            const int_bytes = std.mem.asBytes(&int);

            @memcpy(ret_bytes, int_bytes);

            return ret;
        }

        /// If there's a single writer, this function is guaranteed to succeed.
        pub fn tryStoreImpl(
            self: *Self,
            comptime strong: bool,
            v: Int,
            maybe_expected_generation: ?usize,
        ) bool {
            const to_store = Self.dataFromInt(v);

            const meta_0: Meta = .load(&self.meta);

            if (meta_0.is_being_edited) {
                return false;
            }

            if (maybe_expected_generation) |expected_generation| {
                if (meta_0.generation != expected_generation) return false;
            }

            if (Meta.cmpxchg(strong, &self.meta, meta_0, .{
                .is_being_edited = true,
                .generation = meta_0.generation,
            }) != null) {
                return false;
            }

            for (to_store, 0..) |atomic_to_store, i| {
                @atomicStore(Atomic, &self.data[i], atomic_to_store, .release);
            }

            const new_meta: Meta = .{
                .is_being_edited = false,
                .generation = meta_0.generation +% 1,
            };
            new_meta.store(&self.meta);

            return true;
        }

        const LoadRes = struct {
            generation: usize,
            v: Int,
        };

        /// If there's a single writer, this function is guaranteed to succeed
        /// for the writer.
        pub fn tryLoadImpl(
            self: *Self,
        ) ?LoadRes {
            const meta_0: Meta = .load(&self.meta);

            if (meta_0.is_being_edited) {
                return null;
            }

            var data: Data = undefined;
            for (&self.data, 0..) |*atomic_to_load, i| {
                data[i] = @atomicLoad(Atomic, atomic_to_load, .acquire);
            }

            const meta_1: Meta = .load(&self.meta);

            // tore
            if (meta_0.is_being_edited != meta_1.is_being_edited) return null;
            if (meta_0.generation != meta_1.generation) return null;

            return .{ .generation = meta_0.generation, .v = Self.intFromData(data) };
        }

        pub fn tryLoad(self: *Self) ?Int {
            const maybe_load_res = self.tryLoadImpl();
            if (maybe_load_res) |load_res| {
                return load_res.v;
            }

            return null;
        }

        pub fn load(self: *Self) Int {
            while (true) {
                const maybe_v = self.tryLoad();
                if (maybe_v) |v| return v;
            }

            unreachable;
        }

        /// For the current value stored named `cur_value`, `op_fun` will be
        /// called like: `op_fun(cur_value, ...args)` as if by C++ pack
        /// expansion.
        ///
        /// If there's a single writer, this function is guaranteed to succeed.
        pub fn rmw(
            self: *Self,
            comptime strong: bool,
            comptime op_fun: anytype,
            args: anytype,
        ) ?Int {
            const load_res = self.tryLoadImpl() orelse return null;

            const new_value = @call(.auto, op_fun, .{load_res.v} ++ args);

            if (!self.tryStoreImpl(strong, new_value, load_res.generation)) return null;

            return load_res.v;
        }

        const default_ops = struct {
            fn add(lhs: Int, rhs: Int) Int {
                return lhs + rhs;
            }

            fn sub(lhs: Int, rhs: Int) Int {
                return lhs - rhs;
            }

            fn mul(lhs: Int, rhs: Int) Int {
                return lhs * rhs;
            }

            fn div(lhs: Int, rhs: Int) Int {
                return lhs / rhs;
            }
        };

        fn tryOpFactory(comptime op: anytype) fn (self: *Self, comptime strong: bool, v: Int) ?Int {
            return struct {
                fn aufruf(self: *Self, comptime strong: bool, v: Int) ?Int {
                    return self.rmw(strong, op, .{v});
                }
            }.aufruf;
        }

        fn opFactory(comptime op: anytype) fn (self: *Self, v: Int) Int {
            return struct {
                fn aufruf(self: *Self, v: Int) Int {
                    while (true) {
                        const maybe_res = self.rmw(true, op, .{v});
                        if (maybe_res) |res| {
                            return res;
                        }
                    }

                    unreachable;
                }
            }.aufruf;
        }

        /// Adds `v` to the internal representation and returns the old value.
        ///
        /// Returns `null` if the operation wasn't succesful.
        pub fn tryFetchAdd(self: *Self, comptime strong: bool, v: Int) ?Int {
            return self.rmw(strong, default_ops.add, .{v});
        }

        /// Subtracts `v` from the internal representation and returns the old
        /// value.
        ///
        /// Returns `null` if the operation wasn't succesful.
        ///
        /// See the implementation of `tryFetchAdd` to see how this function works.
        const tryFetchSub = tryOpFactory(default_ops.sub);

        /// Multiplies the internal representation with `v` and returns the old
        /// value.
        ///
        /// Returns `null` if the operation wasn't succesful.
        ///
        /// See the implementation of `tryFetchAdd` to see how this function works.
        const tryFetchMul = tryOpFactory(default_ops.mul);

        /// Divides the internal representation by `v` and returns the old
        /// value.
        ///
        /// Returns `null` if the operation wasn't succesful.
        ///
        /// See the implementation of `tryFetchAdd` to see how this function works.
        const tryFetchDiv = tryOpFactory(default_ops.div);

        /// Adds `v` to the internal representation and returns the old value.
        ///
        /// Guaranteed to succeed but might spin.
        pub fn fetchAdd(self: *Self, v: Int) Int {
            while (true) {
                const maybe_res = self.rmw(true, default_ops.add, .{v});
                if (maybe_res) |res| {
                    return res;
                }
            }

            unreachable;
        }

        /// Subtracts `v` from the internal representation and returns the old
        /// value.
        ///
        /// Guaranteed to succeed but might spin.
        ///
        /// See the implementation of `fetchAdd` to see how this function works.
        const fetchSub = opFactory(default_ops.sub);

        /// Multiplies the internal representation with `v` and returns the old
        /// value.
        ///
        /// Guaranteed to succeed but might spin.
        ///
        /// See the implementation of `fetchAdd` to see how this function works.
        const fetchMul = opFactory(default_ops.mul);

        /// Divides the internal representation by `v` and returns the old
        /// value.
        ///
        /// Guaranteed to succeed but might spin.
        ///
        /// See the implementation of `fetchAdd` to see how this function works.
        const fetchDiv = opFactory(default_ops.div);
    };
}

const TestContextBase = struct {
    const Self = @This();

    go_signal_mutex: std.Thread.Mutex = .{},
    go_signal_cv: std.Thread.Condition = .{},
    go_signal: bool = false,
    bail_signal: bool = false,

    // The only argument passed to the threads will be the base context and the
    // thread number. Use @fieldParentPtr afterward to get the actual context.
    fn spawnMultipleThreads(
        self: *Self,
        comptime n: usize,
        comptime fun: fn (*Self, usize) void,
    ) ![n]std.Thread {
        var threads: [n]std.Thread = undefined;
        var initialised_upto: usize = 0;

        errdefer {
            self.giveBailSignal();
            for (0..initialised_upto) |i| threads[i].join();
        }

        for (0..n) |i| {
            threads[i] = try std.Thread.spawn(.{}, fun, .{ self, i });
            initialised_upto += 1;
        }

        return threads;
    }

    /// if this returns true, proceed, otherwise bail.
    pub fn threadWait(self: *Self) bool {
        self.go_signal_mutex.lock();
        defer self.go_signal_mutex.unlock();

        while (true) {
            if (self.bail_signal) return false;
            if (self.go_signal) return true;

            self.go_signal_cv.wait(&self.go_signal_mutex);
        }
    }

    fn giveSignal(self: *Self, go: bool) void {
        self.go_signal_mutex.lock();
        defer self.go_signal_mutex.unlock();

        if (go) self.go_signal = true else self.bail_signal = true;

        self.go_signal_cv.broadcast();
    }

    pub fn giveGoSignal(self: *Self) void {
        self.giveSignal(true);
    }

    pub fn giveBailSignal(self: *Self) void {
        self.giveSignal(false);
    }
};

test TearingAtomicUint {
    const k_no_threads = 16;
    const k_iters = 64;

    var the_buffer: [k_no_threads * k_iters]usize = .{0} ** (k_no_threads * k_iters);

    const Context = struct {
        base: TestContextBase = .{},

        the_buffer: []usize,
        the_integer: TearingAtomicUint(321) = .{},

        fn aufruf(base_context: *TestContextBase, _: usize) void {
            const context: *@This() = @alignCast(@fieldParentPtr("base", base_context));

            if (!context.base.threadWait()) return;

            for (0..k_iters) |_| {
                const the_index = context.the_integer.fetchAdd(1);
                const the_index_as_usize: usize = @intCast(the_index);

                // std.log.debug("{d}", .{the_index_as_usize});

                context.the_buffer[the_index_as_usize] = the_index_as_usize;
                // @atomicStore(usize, &context.the_buffer[the_index_as_usize], the_index_as_usize, .release);
            }
        }
    };

    var context: Context = .{
        .the_buffer = &the_buffer,
    };

    const threads = try context.base.spawnMultipleThreads(k_no_threads, Context.aufruf);
    context.base.giveGoSignal();

    for (&threads) |*t| t.join();

    //std.log.debug("final generation: {d}", .{context.the_integer.meta});
    try std.testing.expectEqual(k_iters * k_no_threads, context.the_integer.meta);
    for (the_buffer, 0..) |v, i| {
        // std.log.debug("arr[{d}] = {d}", .{ i, v });
        try std.testing.expectEqual(i, v);
    }
}
