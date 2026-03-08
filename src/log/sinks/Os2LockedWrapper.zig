const kompot = @import("kompot");

const log = kompot.log;

const Message = log.Message;
const Sink = log.Sink;

pub fn Os2LockedWrapper(comptime os2: type) type {
    return struct {
        pub const Self = @This();

        pub fn init(inner: *Sink) !Self {
            const mutex = try os2.Mutex.init(.{ .name = "Os2LockedWrapper mutex" });
            errdefer mutex.deinit();

            return .{
                .mutex = mutex,
                .inner = inner,
            };
        }

        fn vDoSink(sink: *Sink, message: Message) anyerror!void {
            const self: *Self = @alignCast(@fieldParentPtr("sink", sink));

            self.mutex.acquire(.wait_forever) catch @panic("unhandled error");
            defer self.mutex.release() catch @panic("unhandled error");

            return self.inner.doSink(message);
        }

        sink: Sink = .{ .vtable = &.{
            .doSink = Self.vDoSink,
        } },

        mutex: os2.Mutex,
        inner: *Sink,
    };
}
