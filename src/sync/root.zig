const std = @import("std");

const tearing_atomic_uint = @import("tearing_atomic_uint.zig");

pub const TearingAtomicUint = tearing_atomic_uint.TearingAtomicUint;

test {
    std.testing.refAllDecls(tearing_atomic_uint);
}
