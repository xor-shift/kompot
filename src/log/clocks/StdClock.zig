const std = @import("std");

const kompot = @import("kompot");

const log = kompot.log;

const Clock = log.Clock;

const Self = @This();

fn getInstant(raw: Clock.RawTimePoint) std.time.Instant {
    var instant: std.time.Instant = undefined;
    const instant_bytes = std.mem.asBytes(&instant);
    @memcpy(instant_bytes, raw[0..instant_bytes.len]);

    return instant;
}

fn vNow(clock: *const Clock) Clock.RawTimePoint {
    const self: *const Self = @alignCast(@fieldParentPtr("clock", clock));
    _ = self;

    const now = std.time.Instant.now() catch unreachable;
    const now_bytes = std.mem.toBytes(now);

    var ret: Clock.RawTimePoint = undefined;
    @memcpy(std.mem.asBytes(&ret)[0..now_bytes.len], now_bytes[0..]);

    return ret;
}

fn vOrder(clock: *const Clock, lhs: Clock.RawTimePoint, rhs: Clock.RawTimePoint) std.math.Order {
    const self: *const Self = @alignCast(@fieldParentPtr("clock", clock));
    _ = self;

    const lhs_instant = getInstant(lhs);
    const rhs_instant = getInstant(rhs);

    return lhs_instant.order(rhs_instant);
}

fn vSince(clock: *const Clock, tp: Clock.RawTimePoint, since: Clock.RawTimePoint) u64 {
    const self: *const Self = @alignCast(@fieldParentPtr("clock", clock));
    _ = self;

    const tp_instant = getInstant(tp);
    const since_instant = getInstant(since);

    return tp_instant.since(since_instant);
}

clock: Clock = .{ .vtable = &.{
    .now = &Self.vNow,
    .order = &Self.vOrder,
    .since = &Self.vSince,
} },
