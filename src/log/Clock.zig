const std = @import("std");

const Clock = @This();

pub const VTable = struct {
    now: *const fn (clock: *const Clock) RawTimePoint,
    order: *const fn (clock: *const Clock, lhs: RawTimePoint, rhs: RawTimePoint) std.math.Order,
    since: *const fn (clock: *const Clock, tp: RawTimePoint, earlier: RawTimePoint) u64,
};

pub const RawTimePoint = [16]u8;

pub const TimePoint = struct {
    clock: *const Clock,
    raw: RawTimePoint,

    pub fn order(lhs: TimePoint, rhs: TimePoint) std.math.Order {
        std.debug.assert(lhs.clock == rhs.clock);
        return lhs.clock.vtable.order(lhs.clock, lhs.raw, rhs.raw);
    }

    pub fn since(self: TimePoint, earlier: TimePoint) u64 {
        std.debug.assert(self.clock == earlier.clock);
        return self.clock.vtable.since(self.clock, self.raw, earlier.raw);
    }
};

pub fn now(clock: *const Clock) TimePoint {
    return .{
        .clock = clock,
        .raw = clock.vtable.now(clock),
    };
}

vtable: *const VTable,
