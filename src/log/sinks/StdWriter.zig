const std = @import("std");

const kompot = @import("kompot");

const log = kompot.log;

const pattern = log.pattern;

const Message = log.Message;
const Sink = log.Sink;

const Self = @This();

pub fn init(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
) Self {
    return .{
        .alloc = alloc,

        .writer = writer,
    };
}

/// `pattern_string` must outlive this sink
pub fn setPatternString(self: *Self, pattern_string: []const u8) void {
    const num_pattern_elements = pattern.parse(pattern_string, &.{});
    const pattern_elements = self.alloc.alloc(pattern.Element, num_pattern_elements) catch @panic("OOM");
    pattern.parse(pattern_string, pattern_elements);

    self.setPatternElements(self.pattern_elements);
    self.pattern_elements_are_owned = true;
}

pub fn setPatternElements(self: *Self, pattern_elements: []const pattern.Element) void {
    if (self.pattern_elements_are_owned) {
        self.alloc.free(self.pattern_elements);
    }

    self.pattern_elements_are_owned = true;
    self.pattern_elements = pattern_elements;
}

fn vDoSink(sink: *Sink, message: Message) anyerror!void {
    const self: *Self = @alignCast(@fieldParentPtr("sink", sink));

    for (self.pattern_elements) |element| {
        switch (element.flag) {
            .literal_string => |literal_string| try self.writer.writeAll(literal_string),
            .literal_character => |literal_character| try self.writer.writeByte(literal_character),

            .the_log_message => try self.writer.writeAll(message.payload),

            .thread_id => |thread_id| {
                if (thread_id.display_name_if_available and message.thread_name_length != null) {
                    const thread_name = message.thread_name_buffer[0..message.thread_name_length.?];
                    try self.writer.printValue("s", std.fmt.Options{
                        .alignment = element.alignment_kind,
                        .width = element.alignment_width,
                    }, thread_name, 0);
                } else if (message.thread_id) |thread_id_value| {
                    try self.writer.printInt(
                        thread_id_value,
                        10,
                        .lower,
                        .{
                            .alignment = element.alignment_kind,
                            .width = element.alignment_width,
                        },
                    );
                } else {
                    try self.writer.writeAll("???");
                }
            },
            .process_id => @panic("NYI"),
            .logger_name => try self.writer.writeAll(message.logger_name),
            .level => |level| if (level.short)
                try self.writer.writeByte(([_]u8{ '?', 'T', 'D', 'I', 'W', 'E', 'F' })[@intFromEnum(message.level)])
            else
                try self.writer.writeAll(([_][]const u8{
                    "off",
                    "trace",
                    "debug",
                    "info",
                    "warning",
                    "error",
                    "fatal",
                })[@intFromEnum(message.level)]),

            .source => |source| if (message.src) |src| {
                if (source.full_path) {
                    try self.writer.writeAll(src.file);
                } else {
                    try self.writer.writeAll(std.fs.path.basename(src.file));
                }
            } else {
                try self.writer.writeAll("???");
            },

            .source_line => if (message.src) |src| {
                try self.writer.printInt(src.line, 10, .lower, .{});
            } else {
                try self.writer.writeAll("???");
            },

            .source_function => if (message.src) |src| {
                try self.writer.writeAll(src.fn_name);
            } else {
                try self.writer.writeAll("???");
            },

            .ns_from_startup => |ns_from_startup| try self.writer.printInt(
                message.ns_since_startup / ns_from_startup.divisor,
                10,
                .lower,
                .{
                    .alignment = element.alignment_kind,
                    .width = element.alignment_width,
                },
            ),

            .datetime_component => |datetime_component| switch (datetime_component) {
                .weekday_name => |weekday_name| {
                    _ = weekday_name;
                    @panic("NYI");
                },
                .month_name => |month_name| {
                    _ = month_name;
                    @panic("NYI");
                },
                .year => |year| {
                    _ = year;
                    @panic("NYI");
                },
                .month => @panic("NYI"),
                .day_of_month => @panic("NYI"),
                .hours_24 => @panic("NYI"),
                .hours_12 => @panic("NYI"),
                .am_or_pm => @panic("NYI"),
                .minutes => @panic("NYI"),
                .seconds => @panic("NYI"),
                .milliseconds => @panic("NYI"),
                .microseconds => @panic("NYI"),
                .nanoseconds => @panic("NYI"),
            },
        }
    }

    try self.writer.writeAll("\r\n");
}

sink: Sink = .{ .vtable = &.{
    .doSink = &Self.vDoSink,
} },

alloc: std.mem.Allocator,

writer: *std.Io.Writer,

pattern_elements_are_owned: bool = false,
pattern_elements: []const pattern.Element = &pattern.default_patterns.dmesg_esque,
