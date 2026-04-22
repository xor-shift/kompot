const std = @import("std");

const kompot = @import("kompot");

const log = kompot.log;

const Clock = log.Clock;

const Self = @This();

fn getTimestamp(raw: Clock.RawTimePoint) std.Io.Timestamp {
    var instant: std.Io.Timestamp = undefined;
    const instant_bytes = std.mem.asBytes(&instant);
    @memcpy(instant_bytes, raw[0..instant_bytes.len]);

    return instant;
}

fn vNow(clock: *const Clock) Clock.RawTimePoint {
    const self: *const Self = @alignCast(@fieldParentPtr("clock", clock));

    const now = std.Io.Timestamp.now(self.io, .real);
    const now_bytes = std.mem.toBytes(now);

    var ret: Clock.RawTimePoint = undefined;
    @memcpy(std.mem.asBytes(&ret)[0..now_bytes.len], now_bytes[0..]);

    return ret;
}

fn vOrder(clock: *const Clock, lhs: Clock.RawTimePoint, rhs: Clock.RawTimePoint) std.math.Order {
    const self: *const Self = @alignCast(@fieldParentPtr("clock", clock));
    _ = self;

    const lhs_timestamp = getTimestamp(lhs);
    const rhs_timestamp = getTimestamp(rhs);

    const duration = lhs_timestamp.durationTo(rhs_timestamp);

    if (duration.toNanoseconds() < 0) return .gt;
    if (duration.toNanoseconds() > 0) return .lt;
    return .eq;
}

fn vSince(clock: *const Clock, tp: Clock.RawTimePoint, since: Clock.RawTimePoint) u64 {
    const self: *const Self = @alignCast(@fieldParentPtr("clock", clock));
    _ = self;

    const tp_timestamp = getTimestamp(tp);
    const since_timestamp = getTimestamp(since);

    const duration = since_timestamp.durationTo(tp_timestamp);

    return @intCast(duration.toNanoseconds()); // TODO: this can be negative
}

clock: Clock = .{ .vtable = &.{
    .now = &Self.vNow,
    .order = &Self.vOrder,
    .since = &Self.vSince,
} },

io: std.Io,
