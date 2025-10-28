const std = @import("std");

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = Channel(T);

        mutex: std.Thread.Mutex = .{},
        open: bool = true,
        data: ?T = null,
        cv_waiting_to_send: std.Thread.Condition = .{},
        cv_waiting_to_recv: std.Thread.Condition = .{},

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.open = false;
            self.cv_waiting_to_send.broadcast();
            self.cv_waiting_to_recv.broadcast();
        }

        pub fn send_start(self: *Self, data: T) bool {
            self.mutex.lock();

            while (true) {
                if (!self.open) return false;
                if (self.data == null) break;

                self.cv_waiting_to_send.wait(&self.mutex);
            }

            self.data = data;

            return true;
        }

        pub fn send_end(self: *Self) void {
            self.cv_waiting_to_recv.signal();

            self.mutex.unlock();
        }

        pub fn send(self: *Self, data: T) bool {
            const ret = self.send_start(data);
            self.send_end();

            return ret;
        }

        pub fn recv_start(self: *Self) ?T {
            self.mutex.lock();

            const data = blk: while (true) {
                if (self.data) |v| break :blk v;
                if (!self.open) return null;

                self.cv_waiting_to_recv.wait(&self.mutex);
            };

            return data;
        }

        pub fn recv_end(self: *Self) void {
            self.data = null;
            self.cv_waiting_to_send.signal();
            self.mutex.unlock();
        }

        pub fn recv(self: *Self) ?T {
            const ret = self.recv_start();
            self.recv_end();

            return ret;
        }
    };
}
