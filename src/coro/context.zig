const std = @import("std");

const kompot = @import("../root.zig");

const Port = @import("Port.zig");

pub fn Context(comptime port: Port) type {
    return struct {
        const Self = @This();

        pub const Thread = @import("thread.zig").Thread(port);
        pub const Task = @import("task.zig").Task(port);

        pub const TaskNode = struct {
            ll_node: std.DoublyLinkedList.Node,
            task: Task,
        };

        const ThreadNode = struct {
            ll_node: std.DoublyLinkedList.Node,
            thread: Thread,
        };

        allocator: std.mem.Allocator,

        task_queue_mutex: port.Mutex = .{},
        tasks_are_available: std.atomic.Value(u32) = .init(0),
        no_tasks: usize = 0,
        task_queue: std.DoublyLinkedList = .{},
        suspended_tasks_list: std.DoublyLinkedList = .{},

        terminated_tasks_mutex: port.Mutex = .{},
        terminated_tasks: std.DoublyLinkedList = .{},

        threads_mutex: port.Mutex = .{},
        threads: std.DoublyLinkedList = .{},

        pub fn init(
            allocator: std.mem.Allocator,
        ) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn makeThread(self: *Self) !*Thread {
            const thread_node = try self.allocator.create(ThreadNode);
            errdefer self.allocator.destroy(thread_node);

            thread_node.thread = .init(self, self.allocator);

            self.threads_mutex.lock();
            self.threads.append(&thread_node.ll_node);
            self.threads_mutex.unlock();

            return &thread_node.thread;
        }

        /// Externally synchronized.
        fn changeNoTasks(self: *Self, op: enum { add, sub }, delta: usize) void {
            switch (op) {
                .add => {
                    self.no_tasks += delta;

                    // synchronized-with with other threads due to the mutex
                    self.tasks_are_available.raw = 1;
                    port.Futex.wake(&self.global_tasks_are_available, std.math.maxInt(u32));
                },
                .sub => {
                    self.no_tasks -= delta;

                    if (self.no_tasks == 0) {
                        // synchronized-with with other threads due to the mutex
                        self.tasks_are_available = 0;
                    }
                },
            }
        }

        pub fn launch(self: *Self, fun: anytype, args: anytype) !*Task {
            const stack = try self.allocator.alloc(u8, port.initial_stack_size);
            errdefer self.allocator.free(stack);

            const task_node = try self.allocator.create(TaskNode);
            errdefer self.allocator.destroy(task_node);

            const Fun = @TypeOf(fun);
            const Args = @TypeOf(args);

            const ArgBlock = struct {
                context: *Self,
                task: *Task,

                fun: Fun,
                args: Args,
            };

            const arg_block = try self.allocator.create(ArgBlock);
            errdefer self.allocator.destroy(arg_block);

            arg_block.* = .{
                .context = self,
                .task = &task_node.task,
                .fun = fun,
                .args = args,
            };

            const wrapper = struct {
                fn aufruf(
                    bootstrap_arg_0: *const anyopaque,
                    bootstrap_arg_1: *const anyopaque,
                ) callconv(.c) void {
                    const arg_block_ = blk: {
                        const arg_block_: *ArgBlock = @ptrCast(@alignCast(@constCast(bootstrap_arg_0)));
                        _ = bootstrap_arg_1;

                        const block = arg_block_.*;
                        block.context.allocator.destroy(arg_block_);

                        break :blk block;
                    };

                    // as per the protocol, we yield immediately after being bootstrapped
                    arg_block_.task.yield();

                    @call(.auto, arg_block_.fun, .{ arg_block_.context, arg_block_.task } ++ arg_block_.args);

                    arg_block_.task.status = .terminated;
                    arg_block_.task.yield();

                    unreachable;
                }
            }.aufruf;

            task_node.* = .{
                .task = .init(stack, &wrapper, @ptrCast(arg_block), undefined),
                .ll_node = undefined,
            };
            task_node.task.bootstrap();

            {
                self.task_queue_mutex.lock();
                defer self.task_queue_mutex.unlock();

                self.task_queue.append(&task_node.ll_node);
                self.changeNoTasks(.add, 1);
            }

            return &task_node.task;
        }

        pub fn getTask(self: *Self) ?*Task {
            blk: {
                self.task_queue_mutex.lock();
                defer self.task_queue_mutex.unlock();

                const node = self.task_queue.first orelse {
                    break :blk;
                };

                self.task_queue.remove(node);
                self.changeNoTasks(.sub, 1);

                const task_node: *TaskNode = @fieldParentPtr("ll_node", node);
                return &task_node.task;
            }

            port.Futex.wait(&self.tasks_are_available, 1);
        }

        pub fn refundTask(self: *Self, task: *Task) void {
            const task_node: *TaskNode = @fieldParentPtr("task", task);

            switch (task.status) {
                .running => {
                    self.task_queue_mutex.lock();
                    defer self.task_queue_mutex.unlock();

                    self.task_queue.append(&task_node.ll_node);
                    self.changeNoTasks(.add, 1);
                },
                .terminated => {
                    self.allocator.free(task_node.task.stack);
                    self.allocator.destroy(task_node);
                },
            }
        }
    };
}

