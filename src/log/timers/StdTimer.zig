const std = @import("std");

const kompot = @import("kompot");

const log = kompot.log;

const Timer = log.Timer;

const Self = @This();

pub fn init(io: std.Io) Self {
    return .{
        .io = io,
    };
}

fn vReset(timer: *Timer) void {
    const self: *Self = @alignCast(@fieldParentPtr("timer", timer));

    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);

    self.base = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
}

fn vRead(timer: *Timer) u64 {
    const self: *Self = @alignCast(@fieldParentPtr("timer", timer));

    self.mutex.lock(self.io) catch return 0; // TODO
    defer self.mutex.unlock(self.io);

    return @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds - self.base);
}

timer: Timer = .{ .vtable = &.{
    .reset = &Self.vReset,
    .read = &Self.vRead,
} },

io: std.Io,

mutex: std.Io.Mutex = .init,
base: i96 = 0,
