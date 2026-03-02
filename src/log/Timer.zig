const Timer = @This();

pub const VTable = struct {
    reset: *const fn (timer: *Timer) void,
    read: *const fn (timer: *Timer) u64,
};

vtable: *const VTable,

pub fn reset(timer: *Timer) void {
    return timer.vtable.reset(timer);
}

pub fn read(timer: *Timer) u64 {
    return timer.vtable.read(timer);
}

pub fn lap(timer: *Timer) u64 {
    timer.vtable.reset(timer);
    return timer.vtable.read(timer);
}

