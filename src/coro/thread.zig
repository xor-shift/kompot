const std = @import("std");

const Port = @import("Port.zig");

pub const ThreadStatus = enum {
    running,

    /// The thread was starved of tasks. A wakeup must be given, upon which,
    /// the task will first try stealing the entirety of the global queue, and
    /// if that fails, it will try stealing half the queue of a random thread.
    ///
    /// If, for some reason, no tasks can be stolen, the thread will not
    /// unsuspend.
    suspended,

    /// `stop` was called or the run-loop exited abnormally.
    terminated,
};

pub fn Thread(comptime port: Port) type {
    return struct {
        const Self = @This();

        const Context = @import("context.zig").Context(port);
        const Task = Context.Task;

        mutex: port.Mutex = .{},

        context: *Context,
        allocator: std.mem.Allocator,

        no_tasks: usize = 0,
        tasks: std.DoublyLinkedList = .{},

        stop_requested: bool = false,
        wakeup_signalled: bool = false,

        status: ThreadStatus = .running,

        rng: std.Random.Xoshiro256 = .init(0xCAFEBABEDEADBEEF),

        pub fn init(context: *Context, allocator: std.mem.Allocator) Self {
            return .{
                .context = context,
                .allocator = allocator,
            };
        }

        fn findTaskToResume(self: *Self) ?*Context.TaskNode {
            var node = self.tasks.first orelse return null;

            const start_index = self.rng.random().intRangeLessThan(usize, 0, self.no_tasks);

            const filterResumable = struct {
                fn aufruf(node_: *std.DoublyLinkedList.Node) ?*Context.TaskNode {
                    const task_node: *Context.TaskNode = @fieldParentPtr("ll_node", node_);

                    if (task_node.task.status == .running) return task_node;

                    return null;
                }
            }.aufruf;

            const to_return_if_not_found = blk: {
                var to_return_if_not_found: ?*Context.TaskNode = null;

                for (0..start_index) |_| {
                    if (to_return_if_not_found == null) {
                        if (filterResumable(node)) |task_node| {
                            to_return_if_not_found = task_node;
                        }
                    }

                    node = node.next.?;
                }

                break :blk to_return_if_not_found;
            };

            for (start_index..self.no_tasks) |cur_task_index| {
                if (filterResumable(node)) |task_node| return task_node;

                node = node.next orelse {
                    std.debug.assert(cur_task_index == self.no_tasks - 1);
                    break;
                };
            }

            return to_return_if_not_found;
        }

        pub fn run(self: *Self) void {
            while (true) {
                self.mutex.lock();

                if (self.stop_requested == true) {
                    self.context.refundTasks(&self.tasks);
                    self.no_tasks = 0;

                    self.mutex.unlock();
                    break;
                }

                const task_to_resume = self.findTaskToResume() orelse {
                    self.mutex.unlock();

                    port.wait_for_wakeup(undefined, undefined);

                    continue;
                };
                self.tasks.remove(&task_to_resume.ll_node);
                self.mutex.unlock();

                task_to_resume.task.@"resume"();

                self.mutex.lock();
                self.tasks.append(&task_to_resume.ll_node);
                self.mutex.unlock();
            }
        }

        pub fn stop(self: *Self) void {
            self.mutex.lock();
            self.stop_requested = true;
            self.mutex.unlock();
        }
    };
}
