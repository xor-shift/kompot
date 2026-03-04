const std = @import("std");

pub const Flag = union(enum) {
    literal_string: []const u8,
    literal_character: u8,

    the_log_message,

    thread_id,
    process_id,
    logger_name,
    level: struct { short: bool = false },

    source: struct { full_path: bool = false },
    source_line,
    source_function,

    ns_from_startup: struct { divisor: u64 = 1 },

    datetime_component: union(enum) {
        weekday_name: struct { abbreviated: bool },
        month_name: struct { abbreviated: bool },
        year: struct { last_two_digits: bool },
        month, //< 01-12
        day_of_month, //< 01-31
        hours_24,
        hours_12,
        am_or_pm,
        minutes, //< 00-59
        seconds, //< 00-59
        milliseconds, //< 000-999
        microseconds, //< 000000-999999
        nanoseconds, //< 000000000-999999999
    },
};

pub const Element = struct {
    alignment_kind: std.fmt.Alignment = .right,
    alignment_width: usize = 0,
    flag: Flag,
};

/// parses a pattern string and writes the pattern elements into
/// `buffer`. if `buffer` isn't large enough for all of the pattern
/// elements in the given pattern string, the excess pattern elements
/// will not get written but they will still be processed.
///
/// to get the number of pattern elements in a pattern string, simply
/// pass an empty buffer and check the return value of this function.
///
/// check spdlog patterns for possible pattern flags.
///
/// the pattern string must outlive the elements in the buffer.
pub fn parse(pattern_str: []const u8, buffer: []Element) usize {
    const emitElement: struct {
        pub fn aufruf(self: *@This(), elem: Element) void {
            defer self.ptr += 1;

            if (self.ptr >= self.buffer.len) return;

            self.buffer[self.ptr] = elem;
        }

        buffer: []Element,
        ptr: usize = 0,
    } = .{
        .buffer = buffer,
    };

    // TODO: SIMD
    var consumed_characters: usize = 0;
    while (true) {
        const remaining_str = pattern_str[consumed_characters..];

        const index_of_next_percent = std.mem.indexOfScalar(u8, remaining_str, '%') orelse remaining_str.len;

        if (index_of_next_percent != 0) {
            const literal_to_emit = remaining_str[0..index_of_next_percent];
            if (literal_to_emit.len != 0) {
                emitElement.aufruf(.{ .literal_string = literal_to_emit });
            }

            consumed_characters += literal_to_emit.len;

            continue;
        }

        // technically, if this is true, we should return an error.
        const bad_flag = remaining_str.len == 1;
        defer consumed_characters += if (bad_flag) 1 else 2;

        const flag_char = if (bad_flag) '%' else remaining_str[1];
        switch (flag_char) {
            'v' => emitElement.aufruf(.payload),
            else => |c| emitElement.aufruf(.{ .character = c }),
        }
    }

    return emitElement.ptr;
}

pub const default_patterns = struct {
    pub const zig_esque = [_]Element{
        Element{ .flag = .logger_name },
        Element{ .flag = .{ .literal_string = ": " } },
        Element{ .flag = .the_log_message },
    };

    pub const dmesg_esque = [_]Element{
        Element{ .flag = .{ .level = .{ .short = true } } },
        Element{ .flag = .{ .level = .{ .short = true } } },
        Element{ .flag = .{ .level = .{ .short = true } } },
        Element{ .flag = .{ .level = .{ .short = true } } },
        Element{ .flag = .{ .literal_string = " (" } },
        Element{
            .flag = .thread_id,
            .alignment_kind = .right,
            .alignment_width = "4294967295".len,
        },
        Element{ .flag = .{ .literal_string = ") [" } },
        Element{
            .flag = .{ .ns_from_startup = .{ .divisor = std.time.ns_per_ms } },
            .alignment_kind = .right,
            .alignment_width = "4294967295".len,
        },
        Element{ .flag = .{ .literal_string = "] " } },
        Element{ .flag = .logger_name },
        Element{ .flag = .{ .literal_string = ": " } },
        Element{ .flag = .the_log_message },
    };
};
