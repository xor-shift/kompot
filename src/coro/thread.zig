const std = @import("std");

const Port = @import("Port.zig");

pub fn Thread(comptime port: Port) type {
    return struct {
        const Self = @This();

        const Context = @import("context.zig").Context(port);
        const Task = Context.Task;

        mutex: port.Mutex = .{},

        context: *Context,
        allocator: std.mem.Allocator,

        pub fn init(context: *Context, allocator: std.mem.Allocator) Self {
            return .{
                .context = context,
                .allocator = allocator,
            };
        }

        pub fn run(self: *Self) void {
            const thread_id = std.Thread.getCurrentId();

            std.log.debug("thread {d} started", .{thread_id});

            while (true) {
                const task = self.context.getTask() orelse break;
                std.log.debug("thread {d} got a task", .{thread_id});
                task.@"resume"();
                std.log.debug("thread {d} is done resuming the task", .{thread_id});

                if (task.status == .terminated) {
                    std.log.debug("the task resumed by thread {d} terminated", .{thread_id});
                }

                self.context.refundTask(task);
            }
        }

        pub fn stop(self: *Self) void {
            self.mutex.lock();
            self.stop_requested = true;
            self.mutex.unlock();
        }
    };
}
