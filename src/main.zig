//! module for x86-jit

const builtin = @import("builtin");

comptime {
    if (builtin.target.cpu.arch != .x86_64) {
        @compileError("x86-jit is only usable on the x86_64 architecture");
    }
}

pub const Jit = @import("Jit.zig");