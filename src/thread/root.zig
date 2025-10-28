const future = @import("future.zig");

pub const Channel = @import("channel.zig").Channel;
pub const WorkerPool = @import("worker_pool.zig").WorkerPool;

pub const Future = future.Future;
pub const Promise = future.Promise;

pub const Ticker = @import("Ticker.zig");

test {
    const std = @import("std");

    std.testing.refAllDecls(@import("channel.zig"));
    std.testing.refAllDecls(@import("future.zig"));
    std.testing.refAllDecls(@import("Ticker.zig"));
    std.testing.refAllDecls(@import("worker_pool.zig"));
}
