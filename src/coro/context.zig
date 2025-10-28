const std = @import("std");

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
        global_task_queue: std.DoublyLinkedList = .{},

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
                    const arg_block_: *ArgBlock = @ptrCast(@alignCast(@constCast(bootstrap_arg_0)));
                    _ = bootstrap_arg_1;

                    // as per the protocol, we yield immediately after being bootstrapped
                    arg_block_.task.yield();
                }
            }.aufruf;

            task_node.* = .{
                .task = .init(stack, &wrapper, @ptrCast(arg_block), undefined),
                .ll_node = undefined,
            };
            task_node.task.bootstrap();

            // it is still ok to destroy the task at this point

            self.task_queue_mutex.lock();
            self.global_task_queue.append(&task_node.ll_node);
            self.task_queue_mutex.unlock();

            return &task_node.task;
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

        pub fn refundTasks(self: *Self, local_task_queue: *std.DoublyLinkedList) void {
            self.task_queue_mutex.lock();
            self.global_task_queue.concatByMoving(local_task_queue);
            self.task_queue_mutex.unlock();
        }
    };
}

test {
    const port: Port = .{
        .ResumeInfo = @import("meta_port/amd64_sysv/ResumeInfo.zig"),
        .Mutex = std.Thread.Mutex,
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

    const llog = std.log.scoped(.main);

    llog.debug("launching task 0", .{});
    _ = try ctx.launch(&struct {
        fn aufruf() void {
            const tlog = std.log.scoped(.task0);
            tlog.debug("started", .{});
            std.Thread.sleep(std.time.ns_per_s);
            tlog.debug("terminating", .{});
        }
    }.aufruf, .{});

    const thread_no = 4;

    llog.debug("starting the former half of the ctx threads", .{});
    const threads_first_half = try makeThreads(&ctx, thread_no / 2);

    llog.debug("launching task 1", .{});
    _ = try ctx.launch(&struct {
        fn aufruf() void {
            const tlog = std.log.scoped(.task1);
            tlog.debug("started", .{});
            std.Thread.sleep(std.time.ns_per_s);
            tlog.debug("terminating", .{});
        }
    }.aufruf, .{});

    llog.debug("launching task 2", .{});
    _ = try ctx.launch(&struct {
        fn aufruf() void {
            const tlog = std.log.scoped(.task2);
            tlog.debug("started", .{});
            std.Thread.sleep(std.time.ns_per_s);
            tlog.debug("terminating", .{});
        }
    }.aufruf, .{});

    llog.debug("sleeping for half a sec after launching 0, 1, 2", .{});
    std.Thread.sleep(std.time.ns_per_s / 2);

    llog.debug("starting the latter half of the ctx threads", .{});
    const threads_second_half = try makeThreads(&ctx, thread_no - thread_no / 2);

    llog.debug("launching task 3", .{});
    _ = try ctx.launch(&struct {
        fn aufruf() void {
            const tlog = std.log.scoped(.task3);
            tlog.debug("started", .{});
            std.Thread.sleep(std.time.ns_per_s);
            tlog.debug("terminating", .{});
        }
    }.aufruf, .{});

    llog.debug("launching task 4", .{});
    _ = try ctx.launch(&struct {
        fn aufruf() void {
            const tlog = std.log.scoped(.task4);
            tlog.debug("started", .{});
            std.Thread.sleep(std.time.ns_per_s);
            tlog.debug("terminating", .{});
        }
    }.aufruf, .{});

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
