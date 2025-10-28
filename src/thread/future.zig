const std = @import("std");

pub fn Future(comptime T: type) type {
    return struct {
        promise: *Promise(T),

        pub fn wait(self: @This()) void {
            self.promise.mutex.lock();
            defer self.promise.mutex.unlock();

            while (self.promise.result == null) {
                self.promise.cv.wait(&self.promise.mutex);
            }
        }

        pub fn get(self: @This()) T {
            self.wait();

            // no need to bother with locks at this point
            return self.promise.result.?;
        }
    };
}

/// A very rudimentary promise type
pub fn Promise(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        cv: std.Thread.Condition = .{},
        result: ?T = null,

        pub fn set_value(self: *@This(), v: T) void {
            self.mutex.lock();

            std.debug.assert(self.result == null);
            self.result = v;

            self.cv.signal();

            self.mutex.unlock();
        }

        /// Pins `self`.
        pub fn get_future(self: *@This()) Future(T) {
            return .{ .promise = self };
        }
    };
}
