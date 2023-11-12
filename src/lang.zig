//! compilation boilerplate and helpers

const std = @import("std");
const Allocator = std.mem.Allocator;
const x86 = @import("x86.zig");

pub const CompiledFunc = fn () callconv(.SysV) void;
pub const Compiled = x86.Assembled(CompiledFunc);

pub const Context = struct {
    const Self = @This();

    ally: Allocator,
    program: std.ArrayListUnmanaged(x86.Op) = .{},

    pub fn init(ally: Allocator) Self {
        return Self{ .ally = ally };
    }

    pub fn deinit(self: *Self) void {
        self.program.deinit(self.ally);
    }

    pub fn assemble(self: *Self) x86.AssembleError!Compiled {
        return try x86.assemble(CompiledFunc, self.ally, self.program.items);
    }

    /// add raw op
    pub fn op(self: *Self, o: x86.Op) Allocator.Error!void {
        try self.program.append(self.ally, o);
    }

    /// add raw ops
    pub fn ops(self: *Self, os: []const x86.Op) Allocator.Error!void {
        try self.program.appendSlice(self.ally, os);
    }

    pub fn call(self: *Self, func_ptr: *const anyopaque) Allocator.Error!void {
        try self.ops(&.{
            .{
                .mov = .{
                    .src = .{ .imm = .{ .ptr = func_ptr } },
                    .dst = .{ .reg = .rax },
                },
            },
            .{ .call = .{ .reg = .rax } },
        });
    }

    /// push a value onto the value stack
    pub fn push(self: *Self, value: x86.RRmIOArg) Allocator.Error!void {
        try self.ops(&.{
            .{
                .mov = .{
                    .src = value,
                    .dst = .{ .reg = .rdi },
                },
            },
        });
        try self.call(&Stack.push);
    }

    /// pop from value stack to a register (rax is most efficient)
    pub fn pop(self: *Self, dst: x86.Register) Allocator.Error!void {
        try self.call(&Stack.pop);

        if (dst == .rax) return;
        try self.op(.{
            .mov = .{
                .src = .{ .reg = .rax },
                .dst = .{ .reg = dst },
            },
        });
    }

    /// pop multiple values into registers (in order)
    pub fn popMany(self: *Self, regs: []const x86.Register) Allocator.Error!void {
        if (regs.len > 1) {
            for (0..regs.len - 1) |_| {
                try self.pop(.rax);
                try self.op(.{ .push = .{ .reg = .rax } });
            }
        }

        if (regs.len > 0) {
            try self.pop(regs[regs.len - 1]);
        }

        if (regs.len > 1) {
            var rev_regs = std.mem.reverseIterator(regs[0..regs.len - 1]);
            while (rev_regs.next()) |reg| {
                try self.op(.{ .pop = .{ .reg = reg } });
            }
        }
    }
};

pub const Builtin = enum {
    debug,
    @"+",
    @"-",

    pub fn compile(b: Builtin, ctx: *Context) Allocator.Error!void {
        switch (b) {
            .debug => {
                try ctx.call(&Stack.debug);
            },
            inline .@"+", .@"-" => |ct_b| {
                const op_tag: x86.Op.Tag = switch (ct_b) {
                    .@"+" => .add,
                    .@"-" => .sub,
                    else => unreachable,
                };

                try ctx.popMany(&.{.rdx, .rax});
                try ctx.op(@unionInit(x86.Op, @tagName(op_tag), .{
                    .dst = .{ .reg = .rax },
                    .src = .{ .reg = .rdx },
                }));
                try ctx.push(.{ .reg = .rax });
            },
        }
    }
};

/// the value stack
pub const Stack = struct {
    const Self = @This();

    const ally = std.heap.page_allocator;

    values: std.ArrayListUnmanaged(u64) = .{},

    inline fn rbx() *Self {
        return asm("" : [ret] "={rbx}" (-> *Self));
    }

    fn init() callconv(.SysV) void {
        const self = rbx();
        self.* = Self{};
    }

    fn deinit() callconv(.SysV) void {
        const self = rbx();
        self.values.deinit(ally);
    }

    /// pushes rdi
    fn push(value: u64) callconv(.SysV) void {
        const self = rbx();
        self.values.append(ally, value) catch @panic("OOM");
    }

    /// pops into rax
    fn pop() callconv(.SysV) u64 {
        const self = rbx();
        return self.values.pop();
    }

    /// prints stack to stderr for debugging
    fn debug() callconv(.SysV) void {
        const self = rbx();

        std.debug.print("[stack]\n", .{});
        for (self.values.items) |x| {
            std.debug.print("{x:0>16} ({d})\n", .{x, x});
        }
    }
};

/// 1. do sysv function prelude
/// 2. save rbx
/// 3. create and init value stack which sits permanently in rbx. in sysv this
///    register is preserved by the callee which makes asm/zig/c interop easy.
pub const compiled_prelude = [_]x86.Op{
    // sysv prelude
    .{ .push = .{ .reg = .rbp } },
    .{
        .mov = .{
            .src = .{ .reg = .rsp },
            .dst = .{ .reg = .rbp },
        },
    },

    // save rbx
    .{ .push = .{ .reg = .rbx } },

    // create value stack
    .{
        .mov = .{
            .src = .{ .imm = .{ .uint = @sizeOf(Stack) } },
            .dst = .{ .reg = .rax },
        },
    },
    .{
        .sub = .{
            .src = .{ .reg = .rax },
            .dst = .{ .reg = .rsp },
        },
    },
    .{
        .mov = .{
            .src = .{ .reg = .rsp },
            .dst = .{ .reg = .rbx },
        },
    },

    // init value stack
    .{
        .mov = .{
            .src = .{ .imm = .{ .ptr = &Stack.init } },
            .dst = .{ .reg = .rax },
        },
    },
    .{ .call = .{ .reg = .rax } },
};

/// 1. deinit and destroy value stack
/// 2. restore rbx
/// 3. do sysv function epilog
pub const compiled_epilog = [_]x86.Op{
    // deinit value stack
    .{
        .mov = .{
            .src = .{ .imm = .{ .ptr = &Stack.deinit } },
            .dst = .{ .reg = .rax },
        },
    },
    .{ .call = .{ .reg = .rax } },

    // destroy value stack
    .{
        .mov = .{
            .src = .{ .imm = .{ .uint = @sizeOf(Stack) } },
            .dst = .{ .reg = .rax },
        },
    },
    .{
        .add = .{
            .src = .{ .reg = .rax },
            .dst = .{ .reg = .rsp },
        },
    },

    // restore rbx
    .{ .pop = .{ .reg = .rbx } },

    // sysv epilog
    .{ .pop = .{ .reg = .rbp } },
    .ret,
};
