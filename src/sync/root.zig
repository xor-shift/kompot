const std = @import("std");

const kompot = @import("kompot");

const arc = @import("arc.zig");
const atomic_spsc_ring_buffer = @import("atomic_spsc_ring_buffer.zig");
const tearing_atomic_uint = @import("tearing_atomic_uint.zig");

pub const AppendOnlyAtomicSinglyLinkedList = @import("AppendOnlyAtomicSinglyLinkedList.zig");

pub const AtomicSPSCRingBuffer = atomic_spsc_ring_buffer.AtomicSPSCRingBuffer;
pub const TearingAtomicUint = tearing_atomic_uint.TearingAtomicUint;

pub const Arc = arc.Arc;
pub const ArcSlice = arc.ArcSlice;
pub const ArcTrivial = arc.ArcTrivial;

test {
    std.testing.refAllDecls(arc);
    std.testing.refAllDecls(atomic_spsc_ring_buffer);
    std.testing.refAllDecls(tearing_atomic_uint);

    std.testing.refAllDecls(AppendOnlyAtomicSinglyLinkedList);
}
