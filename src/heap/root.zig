const next_fit = @import("next_fit.zig");
const rotating_arena = @import("rotating_arena.zig");

pub const RotatingArena = rotating_arena.RotatingArena;
pub const RotatingArenaConfig = rotating_arena.RotatingArenaConfig;

pub const NextFitAllocator = next_fit.NextFitAllocator;
pub const NextFitAllocatorConfig = next_fit.Config;

test {
    const std = @import("std");

    std.testing.refAllDecls(next_fit);
    std.testing.refAllDecls(rotating_arena);
}