test {
    const port: Port = .{
        .ResumeInfo = @import("meta_port/amd64_sysv/ResumeInfo.zig"),
        .Mutex = std.Thread.Mutex,
        .Futex = std.Thread.Futex,
        .wait_for_wakeup = struct {
            pub fn aufruf(_: usize, _: usize) void {}
        }.aufruf,
    };

    var debug_allocator: std.heap.DebugAllocator(.{
        .thread_safe = true,
    }) = .init;
    const alloc = debug_allocator.allocator();

    var ctx: Context(port) = .init(alloc);

    const ThreadPair = struct {
        os_thread: std.Thread,
        ctx_thread: *Context(port).Thread,
    };

    const makeThreads = struct {
        pub fn aufruf(ctx_: *Context(port), comptime num_threads: usize) ![num_threads]ThreadPair {
            var ret: [num_threads]ThreadPair = undefined;

            var initialised_upto: usize = 0;
            errdefer for (0..initialised_upto) |i| {
                ret[i].ctx_thread.stop();
                ret[i].os_thread.join();
            };

            for (0..num_threads) |i| {
                var ctx_thread = try ctx_.makeThread();
                errdefer ctx_thread.stop();

                const os_thread = try std.Thread.spawn(.{}, struct {
                    fn aufruf(thread: *Context(port).Thread) void {
                        thread.run();
                    }
                }.aufruf, .{ctx_thread});
                errdefer os_thread.join();

                initialised_upto = i;
                ret[i] = .{
                    .os_thread = os_thread,
                    .ctx_thread = ctx_thread,
                };
            }

            return ret;
        }
    }.aufruf;

    const make_task_fn = struct {
        pub fn aufruf(comptime scope: @Type(.enum_literal)) *const fn (
            *Context(port),
            *Context(port).Task,
        ) void {
            return &struct {
                fn aufruf(_: *Context(port), task: *Context(port).Task) void {
                    const tlog = std.log.scoped(scope);
                    tlog.debug("started on thread id {X}", .{std.Thread.getCurrentId()});
                    std.Thread.sleep(std.time.ms_per_s * 10);
                    tlog.debug("yielding once on thread id {X}", .{std.Thread.getCurrentId()});
                    task.yield();
                    tlog.debug("terminating", .{});
                }
            }.aufruf;
        }
    }.aufruf;

    const llog = std.log.scoped(.main);
    std.testing.log_level = .debug;

    llog.debug("launching task 0", .{});
    _ = try ctx.launch(make_task_fn(.task0), .{});

    const num_threads = 4;

    llog.debug("starting the former half of the ctx threads", .{});
    const threads_first_half = try makeThreads(&ctx, num_threads / 2);

    llog.debug("launching task 1", .{});
    _ = try ctx.launch(make_task_fn(.task1), .{});

    llog.debug("launching task 2", .{});
    _ = try ctx.launch(make_task_fn(.task2), .{});

    llog.debug("sleeping for half a sec after launching 0, 1, 2", .{});
    std.Thread.sleep(std.time.ns_per_s / 2);

    llog.debug("starting the latter half of the ctx threads", .{});
    const threads_second_half = try makeThreads(&ctx, num_threads - num_threads / 2);

    llog.debug("launching task 3", .{});
    _ = try ctx.launch(make_task_fn(.task3), .{});

    llog.debug("launching task 4", .{});
    _ = try ctx.launch(make_task_fn(.task4), .{});

    std.Thread.sleep(std.time.ns_per_s);
    if (true) @panic("");

    llog.debug("joining the context threads...", .{});
    for (threads_first_half, 0..) |pair, i| {
        llog.debug("joining first half, thread {d}...", .{i});
        pair.os_thread.join();
    }

    for (threads_second_half, 0..) |pair, i| {
        llog.debug("joining second half, thread {d}...", .{i});
        pair.os_thread.join();
    }
}
