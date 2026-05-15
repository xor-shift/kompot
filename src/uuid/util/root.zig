const std = @import("std");

const hex2bytes_mod = @import("hex2bytes.zig");

const capitalise_mod = @import("capitalise.zig");

pub const isCapitalisedHex = hex2bytes_mod.isCapitalisedHex;
pub const capitalisedHex2bytes = hex2bytes_mod.capitalisedHex2bytes.aufruf;

pub const capitalise = capitalise_mod.capitalise;

test {
    std.testing.refAllDecls(hex2bytes_mod);

    std.testing.refAllDecls(capitalise_mod);
}
