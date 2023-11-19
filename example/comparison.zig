//! equivalent to example jit code for benchmarking purposes

const std = @import("std");

fn fib(n: u64) u64 {
    return if (n <= 1) 1 else fib(n - 1) + fib(n - 2);
}

pub fn main() !void {
    var bw = std.io.bufferedWriter(std.io.getStdErr().writer());
    const writer = bw.writer();

    for (0..20) |n| {
        try writer.print("fib({}) = {}\n", .{n, fib(n)});
    }

    try bw.flush();
}