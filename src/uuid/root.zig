const std = @import("std");

const raw_mod = @import("raw.zig");

test {
    std.testing.refAllDecls(raw_mod);
}

pub const Raw = raw_mod.Raw;
pub const Str = raw_mod.Str;

pub const rawToStr = raw_mod.rawToStr;
pub const strToRaw = raw_mod.strToRaw;

const Components = struct {
    custom_a: u48,
    version: u4,
    custom_b: u12,
    variant: u4,
    custom_c: u62,

    fn rawFromComponents(components: anytype) Raw {
        var ret: Raw = 0;

        comptime {
            var sum: usize = 0;
            for (components) |v| sum += @bitSizeOf(@TypeOf(v));
            std.debug.assert(sum == 128);
        }

        inline for (components) |v| {
            const T = @TypeOf(v);

            ret <<= @bitSizeOf(T);
            ret |= v;
        }
        //

        return ret;
    }

    fn getComponents(comptime N: usize, comptime bit_lengths: [N]u16, raw: Raw) [N]u128 {
        comptime {
            var sum: usize = 0;
            for (bit_lengths) |v| sum += v;
            std.debug.assert(sum == 128);
        }

        var v = raw;
        var ret: [N]u128 = undefined;
        inline for (0..N) |i| {
            const j = N - i - 1;

            const Int = std.meta.Int(.unsigned, bit_lengths[j]);
            const component: Int = @truncate(v);
            v >>= bit_lengths[j];

            ret[j] = component;
        }

        return ret;
    }

    pub fn toRaw(self: Components) Raw {
        const components = .{
            self.custom_a,
            @as(u4, 7),
            self.custom_b,
            @as(u2, 2),
            self.custom_c,
        };

        return rawFromComponents(components);
    }

    pub fn fromRaw(raw: Raw) Components {
        const components = getComponents(5, .{ 48, 4, 12, 2, 62 }, raw);

        return .{
            .custom_a = @intCast(components[0]),
            .version = @intCast(components[1]),
            .custom_b = @intCast(components[2]),
            .variant = @intCast(components[3]),
            .custom_c = @intCast(components[4]),
        };
    }
};
pub const UUIDv8 = struct {
    custom_data: u122,

    pub fn toComponents(self: UUIDv8) Components {
        return .{
            .custom_a = @intCast((self.custom_data >> 74) & 0xFFFF_FFFF_FFFF),
            .version = 8,
            .custom_b = @intCast((self.custom_data >> 62) & 0xFFF),
            .variant = 2,
            .custom_c = @intCast((self.custom_data >> 0) & 0x3FFF_FFFF_FFFF_FFFF),
        };
    }

    pub fn fromComponents(raw: Components) UUIDv8 {
        const wide_a: u122 = raw.custom_a;
        const wide_b: u122 = raw.custom_b;
        const wide_c: u122 = raw.custom_c;

        return .{
            .custom_data = (wide_a << 74) | (wide_b << 62) | (wide_c << 0),
        };
    }
};

pub const UUIDv7 = struct {
    /// the number of milliseconds that have passed since 1st of Jan, 1970 (UTC)
    timestamp: u48,
    rand: u74,

    pub fn toComponents(self: UUIDv7) Components {
        return .{
            .custom_a = @as(u48, self.timestamp),
            .version = 7,
            .custom_b = @as(u12, @intCast(self.rand >> 62)),
            .variant = 2,
            .custom_c = @as(u62, @truncate(self.rand)),
        };
    }

    pub fn fromComponents(components: Components) UUIDv7 {
        const wide_b: u74 = components.custom_b;
        const wide_c: u74 = components.custom_c;

        return .{
            .timestamp = components.custom_a,
            .rand = (wide_b << 62) | wide_c,
        };
    }
};

test UUIDv7 {
    const cooked: UUIDv7 = .{
        .timestamp = 0x017F22E279B0,
        .rand = (0xCC3 << 62) | (0b01 << 60) | 0x8C4DC0C0C07398F,
    };

    const raw = cooked.toComponents().toRaw();

    try std.testing.expectEqual(0x017F22E279B07CC398C4DC0C0C07398F, raw);

    const recooked: UUIDv7 = .fromComponents(.fromRaw(raw));

    try std.testing.expectEqual(cooked.timestamp, recooked.timestamp);
    try std.testing.expectEqual(cooked.rand, recooked.rand);

    const reraw = cooked.toComponents().toRaw();
    try std.testing.expectEqual(0x017F22E279B07CC398C4DC0C0C07398F, reraw);
}

pub const UUID = union(enum) {
    uuid_v7: UUIDv7,
    unknown: Raw,

    pub fn fromRaw(raw: Raw) UUID {
        const components: Components = .fromRaw(raw);

        if (components.variant != 2) return .{ .unknown = raw };

        return switch (components.version) {
            7 => .{ .uuid_v7 = .fromComponents(components) },
            else => .{ .unknown = raw },
        };
    }
};
