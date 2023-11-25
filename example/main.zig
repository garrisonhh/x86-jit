const std = @import("std");
const stderr = std.io.getStdErr().writer();
const blox = @import("blox");
const Jit = @import("x86-jit").Jit;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    var jit = Jit.init(ally);
    defer jit.deinit();

    // compile example function
    var builder = jit.builder();
    defer builder.deinit();

    const fun_builder = try builder.block();
    const base_case = try builder.block();

    try fun_builder.op(.{ .enter = 16 });
    try fun_builder.op(.{
        .constant = .{
            .bytes = std.mem.asBytes(&@as(u64, 1)),
            .dst = .rbx,
        }
    });

    // if n <= 1 then do recursive call, otherwise return 1 (base case)
    try fun_builder.op(.{ .cmp = .{ .lhs = .rdi, .rhs = .rbx } });
    try fun_builder.op(.{
        .jump_if = .{ .cond = .le, .label = base_case.label },
    });

    // n' = n - 1
    try fun_builder.op(.{ .sub = .{ .src = .rbx, .dst = .rdi } });
    try fun_builder.op(.{
        .stack_store = .{ .size = .qword, .offset = -8, .src = .rdi },
    });

    // res = fib(n')
    try fun_builder.op(.{ .call = fun_builder.label });
    try fun_builder.op(.{
        .stack_store = .{ .size = .qword, .offset = -16, .src = .rax },
    });

    // return res + fib(n' - 1)
    try fun_builder.op(.{
        .stack_load = .{ .size = .qword, .offset = -8, .dst = .rdi },
    });
    try fun_builder.op(.{ .sub = .{ .src = .rbx, .dst = .rdi } });
    try fun_builder.op(.{ .call = fun_builder.label });
    try fun_builder.op(.{
        .stack_load = .{ .size = .qword, .offset = -16, .dst = .rdx },
    });
    try fun_builder.op(.{ .add = .{ .src = .rdx, .dst = .rax } });
    try fun_builder.op(.leave);
    try fun_builder.op(.ret);

    // return 1
    try base_case.op(.{ .mov = .{ .src = .rbx, .dst = .rax } });
    try base_case.op(.leave);
    try base_case.op(.ret);

    // dump
    var mason = blox.Mason.init(ally);
    defer mason.deinit();

    const rendered = try builder.render(&mason);
    try mason.write(rendered, stderr, .{});

    // build and run function
    try builder.build();

    const fib = jit.get(fun_builder.label, fn(u64) callconv(.SysV) u64);

    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    for (0..20) |n| {
        const res = fib(n);
        try writer.print("fib({}) = {}\n", .{n, res});
    }

    try bw.flush();
}