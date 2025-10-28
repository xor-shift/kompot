const std = @import("std");

pub const Config = struct {
    // 2 4 3 7 5 2 2
    //
    // 0    5    10   15   20   25
    // #----#----#----#----#----#----#----#----#
    // []   [--] [-]  [-----]   [---][]   []     aligned
    // []   [--] [-]  [-----][---][] []          crammed
    /// Prefer crammed.
    const TickMode = enum {
        dumb,
        aligned,
        crammed,
    };

    ns_per_tick: u64,
    mode: TickMode,
};

config: Config,

time_ctx: *anyopaque,
time_provider: *const fn (*anyopaque) u64,

exit_mutex: std.Thread.Mutex = .{},
exit: bool = false,
exit_cv: std.Thread.Condition = .{},

thread: ?std.Thread = null,

next_tick_at: u64 = undefined,

const Self = @This();

/// Pins `self`.
pub fn run(
    self: *Self,
    thread_config: std.Thread.SpawnConfig,
    comptime function: anytype,
    args: anytype,
    comptime init_fn: anytype,
    init_args: anytype,
) !void {
    self.thread = try std.Thread.spawn(
        thread_config,
        worker,
        .{ self, function, args, init_fn, init_args },
    );
}

fn get_time(self: *Self) u64 {
    return self.time_provider(self.time_ctx);
}

const WaitResult = enum {
    quitting,
    do_tick,
};

pub fn wait(self: *Self) WaitResult {
    self.exit_mutex.lock();
    defer self.exit_mutex.unlock();

    while (true) {
        if (@atomicLoad(bool, &self.exit, .acquire)) return .quitting;

        const time = self.get_time();

        if (time >= self.next_tick_at) break;

        const remaining_ns = self.next_tick_at - time;

        self.exit_cv.timedWait(&self.exit_mutex, remaining_ns) catch {};
    }

    return .do_tick;
}

pub fn worker(
    self: *Self,
    comptime function: anytype,
    args: anytype,
    comptime init_fn: anytype,
    init_args: anytype,
) void {
    self.next_tick_at = self.get_time() + self.config.ns_per_tick;

    @call(.auto, init_fn, init_args);

    while (true) {
        if (self.wait() == .quitting) break;

        const start_time = self.get_time();

        if (start_time >= self.next_tick_at + std.time.ns_per_ms) {
            const lag_ns = start_time - self.next_tick_at;
            std.log.warn("tick started {d}ms late", .{
                @as(f64, @floatFromInt(lag_ns)) / std.time.ns_per_ms,
            });
        }

        @call(.auto, function, args);

        const end_time = self.get_time();

        const tick_duration = end_time - start_time;

        switch (self.config.mode) {
            .dumb => self.next_tick_at = start_time + self.config.ns_per_tick,
            .aligned => {
                const ticks_taken = ((tick_duration + self.config.ns_per_tick - 1) / self.config.ns_per_tick);

                if (ticks_taken > 1) {
                    std.log.warn("lagging behind by {d} tick(s) (last tick took {d} ms)", .{
                        ticks_taken - 1,
                        @as(f64, @floatFromInt(tick_duration)) / std.time.ns_per_ms,
                    });
                }

                self.next_tick_at += self.config.ns_per_tick * ticks_taken;
            },
            .crammed => {
                const ticks_taken = @max(1, tick_duration / self.config.ns_per_tick);

                self.next_tick_at += self.config.ns_per_tick * ticks_taken;
            },
        }
    }
}

pub fn stop(self: *Self) void {
    self.exit_mutex.lock();
    @atomicStore(bool, &self.exit, true, .release);
    self.exit_cv.signal();
    self.exit_mutex.unlock();
    self.thread.?.join();
}
