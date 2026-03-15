const std = @import("std");

const kompot = @import("kompot");

const log = kompot.log;

const Timer = log.Timer;

const Self = @This();

pub fn init() Self {
    return .{
        .std_timer = std.time.Timer.start() catch unreachable,
    };
}

fn vReset(timer: *Timer) void {
    const self: *Self = @alignCast(@fieldParentPtr("timer", timer));

    self.mutex.lock();
    defer self.mutex.unlock();

    self.std_timer.reset();
}

fn vRead(timer: *Timer) u64 {
    const self: *Self = @alignCast(@fieldParentPtr("timer", timer));

    self.mutex.lock();
    defer self.mutex.unlock();

    return self.std_timer.read();
}

timer: Timer = .{ .vtable = &.{
    .reset = &Self.vReset,
    .read = &Self.vRead,
} },

mutex: std.Thread.Mutex = .{},
std_timer: std.time.Timer,
