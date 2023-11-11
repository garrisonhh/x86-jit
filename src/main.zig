const std = @import("std");
const x86 = @import("x86.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const text = "hello, jit!\n";

    const ops = [_]x86.Op{
        // enter function
        .{ .push = .{ .reg = .rbp } },
        .{
            .mov = .{
                .src = .{ .reg = .rsp },
                .dst = .{ .reg = .rbp },
            },
        },

        // write text
        .{
            .mov = .{
                .src = .{ .imm = .{ .uint = 0x1 } },
                .dst = .{ .reg = .rax },
            },
        },
        .{
            .mov = .{
                .src = .{ .imm = .{ .uint = 0x1 } },
                .dst = .{ .reg = .rdi },
            },
        },
        .{
            .mov = .{
                .src = .{ .imm = .{ .ptr = text.ptr } },
                .dst = .{ .reg = .rsi },
            },
        },
        .{
            .mov = .{
                .src = .{ .imm = .{ .uint = text.len } },
                .dst = .{ .reg = .rdx },
            },
        },
        .syscall,

        // return value
        .{
            .mov = .{
                .src = .{ .imm = .{ .uint = 420 } },
                .dst = .{ .reg = .rax },
            },
        },

        // exit function
        .{ .pop = .{ .reg = .rbp } },
        .ret,
    };

    const F = fn() callconv(.SysV) u64;
    const assembled = try x86.assemble(F, ally, &ops);
    defer assembled.deinit(ally);

    const res = assembled.func()();

    std.debug.print("function returned: {}\n", .{res});
}