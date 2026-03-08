const std = @import("std");

const philox = @import("engines/philox.zig");

pub const Philox2x32 = philox.Philox2x32;
pub const Philox2x64 = philox.Philox2x64;
pub const Philox4x32 = philox.Philox4x32;
pub const Philox4x64 = philox.Philox4x64;

comptime {
    std.testing.refAllDecls(philox);
}
