const std = @import("std");

const kompot = @import("kompot");

pub const pattern = @import("pattern.zig");

pub const Clock = @import("Clock.zig");
pub const Sink = @import("Sink.zig");
pub const Timer = @import("Timer.zig");

pub const StdClock = @import("clocks/StdClock.zig");

pub const StdTimer = @import("timers/StdTimer.zig");
pub const IncrementedTimer = @import("timers/Incremented.zig");

pub const StdWriterSink = @import("sinks/StdWriter.zig");
pub const Os2LockedWrapperSink = @import("sinks/Os2LockedWrapper.zig").Os2LockedWrapper;

pub const Level = enum(u32) {
    off = 0,
    trace = 1,
    debug = 2,
    info = 3,
    warn = 4,
    err = 5,
    fatal = 6,
};

pub const Message = struct {
    src: ?std.builtin.SourceLocation,

    thread_id: usize,
    process_id: usize,

    ns_since_startup: u64,
    time_point: Clock.TimePoint,

    logger_name: []const u8,

    level: Level,

    payload: []const u8,
};

pub const Filter = struct {
    pub const VTable = struct {
        matches: *const fn (filter: *const Filter, message: Message) bool,
    };

    pub fn matches(filter: *const Filter, message: Message) bool {
        return filter.vtable.matches(filter, message);
    }

    vtable: *const VTable,
};

pub const filters = struct {
    pub fn Factory(comptime Predicate: type) type {
        return struct {
            const FSelf = @This();

            pub fn init(predicate: Predicate) FSelf {
                return .{
                    .predicate = predicate,
                };
            }

            fn vMatches(filter: *const Filter, message: Message) bool {
                const self: *const FSelf = @alignCast(@fieldParentPtr("filter", filter));

                return self.predicate.aufruf(message);
            }

            filter: Filter = .{ .vtable = &.{
                .matches = &FSelf.vMatches,
            } },

            predicate: Predicate,
        };
    }

    const unary_logic = struct {
        fn not(v: bool) bool {
            return !v;
        }
    };

    const binary_logic = struct {
        fn @"and"(x: bool, y: bool) bool {
            return x and y;
        }

        fn @"or"(x: bool, y: bool) bool {
            return x or y;
        }

        fn xor(x: bool, y: bool) bool {
            return (!x and y) or (x and !y);
        }

        fn ifThen(x: bool, y: bool) bool {
            return !x or y;
        }
    };

    fn NotPredicate(comptime Inner: type) type {
        return struct {
            const FSelf = @This();

            fn aufruf(self: *const FSelf, message: Message) bool {
                const inner: *const Filter = &self.inner.filter;
                return !inner.matches(message);
            }

            inner: Inner,
        };
    }

    pub fn not(inner: anytype) Factory(NotPredicate(@TypeOf(inner))) {
        return .init(.{ .inner = inner });
    }

    pub fn BinaryPredicate(comptime Lhs: type, comptime Rhs: type, comptime op: anytype) type {
        return struct {
            const FSelf = @This();

            fn aufruf(self: *const FSelf, message: Message) bool {
                const lhs: *const Filter = &self.lhs.filter;
                const rhs: *const Filter = &self.rhs.filter;

                const lhs_res = lhs.matches(message);
                const rhs_res = rhs.matches(message);

                return @call(.auto, op, .{ lhs_res, rhs_res });
            }

            lhs: Lhs,
            rhs: Rhs,
        };
    }

    const NameMatchesPredicate = struct {
        const FSelf = @This();

        fn aufruf(self: *const FSelf, message: Message) bool {
            return std.mem.eql(u8, message.logger_name, self.name);
        }

        name: []const u8,
    };

    pub fn nameMatches(name: []const u8) Factory(NameMatchesPredicate) {
        return .init(.{ .name = name });
    }

    const NameStartsWithPredicate = struct {
        const FSelf = @This();

        fn aufruf(self: *const FSelf, message: Message) bool {
            return std.mem.startsWith(u8, message.logger_name, self.prefix);
        }

        prefix: []const u8,
    };

    pub fn nameStartsWith(prefix: []const u8) Factory(NameStartsWithPredicate) {
        return .init(.{ .prefix = prefix });
    }

    const LevelMoreThanPredicate = struct {
        const FSelf = @This();

        fn aufruf(self: *const FSelf, message: Message) bool {
            return @intFromEnum(message.level) > @intFromEnum(self.level);
        }

        level: Level,
    };

    pub fn levelMoreThan(level: Level) Factory(LevelMoreThanPredicate) {
        return .init(.{ .level = level });
    }

    const LevelLessThanPredicate = struct {
        const FSelf = @This();

        fn aufruf(self: *const FSelf, message: Message) bool {
            return @intFromEnum(message.level) < @intFromEnum(self.level);
        }

        level: Level,
    };

    pub fn levelLessThan(level: Level) Factory(LevelLessThanPredicate) {
        return .init(.{ .level = level });
    }

    pub fn @"and"(lhs: anytype, rhs: anytype) Factory(BinaryPredicate(@TypeOf(lhs), @TypeOf(rhs), binary_logic.@"and")) {
        return .init(.{
            .lhs = lhs,
            .rhs = rhs,
        });
    }

    pub fn @"or"(lhs: anytype, rhs: anytype) Factory(BinaryPredicate(@TypeOf(lhs), @TypeOf(rhs), binary_logic.@"or")) {
        return .init(.{
            .lhs = lhs,
            .rhs = rhs,
        });
    }

    pub fn xor(lhs: anytype, rhs: anytype) Factory(BinaryPredicate(@TypeOf(lhs), @TypeOf(rhs), binary_logic.xor)) {
        return .init(.{
            .lhs = lhs,
            .rhs = rhs,
        });
    }

    pub fn ifThen(lhs: anytype, rhs: anytype) Factory(BinaryPredicate(@TypeOf(lhs), @TypeOf(rhs), binary_logic.ifThen)) {
        return .init(.{
            .lhs = lhs,
            .rhs = rhs,
        });
    }
};

