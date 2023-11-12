const std = @import("std");
const compilation = @import("compile.zig");
const compile = compilation.compile;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const program =
        \\3 5 4 debug - debug + debug
    ;

    const compiled = try compile(ally, program);
    defer compiled.deinit(ally);

    const func = compiled.func();
    func();
}