const kompot = @import("kompot");

const log = kompot.log;

const Timer = log.Timer;

const Self = @This();

pub fn increment(self: *Self, elapsed_ns: u64) void {
    _ = self.counter.fetchAdd(elapsed_ns);
}

fn vReset(timer: *Timer) void {
    const self: *Self = @alignCast(@field(timer, "timer"));
    _ = self.counter.store(0);
}

pub fn vElapsedNS(timer: *Timer) u64 {
    const self: *Self = @alignCast(@field(timer, "timer"));
    return self.counter.load();
}

timer: Timer = .{ .vtable = &.{
    .reset = &Self.vReset,
    .elapsedNS = &Self.vElapsedNS,
}},

counter: kompot.sync.TearingAtomicUint(64) = .init(0),