pub const NamedLogger = struct {
    alloc: std.mem.Allocator,

    logger: *Logger,
    name: []const u8,

    fn logImpl(
        self: NamedLogger,
        src: ?std.builtin.SourceLocation,
        level: Level,
        comptime fmt: []const u8,
        args: anytype,
    ) std.mem.Allocator.Error!void {
        const formatted_length = blk: {
            var writer: kompot.DiscardingWriterNoFiles = .init(&.{});
            writer.writer.print(fmt, args) catch unreachable;
            const formatted_length = writer.fullCount();
            break :blk formatted_length;
        };

        const buffer = try self.alloc.alloc(u8, formatted_length);
        defer self.alloc.free(buffer);

        {
            var writer = std.io.Writer.fixed(buffer);
            writer.print(fmt, args) catch unreachable;
        }

        self.logger.logRaw(.{
            .src = src,

            .thread_id = @intCast(std.Thread.getCurrentId()),
            .process_id = 0,

            .time_point = self.logger.clock.now(),
            .ns_since_startup = self.logger.timer.read(),

            .logger_name = self.name,

            .level = level,

            .payload = buffer,
        });
    }

    pub fn t(self: NamedLogger, src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.logImpl(src, .trace, fmt, args) catch {};
    }

    pub fn d(self: NamedLogger, src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.logImpl(src, .debug, fmt, args) catch {};
    }

    pub fn i(self: NamedLogger, src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.logImpl(src, .info, fmt, args) catch {};
    }

    pub fn w(self: NamedLogger, src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.logImpl(src, .warn, fmt, args) catch {};
    }

    pub fn e(self: NamedLogger, src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.logImpl(src, .err, fmt, args) catch {};
    }

    pub fn f(self: NamedLogger, src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.logImpl(src, .fatal, fmt, args) catch {};
    }
};

pub const Logger = struct {
    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        timer: *Timer,
        clock: *Clock,
    ) Self {
        return .{
            .alloc = alloc,

            .timer = timer,
            .clock = clock,
        };
    }

    pub fn addSink(self: *Self, sink: *Sink) std.mem.Allocator.Error!void {
        try self.sinks.append(self.alloc, sink);
    }

    pub fn logRaw(self: *Self, message: Message) void {
        for (self.filters.items) |filter| {
            if (!filter.matches(message)) return;
        }

        for (self.sinks.items) |sink| {
            sink.doSink(message) catch |e| {
                self.sink_error_handler(self.sink_error_handler_context, sink, message, e);
            };
        }
    }

    pub fn getNamedLogger(self: *Self, name: []const u8) NamedLogger {
        return .{
            .alloc = self.alloc,
            .logger = self,
            .name = name,
        };
    }

    pub fn addFilter(self: *Self, filter: *const Filter) std.mem.Allocator.Error!void {
        try self.filters.append(self.alloc, filter);
    }

    alloc: std.mem.Allocator,

    timer: *Timer,
    clock: *Clock,

    sink_error_handler_context: ?*anyopaque = null,
    sink_error_handler: *const fn (ctx: ?*anyopaque, sink: *Sink, message: Message, err: anyerror) void = struct {
        pub fn aufruf(ctx: ?*anyopaque, sink: *Sink, message: Message, err: anyerror) void {
            _ = ctx;
            _ = sink;
            _ = message;
            err catch {};
        }
    }.aufruf,

    sinks: std.ArrayList(*Sink) = .empty,

    filters: std.ArrayList(*const Filter) = .empty,
};
