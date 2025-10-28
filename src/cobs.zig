const std = @import("std");

const kompot = @import("root.zig");

pub const Reader = struct {
    const Self = @This();

    const State = union(enum) {
        waiting_restart,

        normal: struct {
            expecting_overhead: bool,
            next_offset_in: u8,
        },
    };

    inner: *std.io.Reader,

    reader: std.io.Reader,

    state: State = .{ .normal = .{
        .expecting_overhead = true,
        .next_offset_in = 0,
    } },

    pub fn init(inner: *std.io.Reader, buffer: []u8) Self {
        return .{
            .inner = inner,
            .reader = .{
                .buffer = buffer,
                .vtable = &std.io.Reader.VTable{
                    .stream = &Self.stream,
                },
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn restart(self: *Self) void {
        self.state = .{ .normal = .{
            .expecting_overhead = true,
            .next_offset_in = 0,
        } };
    }

    pub fn stream(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
        const self: *Self = @fieldParentPtr("reader", r);

        var state = switch (self.state) {
            .waiting_restart => return std.io.Reader.StreamError.EndOfStream,
            .normal => |v| v,
        };

        var wrote: usize = 0;
        outer: while (true) {
            if (limit.toInt()) |v| {
                std.debug.assert(wrote <= v);
                if (wrote == v) break;
            }

            const cur_byte = blk: {
                var cur_byte: u8 = undefined;
                var vec: [1][]u8 = .{(&cur_byte)[0..1]};

                const num_read = try self.inner.readVec(&vec);

                if (num_read == 0) {
                    break :outer;
                }

                std.debug.assert(num_read == 1);

                break :blk cur_byte;
            };

            if (cur_byte == 0) {
                self.state = .waiting_restart;
                break;
            }

            if (state.next_offset_in == 0) {
                if (!state.expecting_overhead) {
                    try w.writeByte(0);
                    wrote += 1;
                }

                state = .{
                    .next_offset_in = cur_byte - 1,
                    .expecting_overhead = cur_byte == 0xFF,
                };

                continue;
            }

            try w.writeByte(cur_byte);
            wrote += 1;
            state.next_offset_in -= 1;
        }

        return wrote;
    }
};

test Reader {
    const cobs_input = [_]u8{
        0x01, 0x05, 0x01, 0x02, 0x03, 0x04, 0x00,
    } //
        ++ [_]u8{0xFF} ++ ([_]u8{0x55} ** 254) //
        ++ [_]u8{0xFE} ++ ([_]u8{0xAA} ** 250 ++ [_]u8{ 0xAB, 0xAC, 0xAD }) ++ [_]u8{0x00};
    var raw_cobs_reader = std.io.Reader.fixed(&cobs_input);
    var cobs_reader = Reader.init(&raw_cobs_reader, &.{});

    var output_buffer: [5 + 254 + 253]u8 = undefined;
    var decoded_writer = std.io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(5, try cobs_reader.reader.stream(&decoded_writer, .unlimited));
    try std.testing.expectError(
        std.io.Reader.StreamError.EndOfStream,
        cobs_reader.reader.stream(&decoded_writer, .unlimited),
    );

    cobs_reader.restart();

    {
        var total_read: usize = 0;

        while (true) {
            const curr_read = cobs_reader.reader.stream(&decoded_writer, .unlimited) catch |e| switch (e) {
                std.io.Reader.StreamError.EndOfStream => {
                    std.log.debug("end of stream from cobs_reader", .{});
                    break;
                },
                else => return e,
            };

            std.log.debug("cobs_reader gave us {d} byte(s)", .{curr_read});
            total_read += curr_read;

            if (curr_read == 0) break;
        }

        try std.testing.expectEqual(254 + 253, total_read);
    }

    try std.testing.expectEqual(5 + 254 + 253, decoded_writer.end);

    const expected_output = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04,
    } //
        ++ ([_]u8{0x55} ** 254) //
        ++ ([_]u8{0xAA} ** 250) //
        ++ [_]u8{ 0xAB, 0xAC, 0xAD };
    try std.testing.expectEqualSlices(u8, &expected_output, &output_buffer);
}
