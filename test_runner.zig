const std = @import("std");

const root = @import("root");

const SGR = @import("sgr");

fn printf(comptime fmt: []const u8, args: anytype) void {
    var writer = std.fs.File.stdout().writer(&.{});
    writer.interface.print(fmt, args) catch {};
}

pub fn main() !void {
    // @compileLog(@hasDecl(root, "core"));

    const builtin = @import("builtin");

    // LARP just to make the output look like that of googletest's
    // Don't take this seriously
    printf("{s}[----------]{s} Global test environment set-up\n", .{
        &(SGR{ .foreground = .{ .color = .Green } }).to_str(),
        &(SGR{}).to_str(),
    });

    printf("{s}[----------]{s} {d} test{s} from {s}\n", .{
        &(SGR{ .foreground = .{ .color = .Green } }).to_str(),
        &(SGR{}).to_str(),
        builtin.test_functions.len,
        if (builtin.test_functions.len == 1) "" else "s",
        "N/A",
    });

    var results: struct {
        passed: usize = 0,
        failed: usize = 0,
        leaked: usize = 0,
    } = .{};

    for (builtin.test_functions) |test_function| {
        printf("{s}[ RUN      ]{s} {s}\n", .{
            &(SGR{ .foreground = .{ .color = .Green } }).to_str(),
            &(SGR{}).to_str(),
            test_function.name,
        });

        std.testing.allocator_instance = .{};

        const result = test_function.func();

        if (std.testing.allocator_instance.deinit() == .leak) {
            results.leaked += 1;
            printf("{s}[  LEAKED  ]{s} {s}\n", .{
                &(SGR{ .foreground = .{ .color = .Red } }).to_str(),
                &(SGR{}).to_str(),
                test_function.name,
            });
            continue;
        }

        if (result) |_| {
            results.passed += 1;
            printf("{s}[       OK ]{s} {s}\n", .{
                &(SGR{ .foreground = .{ .color = .Green } }).to_str(),
                &(SGR{}).to_str(),
                test_function.name,
            });
        } else |err| {
            results.failed += 1;
            printf("{any}\n", .{err});

            const trace = @errorReturnTrace().?;
            printf("{any}\n", .{trace});

            printf("{s}[  FAILED  ]{s} {s}\n", .{
                &(SGR{ .foreground = .{ .color = .Red } }).to_str(),
                &(SGR{}).to_str(),
                test_function.name,
            });
        }
    }

    // LARP just to make the output look like that of googletest's
    // Don't take this seriously
    printf("{s}[----------]{s} Global test environment tear-down\n", .{
        &(SGR{ .foreground = .{ .color = .Green } }).to_str(),
        &(SGR{}).to_str(),
    });

    if (results.passed != 0) {
        printf("{s}[  PASSED  ]{s} {d} test{s}\n", .{
            &(SGR{ .foreground = .{ .color = .Green } }).to_str(),
            &(SGR{}).to_str(),
            results.passed,
            if (results.passed == 1) "" else "s",
        });
    }

    if (results.leaked != 0) {
        printf("{s}[  LEAKED  ]{s} {d} test{s}\n", .{
            &(SGR{ .foreground = .{ .color = .Red } }).to_str(),
            &(SGR{}).to_str(),
            results.leaked,
            if (results.leaked == 1) "" else "s",
        });

        // TODO: list leaked
    }

    if (results.failed != 0) {
        printf("{s}[  FAILED  ]{s} {d} test{s}\n", .{
            &(SGR{ .foreground = .{ .color = .Red } }).to_str(),
            &(SGR{}).to_str(),
            results.failed,
            if (results.failed == 1) "" else "s",
        });

        // TODO: list failed
    }

    std.process.exit(0);
}
