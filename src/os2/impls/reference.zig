const std = @import("std");

pub const Error = error{
    /// Unspecified RTOS error: run-time error but no other error
    /// message fits.
    Unspecified,

    /// Operation not completed within the timeout period.
    Timeout,

    /// Resource not available.
    Resource,

    /// Parameter error.
    Parameter,

    /// System is out of memory: it was impossible to allocate or
    /// reserve memory for the operation.
    NoMemory,

    /// Not allowed in ISR context: the function cannot be called from
    /// interrupt service routines.
    Isr,
};

/// A timeout value of `dont_wait` will make the function the timeout
/// value is given to return instantly and `wait_forever` will make it
/// wait forever. All other values are in nanoseconds.
///
/// The normal timeout value gets rounded down to the nearest
/// tick. Timeout values that would have gotten rounded down to 0 ticks
/// will get rounded up to 1 tick.
pub const TimeoutNS = enum(u64) {
    dont_wait = 0,
    wait_forever = std.math.maxInt(u64),
    _,
};

/// This function is best-effort and might over- or undershoot the
/// given nanoseconds value.
///
/// A return value of `Error.Parameter` means that the time can't be
/// handled (0 ticks).
///
/// A return value of `Error.Unspecified` could mean that the kernel is
/// not running or that no *READY* thread exists.
pub fn delay(nanoseconds: u64) Error!void {
    _ = nanoseconds;
    @panic("not implemented");
}

pub const Thread = struct {
    pub const Settings = struct {
        pub const Flags = packed struct {
            joinable: bool = false,
            unprivileged: bool = false,
            privileged: bool = false,
        };

        pub const Priority = enum(u32) {
            none = 0,
            idle = 1,
            low = 8,
            low_1 = 8 + 1,
            low_2 = 8 + 2,
            low_3 = 8 + 3,
            low_4 = 8 + 4,
            low_5 = 8 + 5,
            low_6 = 8 + 6,
            low_7 = 8 + 7,
            below_normal = 16,
            below_normal_1 = 16 + 1,
            below_normal_2 = 16 + 2,
            below_normal_3 = 16 + 3,
            below_normal_4 = 16 + 4,
            below_normal_5 = 16 + 5,
            below_normal_6 = 16 + 6,
            below_normal_7 = 16 + 7,
            normal = 24,
            normal_1 = 24 + 1,
            normal_2 = 24 + 2,
            normal_3 = 24 + 3,
            normal_4 = 24 + 4,
            normal_5 = 24 + 5,
            normal_6 = 24 + 6,
            normal_7 = 24 + 7,
            above_normal = 32,
            above_normal_1 = 32 + 1,
            above_normal_2 = 32 + 2,
            above_normal_3 = 32 + 3,
            above_normal_4 = 32 + 4,
            above_normal_5 = 32 + 5,
            above_normal_6 = 32 + 6,
            above_normal_7 = 32 + 7,
            high = 40,
            high_1 = 40 + 1,
            high_2 = 40 + 2,
            high_3 = 40 + 3,
            high_4 = 40 + 4,
            high_5 = 40 + 5,
            high_6 = 40 + 6,
            high_7 = 40 + 7,
            realtime = 48,
            realtime_1 = 48 + 1,
            realtime_2 = 48 + 2,
            realtime_3 = 48 + 3,
            realtime_4 = 48 + 4,
            realtime_5 = 48 + 5,
            realtime_6 = 48 + 6,
            realtime_7 = 48 + 7,
            isr = 56,
            _,
        };

        pub const State = enum(u32) {
            inactive = 0,
            ready = 1,
            running = 2,
            blocked = 3,
            terminated = 4,
        };

        name: ?[:0]const u8 = null,
        static_memory: ?[]u8 = null,

        stack: union(enum) {
            manual: []u8,
            automatic: usize,
        },

        priority: Priority = .normal,
        flags: Flags = .{},
    };
};

pub const Semaphore = struct {
    pub const Settings = struct {
        name: ?[:0]const u8 = null,
        static_memory: ?[]u8 = null,
    };

    pub fn init() Error!Semaphore {
        @panic("not implemented");
    }

    /// A return value of `Error.Resource` means that the semaphore is
    /// in an invalid state.
    ///
    /// A return value of `Error.Parameter` means that the semaphore
    /// handle is invalid.
    ///
    /// A panic should ideally take place if this function returns an
    /// error.
    pub fn deinit(self: *Semaphore) Error!void {
        _ = self;
        @panic("not implemented");
    }

    pub fn getName(self: Semaphore) [:0]const u8 {
        _ = self;

        @panic("not implemented");
    }

    /// A return value of `Error.Timeout` means that the semaphore
    /// couldn't be acquired in the timeout given.
    ///
    /// A return value of `Error.Resource` means that the semaphore
    /// couldn't be acquired despite there being no timeout.
    ///
    /// A return value of `Error.Parameter` means that the semaphore
    /// handle is invalid.
    pub fn acquire(self: *Semaphore, timeout_ns: TimeoutNS) Error!void {
        _ = self;
        _ = timeout_ns;

        @panic("not implemented");
    }

    /// A return value of `Error.Resource` means that the semaphore
    /// couldn't be released as the token count has reached the upper
    /// limit.
    ///
    /// A return value of `Error.Parameter` means that the semaphore
    /// handle is invalid.
    pub fn release(self: *Semaphore) Error!void {
        _ = self;

        @panic("not implemented");
    }
};

pub const Mutex = struct {
    pub const Settings = struct {
        name: ?[:0]const u8 = null,
        static_memory: ?[]u8 = null,
    };
};

pub const RecursiveMutex = struct {
    pub const Settings = Mutex.Settings;
};
