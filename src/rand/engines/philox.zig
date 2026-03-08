const std = @import("std");

pub fn BufUint(comptime word_size: u16, comptime word_ct: usize) type {
    return struct {
        const Self = @This();

        const Word = std.meta.Int(.unsigned, word_size);
        const DWord = std.meta.Int(.unsigned, @bitSizeOf(Word) * 2);

        pub const UInt = std.meta.Int(.unsigned, word_size * word_ct);

        pub fn init(v: UInt) Self {
            var w = v;

            var ret: Self = undefined;
            for (0..word_ct) |i| {
                ret.buf[i] = @truncate(w);
                w >>= word_size;
            }

            return ret;
        }

        pub fn asInt(self: Self) UInt {
            var ret: UInt = undefined;
            for (0..word_ct) |i| {
                ret <<= word_size;
                ret += @intCast(self.buf[i]);
            }

            return ret;
        }

        fn addSubImpl(
            comptime modular: bool,
            comptime op: enum {
                add,
                sub,
            },
            lhs: Self,
            rhs: Self,
        ) Self {
            var ret = lhs;

            const fun = switch (op) {
                .add => struct {
                    fn aufruf(lhs_: Word, rhs_: Word) struct { Word, u1 } {
                        const v, const c = @addWithOverflow(lhs_, rhs_);
                        return .{ v, c };
                    }
                }.aufruf,
                .sub => struct {
                    fn aufruf(lhs_: Word, rhs_: Word) struct { Word, u1 } {
                        const v, const c = @subWithOverflow(lhs_, rhs_);
                        return .{ v, c };
                    }
                }.aufruf,
            };

            var carry_or_borrow: u1 = 0;
            for (0..word_ct) |i| {
                const lhs_i = ret.buf[i];
                const rhs_i = rhs.buf[i];

                const half_res_i = fun(lhs_i, rhs_i);
                const full_res_i = fun(half_res_i.@"0", carry_or_borrow);

                const carried = half_res_i.@"1" + full_res_i.@"1";

                ret.buf[i] = full_res_i.@"0";
                carry_or_borrow = carried;
            }

            if (!modular) {
                std.debug.assert(carry_or_borrow == 0);
            }

            return ret;
        }

        pub fn add(lhs: Self, rhs: Self) Self {
            return Self.addSubImpl(false, .add, lhs, rhs);
        }

        pub fn addModular(lhs: Self, rhs: Self) Self {
            return Self.addSubImpl(true, .add, lhs, rhs);
        }

        pub fn sub(lhs: Self, rhs: Self) Self {
            return Self.addSubImpl(false, .sub, lhs, rhs);
        }

        pub fn subModular(lhs: Self, rhs: Self) Self {
            return Self.addSubImpl(true, .sub, lhs, rhs);
        }

        pub fn div(lhs: Self, rhs: Self) Self {
            // TODO: don't rely on large ints

            return .init(lhs.asInt() / rhs.asInt());
        }

        fn shift(self: Self, n: usize, comptime left: bool) Self {
            var ret: Self = self;

            const words = n / word_size;
            const bits = n % word_size;

            // 0 1 2 3 . .
            const left_side = ret.buf[0 .. ret.buf.len - words];
            const right_excess = ret.buf[ret.buf.len - words ..];
            // . . 4 5 6 7
            const right_side = ret.buf[words..];
            const left_excess = ret.buf[0..words];

            if (left) {
                // 0 1 2 3 4 5
                // . . 0 1 2 3
                std.mem.copyBackwards(Word, right_side, left_side);
                @memset(left_excess, 0);
            } else {
                // 0 1 2 3 4 5
                // 2 3 4 5 . .
                std.mem.copyBackwards(Word, left_side, right_side);
                @memset(right_excess, 0);
            }

            // left:
            // 76543210 FEDCBA98
            // 43210... CBA98765
            //      ---      --- prev
            // 0        1        iteration order

            // right:
            // 76543210 FEDCBA98
            // A9876543 ...FEDCB

            var prev: Word = 0;
            for (0..ret.buf.len) |i| {
                const idx = if (left) i else ret.buf.len - i - 1;
                const v = ret.buf[idx];

                const @"bits'" = @bitSizeOf(v) - bits;

                const partial_new_v: Word = if (left) v << bits else v >> bits;
                const new_prev = if (left) v >> @"bits'" else v << @"bits'";

                const new_v = partial_new_v | prev;
                prev = new_prev;

                ret.buf[idx] = new_v;
            }

            return ret;
        }

        fn shl(self: Self, n: usize) Self {
            return self.shift(n, true);
        }

        fn shr(self: Self, n: usize) Self {
            return self.shift(n, false);
        }

        pub fn resize(self: Self, comptime new_word_ct: usize) BufUint(word_size, new_word_ct) {
            var ret: BufUint(word_size, new_word_ct) = undefined;

            @memset(&ret.buf, 0);
            const to_copy = @min(new_word_ct, word_ct);
            @memcpy(ret.buf[0..to_copy], self.buf[0..to_copy]);

            return ret;
        }

        pub fn mulWord(lhs: Self, rhs: Word) struct { hi: Word, lo: Self } {
            //             FE FE FE
            //             FF FF FF FF
            //                      FF
            // -----------------------
            //          FE FF FF FF 01

            var ret: Self = undefined;

            var carry: Word = 0;
            for (0..word_ct) |i| {
                const half_res: DWord = std.math.mulWide(Word, lhs.buf[i], rhs);
                const res = half_res + carry;

                const hi: Word = @intCast(res >> word_size);
                const lo: Word = @truncate(res);

                carry = hi;
                ret.buf[i] = lo;
            }

            return .{ .hi = carry, .lo = ret };
        }

        pub fn mulWide(lhs: Self, rhs: Self) struct { hi: Self, lo: Self } {
            // TODO: this can be log(n)

            const DoubleSelf = BufUint(word_size, word_ct * 2);
            var ret: DoubleSelf = .init(0);

            for (0..word_ct) |i| {
                ret = ret.shl(word_size);

                const hi: Self, const lo: Word = lhs.mulWord(rhs.buf[i]);

                const combined = hi.resize(word_ct * 2).add(DoubleSelf.init(lo).shl(word_size));

                ret = ret.add(combined.shl(i * word_size));
            }

            return .{
                .hi = ret.shr(word_size * word_ct).resize(word_ct),
                .lo = ret.resize(word_ct),
            };
        }

        pub fn compare(lhs: Self, rhs: Self) std.math.Order {
            for (0..word_ct) |i| {
                const j = word_ct - i - 1;
                const o = std.math.order(lhs.buf[j], rhs.buf[j]);
                if (o == .eq) continue;

                return o;
            }

            return .eq;
        }

        pub fn min(lhs: Self, rhs: Self) Self {
            const o = lhs.compare(rhs);

            return if (o == .lt) lhs else rhs;
        }

        pub fn max(lhs: Self, rhs: Self) Self {
            const o = lhs.compare(rhs);

            return if (o == .lt) rhs else lhs;
        }

        pub fn isSmall(self: Self) bool {
            return std.mem.allEqual(Word, self.buf[1..], 0);
        }

        pub fn asSmall(self: Self) Word {
            return self.buf[0];
        }

        buf: [word_ct]Word,
    };
}

