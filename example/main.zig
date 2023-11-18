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
    try fun_builder.enterSysV();
    try fun_builder.op(.{ .mov = .{ .src = .rdi, .dst = .rax } });
    try fun_builder.op(.{ .add = .{ .src = .rsi, .dst = .rax } });
    try fun_builder.op(.{
        .constant = .{ .bytes = std.mem.asBytes(&@as(u64, 420)), .dst = .rsi },
    });
    try fun_builder.op(.{ .add = .{ .src = .rsi, .dst = .rax } });
    try fun_builder.exitSysV();

    try builder.build();

    // run function
    const fun = jit.get(fun_label, fn(i64, i64) callconv(.SysV) i64);
    const a = 123;
    const b = 456;
    const res = fun(a, b);

    std.debug.print("fun({}, {}) = {}\n", .{a, b, res});
}