const builtin = @import("builtin");
const std = @import("std");

pub const util = @import("util.zig");

pub const impls = struct {
    /// This contains stubs and documentation
    pub const single_threaded = @import("impls/single_threaded.zig");

    /// This is the implementation based on `cmsis_os2.h`
    pub const cmsis_os2 = @import("impls/cmsis_header.zig");

    /// This is the implementation based on the Zig standard library as well as
    /// custom code
    pub const std = @import("impls/std.zig");
};

pub const impl = //
    if (builtin.os.tag == .freestanding and builtin.cpu.arch == .thumb) impls.cmsis_os2 //
    else @import("impls/std.zig");
