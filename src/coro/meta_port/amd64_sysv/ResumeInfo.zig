const std = @import("std");

const Self = @This();

const comptimePrint = std.fmt.comptimePrint;

stack_pointer: [*]u8,

pub fn init(
    stack: []u8,
    bootstrap_at: *const fn (
        bootstrap_arg_0: *const anyopaque,
        bootstrap_arg_1: *const anyopaque,
    ) callconv(.c) void,
    bootstrap_arg_0: *const anyopaque,
    bootstrap_arg_1: *const anyopaque,
) Self {
    const sp = stack[0..].ptr + stack.len;

    // what was he cooking?
    // asm volatile (
    //     \\ movq %%rsp, %%rax
    //     \\ movq %[the_sp], %%rsp
    //     \\ pushq %[bootstrap_at]
    //     \\ pushq %[bootstrap_arg_0]
    //     \\ pushq %[bootstrap_arg_1]
    //     \\ movq %%rax, %%rsp
    //     :
    //     : [bootstrap_at] "r" (bootstrap_at),
    //       [bootstrap_arg_0] "r" (bootstrap_arg_0),
    //       [bootstrap_arg_1] "r" (bootstrap_arg_1),
    //       [the_sp] "r" (sp),
    //     : .{
    //       .rax = true,
    //       .memory = true,
    //     });

    const args = sp - 24;
    @memcpy(args[0..8], std.mem.asBytes(&@intFromPtr(bootstrap_arg_1)));
    @memcpy(args[8..16], std.mem.asBytes(&@intFromPtr(bootstrap_arg_0)));
    @memcpy(args[16..24], std.mem.asBytes(&@intFromPtr(bootstrap_at)));

    return .{
        .stack_pointer = sp,
    };
}

const push_registers =
    \\ push rbx
    \\ push r12
    \\ push r13
    \\ push r14
    \\ push r15
    \\ push rbp
    \\ push rdi // just in case, `self`
    \\ push rsi // just in case, `restore_self`
;

const pop_registers =
    \\ pop rsi
    \\ pop rdi
    \\ pop rbp
    \\ pop r15
    \\ pop r14
    \\ pop r13
    \\ pop r12
    \\ pop rbx
;

pub fn bootstrap(
    self: *Self, // rdi
    restore_self: *Self, // rsi
) callconv(.c) void {
    _ = self;
    _ = restore_self;

    asm volatile (comptimePrint(
            // fuck you, zig, i'm not going to use at&t
            \\ .intel_syntax noprefix
            \\
        ++ push_registers ++
            \\
            // yeah
            \\ mov [rsi + {0}], rsp
            \\ mov rsp, [rdi + {0}]
            \\
            // recover the arguments to `init`
            \\ mov rax, [rsp - 1 * 8] // bootstrap_at
            \\ mov rdi, [rsp - 2 * 8] // bootstrap_arg_0
            \\ mov rsi, [rsp - 3 * 8] // bootstrap_arg_1
            \\
            // avoid stack unwinding past this point
            \\ push 0     // return address
            \\ mov rbp, 0 // bad base pointer
            \\
            // ok let's go
            \\ jmp rax
            \\
            \\ // unreachable
            \\ 1:
            \\ jmp 1b
        , .{
            @offsetOf(Self, "stack_pointer"),
        }) ::: .{
            // the lion does not care about register clobbers
            // the lion thinks he understands the compiler
            .memory = true,
        });
}

/// Use this function if you want cooperative scheduling.
///
/// `doResumeShallow` forces the compiler to save caller-saved
/// registers as per the amd64 ABI. use `doResume` for an ABI-agnostic
/// resumption function.
pub fn doResume(
    self: *Self,
    restore_self: *Self,
) callconv(.c) void {
    _ = self;
    _ = restore_self;

    asm volatile (comptimePrint(
            \\ .intel_syntax noprefix
        ++ push_registers ++
            \\
            \\ mov [rsi + {0}], rsp
            \\ mov rsp, [rdi + {0}]
            \\
        ++ pop_registers ++
            \\
        , .{
            @offsetOf(Self, "stack_pointer"),
        }) ::: .{
            // the lion does not care about register clobbers
            // the lion thinks he understands the compiler
            .memory = true,
        });
}

test {
    const test_fun = struct {
        fn aufruf(bootstrap_arg_0: *const anyopaque, bootstrap_arg_1: *const anyopaque) callconv(.c) void {
            const inner: *Self = @ptrCast(@alignCast(@constCast(bootstrap_arg_0)));
            const restore_self: *Self = @ptrCast(@alignCast(@constCast(bootstrap_arg_1)));

            std.log.debug("pre restore_self.doResume", .{});
            restore_self.doResume(inner);
            std.log.debug("after first restore_self.doResume", .{});
            restore_self.doResume(inner);
        }
    }.aufruf;

    var stack: [65536]u8 align(16) = undefined;

    var inner: Self = undefined;
    var restore_self: Self = undefined;

    inner = .init(&stack, &test_fun, @ptrCast(&inner), @ptrCast(&restore_self));

    std.log.debug("0: {X:016}", .{@as(usize, @bitCast(stack[65536 - 1 * 8 .. 65536 - 0 * 8].*))});
    std.log.debug("1: {X:016}", .{@as(usize, @bitCast(stack[65536 - 2 * 8 .. 65536 - 1 * 8].*))});
    std.log.debug("2: {X:016}", .{@as(usize, @bitCast(stack[65536 - 3 * 8 .. 65536 - 2 * 8].*))});
    std.log.debug("test_fun: {*}", .{&test_fun});
    std.log.debug("inner   : {*}", .{&inner});
    std.log.debug("restore : {*}", .{&restore_self});

    std.log.debug("pre-inner.bootstrap", .{});
    inner.bootstrap(&restore_self);
    std.log.debug("pre-inner.doResume", .{});
    inner.doResume(&restore_self);
    std.log.debug("post-inner.doResume", .{});
}
