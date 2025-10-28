const std = @import("std");

ResumeInfo: type,

Mutex: type = struct {
    pub fn lock(self: *@This()) void {
        _ = self;
        @panic("not implemented");
    }

    pub fn tryLock(self: *@This()) bool {
        _ = self;
        @panic("not implemented");
    }

    pub fn unlock(self: *@This()) void {
        _ = self;
        @panic("not implemented");
    }
},

Futex: type = struct {
    pub fn timedWait(ptr: *const std.atomic.Value(u32), expect: u32, timeout_ns: u64) error{Timeout}!void {
        _ = ptr;
        _ = expect;
        _ = timeout_ns;
        @panic("not implemented");
    }

    pub fn wait(ptr: *const std.atomic.Value(u32), expect: u32) void {
        _ = ptr;
        _ = expect;
        @panic("not implemented");
    }

    pub fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        _ = ptr;
        _ = max_waiters;
        @panic("not implemented");
    }
},

/// thread_no of 0 means that the context object is waiting
///
/// spurious wakeups are fine, anyone waiting on a wakeup must check an
/// atomic flag.
wait_for_wakeup: fn (context_ident: usize, thread_no: usize) void,

initial_stack_size: usize = 16 * 1024 * 1024,
