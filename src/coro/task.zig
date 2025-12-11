const Port = @import("Port.zig");

pub const TaskStatus = enum {
    /// The task may or may not be executing but it can be resumed freely.
    running,

    /// The task won't be resumed until unsuspend is called on it
    // suspended,

    /// The task has exited and the resources may be freed upon the next yield
    terminated,
};

pub fn Task(comptime port: Port) type {
    return struct {
        const Self = @This();

        name_length: usize = 0,
        name_buffer: [128]u8 = undefined,

        stack: []u8,

        status: TaskStatus = .running,

        /// If this is true, do not steal.
        dont_touch: bool = false,

        /// this is initialized by the context and used by a task for
        /// resumption.
        task_resume_info: port.ResumeInfo,

        /// this is filled in by the thread running the task during task
        /// resumption.
        thread_resume_info: port.ResumeInfo = undefined,

        pub fn init(
            stack: []u8,
            fun: *const fn (
                bootstrap_arg_0: *const anyopaque,
                bootstrap_arg_1: *const anyopaque,
            ) callconv(.c) void,
            bootstrap_arg_0: *const anyopaque,
            bootstrap_arg_1: *const anyopaque,
        ) Self {
            return .{
                .stack = stack,
                .task_resume_info = .init(stack, fun, bootstrap_arg_0, bootstrap_arg_1),
            };
        }

        /// Externally synchronized
        pub fn setName(self: *Self, name: []const u8) void {
            const real_len = @min(name.len, self.name_buffer.len);
            @memcpy(self.name_buffer[0..real_len], name[0..real_len]);
            self.name_length = real_len;
        }

        /// Externally synchronized
        pub fn getName(self: Self) []const u8 {
            return self.name_buffer[0..self.name_length];
        }

        pub fn bootstrap(self: *Self) void {
            self.task_resume_info.bootstrap(&self.thread_resume_info);
        }

        /// Only call from outside the task
        ///
        /// This is the counterpart of `yield`
        pub fn @"resume"(self: *Self) void {
            self.task_resume_info.doResume(&self.thread_resume_info);
        }

        /// Only call from within the task.
        ///
        /// This is the counterpart of `resume`
        pub fn yield(self: *Self) void {
            self.thread_resume_info.doResume(&self.task_resume_info);
        }

        pub fn @"suspend"(self: *Self) void {
            self.status = .suspended;
            self.yield();
        }
    };
}
