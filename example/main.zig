const std = @import("std");
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
    const fun_label = fun_builder.label;

    const base_case = try builder.block();

    try fun_builder.op(.{ .enter = 0 });
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

    // return fib(n - 1) + fib(n - 2)
    try fun_builder.op(.{ .sub = .{ .src = .rbx, .dst = .rdi } });
    try fun_builder.op(.{ .push = .rdi });
    try fun_builder.op(.{ .call = fun_builder.label });
    try fun_builder.op(.{ .pop = .rdi });
    try fun_builder.op(.{ .push = .rax });
    try fun_builder.op(.{ .sub = .{ .src = .rbx, .dst = .rdi } });
    try fun_builder.op(.{ .call = fun_builder.label });
    try fun_builder.op(.{ .pop = .rdx });
    try fun_builder.op(.{ .add = .{ .src = .rdx, .dst = .rax } });
    try fun_builder.op(.leave);
    try fun_builder.op(.ret);

    // return 1
    try base_case.op(.{ .mov = .{ .src = .rbx, .dst = .rax } });
    try base_case.op(.leave);
    try base_case.op(.ret);

    try builder.build();

    // run function
    const fib = jit.get(fun_label, fn(u64) callconv(.SysV) u64);

    for (0..20) |n| {
        std.debug.print("fib({}) = {}\n", .{n, fib(n)});
    }
}