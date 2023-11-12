const std = @import("std");
const compilation = @import("compile.zig");
const compile = compilation.compile;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const program =
        \\1 2 + .
    ;

    const compiled = try compile(ally, program);
    defer compiled.deinit(ally);

    compiled.func()();
}