pub fn Philox(
    comptime counter_length: u16,
    comptime word_size: u16,
    comptime round_count: usize,
    comptime multipliers: [counter_length / 2]std.meta.Int(.unsigned, word_size),
    comptime bump_constants: [counter_length / 2]std.meta.Int(.unsigned, word_size),
) type {
    return struct {
        const Self = @This();

        const key_length = @ctz(counter_length);

        pub const Word = std.meta.Int(.unsigned, word_size);
        const DWord = std.meta.Int(.unsigned, word_size * 2);

        pub const Counter = BufUint(word_size, counter_length);
        pub const CounterInteger = Counter.UInt;
        pub const CounterBuf = [counter_length]Word;

        pub const Key = [key_length]Word;

        /// This initialises the engine with the default seed of 20111115 which
        /// is the default in C++.
        pub fn init() Self {
            return .initSeed(20111115);
        }

        /// this function mirrors C++ initialisation of the engine
        pub fn initSeed(seed: u64) Self {
            return .{
                .key = .{
                    @as(Word, @truncate(seed)),
                } ++ (.{0} ** (key_length - 1)),
            };
        }

        pub fn random(self: *Self) std.Random {
            return .{
                .ptr = @ptrCast(self),
                .fillFn = &Self.vFillFn,
            };
        }

        fn vFillFn(self_opaque: *anyopaque, buf: []u8) void {
            const self: *Self = @ptrCast(@alignCast(self_opaque));

            const num_calls_whole = buf.len / @sizeOf(Word);
            const excess_bytes = buf.len % @sizeOf(Word);

            for (0..num_calls_whole) |i| {
                const byte_offset = i * @sizeOf(Word);
                const remaining_buf = buf[byte_offset..];

                const word: Word = self.next();

                @memcpy(remaining_buf[0..@sizeOf(Word)], &std.mem.toBytes(word));
            }

            if (excess_bytes != 0) {
                const word: Word = self.next();

                const excess_buf = buf[excess_bytes * @sizeOf(Word) ..];

                @memcpy(excess_buf, std.mem.toBytes(word)[0..excess_buf.len]);
            }
        }

        fn bumpKey(key: Key) Key {
            var ret: Key = key;
            for (0..key.len) |i| {
                ret[i] +%= bump_constants[i];
            }
            return ret;
        }

        fn keyForRound(key: Key, round_no: Word) Key {
            var ret: Key = key;
            for (0..key.len) |i| {
                ret[i] = ret[i] +% (bump_constants[i] *% round_no);
            }
            return ret;
        }

        fn round(counter: CounterBuf, key: Key) CounterBuf {
            const swap_indices = comptime switch (counter_length) {
                2 => .{ 0, 1 },
                4 => .{ 2, 1, 0, 3 },
                else => @compileError("unsupported counter length"),
            };

            const swapped = blk: {
                var swapped: CounterBuf = undefined;
                inline for (0..counter_length) |i| {
                    swapped[i] = counter[swap_indices[i]];
                }

                break :blk swapped;
            };

            var ret = counter;
            inline for (0..counter_length / 2) |i| {
                const j = (counter_length / 2) - i - 1;
                const res = std.math.mulWide(Word, swapped[2 * i], multipliers[j]);
                const res_lo: Word = @truncate(res);
                const res_hi: Word = @intCast(res >> word_size);

                ret[2 * i] = res_hi ^ swapped[2 * i + 1] ^ key[i];
                ret[2 * i + 1] = res_lo;
            }

            return ret;
        }

        // left for posterity
        fn round4(counter: CounterBuf, key: Key) CounterBuf {
            const res_0: DWord = std.math.mulWide(Word, counter[0], multipliers[0]);
            const res_1: DWord = std.math.mulWide(Word, counter[2], multipliers[1]);

            const res_0_lo: Word = @truncate(res_0);
            const res_0_hi: Word = @truncate(res_0 >> word_size);

            const res_1_lo: Word = @truncate(res_1);
            const res_1_hi: Word = @truncate(res_1 >> word_size);

            const ret: [4]Word = .{
                res_1_hi ^ counter[1] ^ key[0],
                res_1_lo,
                res_0_hi ^ counter[3] ^ key[1],
                res_0_lo,
            };

            return ret;
        }

        fn completeRound(counter: Counter, key: Key) CounterBuf {
            var ret: CounterBuf = counter.buf;
            for (0..round_count) |i| {
                ret = round(ret, keyForRound(key, @intCast(i)));
            }

            return ret;
        }

        pub fn next(self: *Self) Word {
            if (self.remaining_in_buffer == 0) {
                self.buf = Self.completeRound(self.counter, self.key);
                self.counter = self.counter.add(.init(1));
                self.remaining_in_buffer = counter_length;
            }

            const idx = counter_length - self.remaining_in_buffer;
            self.remaining_in_buffer -= 1;

            return self.buf[idx];
        }

        pub fn discardLarge(self: *Self, n: Counter) void {
            var remaining_to_discard: Counter = n;

            if (remaining_to_discard.asInt() != 0) {
                const remaining_in_buffer = Counter.init(self.remaining_in_buffer);

                const to_discard_wide = remaining_in_buffer.min(remaining_to_discard);
                std.debug.assert(to_discard_wide.isSmall());

                const to_discard_small = to_discard_wide.asSmall();
                self.remaining_in_buffer -= to_discard_small;

                remaining_to_discard = remaining_to_discard.sub(to_discard_wide);
            }

            if (remaining_to_discard.asInt() != 0) {
                const groups_to_discard = remaining_to_discard.div(.init(counter_length));
                self.counter = self.counter.add(groups_to_discard);

                const to_discard = groups_to_discard.mulWord(counter_length).lo;
                remaining_to_discard = remaining_to_discard.sub(to_discard);
            }

            while (remaining_to_discard.asInt() != 0) {
                _ = self.next();
                remaining_to_discard = remaining_to_discard.sub(.init(1));
            }
        }

        pub fn discard(self: *Self, n: usize) void {
            return self.discardLarge(.init(n));
        }

        pub fn getNth(seed: u64, n: CounterInteger) Word {
            var p: Self = .initSeed(seed);
            p.discardLarge(.init(n));
            return p.next();
        }

        key: Key,

        remaining_in_buffer: usize = 0,
        buf: [counter_length]Word = undefined,
        counter: BufUint(word_size, counter_length) = .init(0),
    };
}

