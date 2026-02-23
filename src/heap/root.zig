const any_fit = @import("any_fit.zig");
const rotating_arena = @import("rotating_arena.zig");
const allocator_with_hooks = @import("metadata_wrapper.zig");

pub const RotatingArena = rotating_arena.RotatingArena;
pub const RotatingArenaConfig = rotating_arena.RotatingArenaConfig;

pub const NextFitAllocator = any_fit.FirstFitAllocator;
pub const BestFitAllocator = any_fit.BestFitAllocator;

pub const AtomicBumpAllocator = @import("AtomicBumpAllocator.zig");

pub const SafetyWrapper = @import("safety_wrapper.zig");
pub const SafetyWrapper2 = allocator_with_hooks.SafetyWrapper;
pub const AllocatorWithHooks = allocator_with_hooks.AllocatorWithHooks;

test {
    const std = @import("std");

    std.testing.refAllDecls(rotating_arena);
    std.testing.refAllDecls(AtomicBumpAllocator);
    std.testing.refAllDecls(SafetyWrapper);
    std.testing.refAllDecls(allocator_with_hooks);
    std.testing.refAllDecls(any_fit);
}
