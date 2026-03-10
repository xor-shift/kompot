const std = @import("std");

const kompot = @import("kompot");

const log = kompot.log;

const Clock = log.Clock;

const Self = @This();

fn vNow(clock: *const Clock) Clock.RawTimePoint {
    const self: *const Self = @alignCast(@fieldParentPtr("clock", clock));
    _ = self;

    return std.mem.zeroes(Clock.RawTimePoint);
}

fn vOrder(clock: *const Clock, lhs: Clock.RawTimePoint, rhs: Clock.RawTimePoint) std.math.Order {
    const self: *const Self = @alignCast(@fieldParentPtr("clock", clock));
    _ = self;

    _ = lhs;
    _ = rhs;

    return .eq;
}

fn vSince(clock: *const Clock, tp: Clock.RawTimePoint, since: Clock.RawTimePoint) u64 {
    const self: *const Self = @alignCast(@fieldParentPtr("clock", clock));
    _ = self;

    _ = tp;
    _ = since;

    return 0;
}

clock: Clock = .{ .vtable = &.{
    .now = &Self.vNow,
    .order = &Self.vOrder,
    .since = &Self.vSince,
} },
