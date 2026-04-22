const std = @import("std");

const kompot = @import("kompot");

const log = kompot.log;

const Message = log.Message;
const Sink = log.Sink;

pub const Self = @This();

pub fn init(io: std.Io, inner: *Sink) !Self {
    return .{
        .io = io,
        .inner = inner,
    };
}

pub fn deinit(self: *Self) void {
    self.deinit();
}

fn vDoSink(sink: *Sink, message: Message) anyerror!void {
    const self: *Self = @alignCast(@fieldParentPtr("sink", sink));

    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    return self.inner.doSink(message);
}

sink: Sink = .{ .vtable = &.{
    .doSink = Self.vDoSink,
} },

io: std.Io,

mutex: std.Io.Mutex = .init,
inner: *Sink,
