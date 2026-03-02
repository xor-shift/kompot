const kompot = @import("kompot");

const log = kompot.log;

const Message = log.Message;

const Sink = @This();

pub const VTable = struct {
    doSink: *const fn (sink: *Sink, message: Message) anyerror!void,
};

pub fn doSink(sink: *Sink, message: Message) anyerror!void {
    return sink.vtable.doSink(sink, message);
}

vtable: *const VTable,

pub const Toggleable = struct {
    const Self = @This();

    pub fn init(inner: *Sink) Self {
        return .{
            .inner = inner,
        };
    }

    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }

    fn vDoSink(sink: *Sink, message: Message) anyerror!void {
        const self: *Self = @alignCast(@fieldParentPtr("sink", sink));

        if (!self.enabled) return;

        return self.inner.doSink(message);
    }

    sink: Sink = .{ .vtable = &.{
        .doSink = &Self.vDoSink,
    } },

    enabled: bool = false,

    inner: *Sink,
};
