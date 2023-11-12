const std = @import("std");
const Allocator = std.mem.Allocator;
const x86 = @import("x86.zig");
const Lexer = @import("Lexer.zig");

pub const CompileError = Lexer.Error || x86.AssembleError;

pub const CompiledFunc = fn() callconv(.SysV) void;
pub const Compiled = x86.Assembled(CompiledFunc);

pub fn compile(ally: Allocator, program: []const u8) CompileError!Compiled {
    _ = ally;

    var lexer = Lexer.init(program);
    while (try lexer.next()) |token| {
        std.debug.print("{} `{s}`\n", .{token, lexer.slice(token)});
    }

    @panic("TODO");
}