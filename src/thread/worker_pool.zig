const std = @import("std");
const kompot = @import("../root.zig");

const Channel = kompot.thread.Channel;

pub fn WorkerPool(comptime Context: type, comptime Work: type, comptime Result: type) type {
    return struct {
        const Self = @This();

        const ResultInfo = struct {
            for_work: Work,
            counter_during: usize,
            by_worker: usize,
        };

        alloc: std.mem.Allocator,

        // contains 2x the thread count of Result object
        result_storage: []*Result,

        work_producer: std.Thread,
        workers: []std.Thread,

        producing_work: bool = false,
        outstanding_work: u32 = 0,
        context: ?*Context = null,

        chan_context: Channel(*Context) = .{},
        chan_work: Channel(Work) = .{},
        chan_result: Channel(ResultInfo) = .{
            .open = false,
        },

        pub fn init(
            no_threads: usize,
            alloc: std.mem.Allocator,
            comptime work_producer_fn: anytype,
            comptime worker_fn: anytype,
        ) !*Self {
            const storage = try alloc.alloc(*Result, no_threads * 3);
            var managed_to_allocate: usize = 0;
            errdefer for (0..managed_to_allocate) |i| alloc.destroy(storage[i]);
            for (0..no_threads * 3) |i| {
                storage[i] = try alloc.create(Result);
                managed_to_allocate += 1;
            }

            const workers = try alloc.alloc(std.Thread, no_threads);
            errdefer alloc.free(workers);

            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            self.* = .{
                .alloc = alloc,

                .result_storage = storage,

                .work_producer = undefined,
                .workers = workers,
            };

            const work_producer = try std.Thread.spawn(.{
                .allocator = alloc,
            }, Self.work_producer_wrapper, .{
                self,
                work_producer_fn,
            });
            errdefer {
                self.quit();
                work_producer.join();
            }

            self.work_producer = work_producer;

            var managed_to_spawn: usize = 0;
            for (0..no_threads) |no| {
                self.workers[no] = try std.Thread.spawn(.{
                    .allocator = alloc,
                }, Self.worker_wrapper, .{
                    self,
                    worker_fn,
                    no,
                });
                managed_to_spawn += 1;
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.quit();
            self.work_producer.join();
            for (self.workers) |worker| worker.join();

            self.alloc.free(self.workers);
            for (self.result_storage) |p| self.alloc.destroy(p);
            self.alloc.free(self.result_storage);
        }

        fn quit(self: *Self) void {
            self.chan_context.close();
            self.chan_work.close();
            self.chan_result.close();
        }

        fn worker_wrapper(self: *Self, comptime worker_fn: anytype, no: usize) void {
            var counter: usize = 0;
            while (true) {
                const work = self.chan_work.recv() orelse return;

                const result_ptr = self.result_storage[no * 3 + counter % 3];
                @call(.auto, worker_fn, .{
                    self.context.?,
                    result_ptr,
                    work,
                });

                if (!self.chan_result.send(.{
                    .for_work = work,
                    .counter_during = counter,
                    .by_worker = no,
                })) {
                    return;
                }
                if (@atomicRmw(u32, &self.outstanding_work, .Sub, 1, .seq_cst) == 1 and !@atomicLoad(bool, &self.producing_work, .seq_cst)) {
                    self.context = null;
                    self.chan_result.close();
                }

                counter += 1;
            }
        }

        pub fn get_result(self: *Self) ?struct {
            for_work: Work,
            result: *Result,
        } {
            const res_info = self.chan_result.recv() orelse return null;

            const base_offset = res_info.by_worker * 3;
            const swap_offset = res_info.counter_during % 3;
            const result_ptr = self.result_storage[base_offset + swap_offset];

            return .{
                .for_work = res_info.for_work,
                .result = result_ptr,
            };
        }

        fn work_producer_wrapper(self: *Self, comptime producer: anytype) void {
            while (true) {
                const ctx = self.chan_context.recv() orelse return;
                std.debug.assert(@atomicLoad(u32, &self.outstanding_work, .seq_cst) == 0);

                self.context = ctx;
                self.producing_work = true; // atomicity doesn't matter here

                var prev = @call(.auto, producer, .{ctx}) orelse {
                    self.context = null;
                    self.producing_work = false;
                    self.chan_result.close();
                    continue;
                };

                while (true) {
                    const to_send = prev;
                    prev = @call(.auto, producer, .{ctx}) orelse break;

                    _ = @atomicRmw(u32, &self.outstanding_work, .Add, 1, .seq_cst);
                    if (!self.chan_work.send(to_send)) return;
                }

                _ = @atomicRmw(u32, &self.outstanding_work, .Add, 1, .seq_cst);
                @atomicStore(bool, &self.producing_work, false, .seq_cst);
                if (!self.chan_work.send(prev)) return;
            }
        }

        pub fn begin_work(self: *Self, context: *Context) void {
            self.chan_result.open = true;
            _ = self.chan_context.send(context);
        }
    };
}

test WorkerPool {
    const alloc = std.testing.allocator;

    const Work = struct {
        a: u64,
        x: u64,
        b: u64,
    };

    const Result = struct {
        values: [8]u64,
    };

    const Context = struct {
        i: u64,
    };

    var pool = try WorkerPool(Context, Work, Result).init(
        2,
        alloc,
        struct {
            fn aufruf(ctx: *Context) ?Work {
                if (ctx.i > 8) {
                    return null;
                }

                defer ctx.i += 1;
                return .{
                    .a = ctx.i * 3 + 0,
                    .x = ctx.i * 3 + 1,
                    .b = ctx.i * 3 + 2,
                };
            }
        }.aufruf,

        struct {
            fn aufruf(ctx: *Context, out_result: *Result, work: Work) void {
                var values: [8]u64 = .{0} ** 6 ++ .{ work.a, work.b };

                for (0..work.x) |_| {
                    const c = values[6] +% values[7];
                    for (0..7) |i| values[i] = values[i + 1];
                    values[7] = c;
                }

                std.Thread.sleep(50 * std.time.ns_per_ms);

                out_result.* = .{
                    .values = values,
                };
                _ = ctx;
            }
        }.aufruf,
    );

    std.log.debug("main thread: finished init of pool", .{});

    var ctx: Context = .{
        .i = 0,
    };
    std.log.debug("main thread: going to call pool.begin_work", .{});
    pool.begin_work(&ctx);

    while (pool.get_result()) |result| {
        std.log.debug("main thread: got result: {any}", .{result.result});
    }

    ctx.i = 0;
    std.log.debug("main thread: going to call pool.begin_work", .{});
    pool.begin_work(&ctx);

    while (pool.get_result()) |result| {
        std.log.debug("main thread: got result: {any}", .{result.result});
    }

    std.log.debug("main thread: going to call pool.deinit", .{});
    pool.deinit();

    std.log.debug("main thread: done", .{});

    alloc.destroy(pool);
}
