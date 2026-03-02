const std = @import("std");

const reference = @import("reference.zig");

pub const Error = reference.Error;
pub const TimeoutNS = reference.TimeoutNS;

pub fn delay(nanoseconds: u64) void {
    std.Thread.sleep(nanoseconds);
}

pub const Thread = struct {
    handle: std.Thread.Id,
};

pub const Semaphore = struct {
    pub const Settings = reference.Semaphore.Settings;

    name: [:0]const u8,

    max_count: u32,
    cur_count: u32,

    pub fn init(max_count: u32, initial_count: u32, settings: Settings) !Semaphore {
        return .{
            .name = settings.name orelse "",

            .max_count = max_count,
            .cur_count = initial_count,
        };
    }

    pub fn deinit(self: Semaphore) Error!void {
        _ = self;
    }

    pub fn getName(self: Semaphore) [:0]const u8 {
        return self.name;
    }

    pub fn acquire(self: *Semaphore, timeout_ns: TimeoutNS) Error!void {
        var timer = std.time.Timer.start() catch return Error.Unspecified;

        while (true) {
            const expected_value_before_sub = @atomicLoad(u32, &self.cur_count, .acquire);

            if (expected_value_before_sub == 0) {
                const max_wait_for = switch (timeout_ns) {
                    .dont_wait => return Error.Timeout,
                    .wait_forever => std.math.maxInt(u64),
                    else => |v| @intFromEnum(v),
                };

                const elapsed = timer.read();

                if (elapsed >= max_wait_for) return Error.Timeout;

                const wait_for = max_wait_for - elapsed;

                std.Thread.Futex.timedWait(@ptrCast(&self.cur_count), 0, wait_for) catch {};

                continue;
            }

            const maybe_actual_value_before_sub = @cmpxchgWeak(
                u32,
                &self.cur_count,
                expected_value_before_sub,
                expected_value_before_sub - 1,
                .acq_rel,
                .acquire,
            );

            if (maybe_actual_value_before_sub == null) break;
        }
    }

    pub fn release(self: *Semaphore) Error!void {
        while (true) {
            const expected_value = @atomicLoad(u32, &self.cur_count, .acquire);
            std.debug.assert(expected_value <= self.max_count);

            if (expected_value == self.max_count) return Error.Resource;

            const maybe_actual_value = @cmpxchgWeak(
                u32,
                &self.cur_count,
                expected_value,
                expected_value + 1,
                .acq_rel,
                .acquire,
            );

            if (maybe_actual_value == null) break;
        }

        std.Thread.Futex.wake(@ptrCast(&self.cur_count), std.math.maxInt(u32));
    }

    pub fn getCount(self: Semaphore) usize {
        return @intCast(@atomicLoad(u32, &self.cur_count, .acquire));
    }
};

pub const Mutex = struct {
    const Self = @This();

    semaphore: Semaphore,
    owner: ?Thread = null,
    lock_count: usize = 0,

    pub fn init(name: [:0]const u8) Error!Self {
        return .{
            .semaphore = try .init(1, 1, .{
                .name = name,
            }),
        };
    }

    pub fn deinit(self: Self) Error!void {
        return self.semaphore.deinit();
    }

    pub fn getName(self: Self) [:0]const u8 {
        return self.semaphore.getName();
    }

    pub fn acquire(self: *Self, timeout_ns: TimeoutNS) Error!void {
        return self.semaphore.acquire(timeout_ns);
    }

    pub fn release(self: *Self) Error!void {
        return self.semaphore.release();
    }

    // pub fn getOwner(self: Self) Error!?Thread {}
};