/// This mirrors C++ std::random::philox4x32
pub const Philox4x32 = Philox(4, 32, 10, .{ 0xD2511F53, 0xCD9E8D57 }, .{ 0x9E3779B9, 0xBB67AE85 });

/// This mirrors C++ std::random::philox4x64
pub const Philox4x64 = Philox(4, 64, 10, .{
    0xD2E7470EE14C6C93,
    0xCA5A826395121157,
}, .{
    0x9E3779B97F4A7C15,
    0xBB67AE8584CAA73B,
});

pub const Philox2x32 = Philox(2, 32, 10, .{0xD256D193}, .{0x9E3779B9});
pub const Philox2x64 = Philox(2, 64, 10, .{0xD2B74407B1CE6E93}, .{0x9E3779B97F4A7C15});

test "Philox4x64 discard consistency" {
    var p0: Philox4x64 = .initSeed(123123123);
    var p1: Philox4x64 = .initSeed(123123123);

    const DoDiscard = struct {
        fn aufruf(self: *@This(), p: *Philox4x64, to_discard: u256) void {
            var remaining = to_discard;
            while (remaining != 0) {
                const cur = self.rng.random().intRangeAtMost(u256, 1, remaining);
                remaining -= cur;

                p.discardLarge(.init(cur));
            }
        }

        rng: std.Random.Xoshiro256 = .init(456456456),
    };

    var discarder: DoDiscard = .{};

    const discard_ct = 123456789123456789;
    discarder.aufruf(&p0, discard_ct);
    discarder.aufruf(&p1, discard_ct);

    try std.testing.expectEqual(p0.next(), p1.next());
}

test "Philox4xW-10" {
    // from p2075r6:
    //
    // (about `std::random::philox4x32`)
    //
    // "Required behavior: The 10000th consecutive invocation of a
    // default-constructed object of type philox4x32 produces the value
    // 1955073260."
    {
        var p: Philox4x32 = .init();
        p.discard(9999);
        try std.testing.expectEqual(1955073260, p.next());
    }

    // (about `std::random::philox4x64`)
    //
    // "Required behavior: The 10000th consecutive invocation of a
    // default-constructed object of type philox4x64 produces the value
    // 3409172418970261260."
    {
        var p: Philox4x64 = .init();
        p.discard(9999);
        try std.testing.expectEqual(3409172418970261260, p.next());
    }
}
