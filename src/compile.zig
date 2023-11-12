const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const x86 = @import("x86.zig");
const lang = @import("lang.zig");
const Context = lang.Context;

pub const CompileError = Lexer.Error || x86.AssembleError;

fn compileToken(ctx: *Context, tok: Token, text: []const u8) CompileError!void {
    switch (tok.tag) {
        .int => {
            const val = std.fmt.parseInt(i64, text, 0) catch {
                @panic("TODO handle int parse error");
            };

            try ctx.push(.{ .imm = .{ .sint = val } });
        },
        .real => {
            @panic("TODO compile floats");
        },
        .word => {
            if (std.meta.stringToEnum(lang.Builtin, text)) |bw| {
                try bw.compile(ctx);
            } else {
                @panic("TODO custom words");
            }
        },
    }
}

pub fn compile(
    ally: Allocator,
    program: []const u8,
) CompileError!lang.Compiled {
    var lexer = Lexer.init(program);
    var ctx = Context{ .ally = ally };
    defer ctx.deinit();

    try ctx.ops(&lang.compiled_prelude);

    while (try lexer.next()) |token| {
        try compileToken(&ctx, token, lexer.slice(token));
    }

    try ctx.ops(&lang.compiled_epilog);

    return try ctx.assemble();
}