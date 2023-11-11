//! encodes a limited subset of x86

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const in_debug = builtin.mode == .Debug;

// helpers =====================================================================

/// internally used for byte serialization
const ByteBuffer = struct {
    const Self = @This();

    buffer: []u8,
    index: usize,

    fn init(buffer: []u8) Self {
        return Self{
            .buffer = buffer,
            .index = 0,
        };
    }

    fn write(self: *Self, byte: u8) void {
        if (in_debug and self.index == self.buffer.len) {
            @panic("overflowed buffer");
        }

        self.buffer[self.index] = byte;
        self.index += 1;
    }

    fn writeSlice(self: *Self, src: []const u8) void {
        if (in_debug and self.index + src.len > self.buffer.len) {
            @panic("overflowed buffer");
        }

        const dst = self.buffer[self.index..self.index + src.len];
        // @memcpy seems to be bugged here
        std.mem.copyForwards(u8, dst, src);
        self.index += src.len;
    }

    fn slice(self: Self) []const u8 {
        return self.buffer[0..self.index];
    }
};

// bit smashing ================================================================

// manual figure 2.1 is super helpful for this, as well as section 3.1

const Rex = packed struct(u4) {
    b: u1 = 0,
    x: u1 = 0,
    r: u1 = 0,
    w: u1 = 0,

    fn byte(rex: Rex) u8 {
        return 0b0100_0000 | @as(u8, @as(u4, @bitCast(rex)));
    }
};

const ModRm = packed struct(u8) {
    rm: u3,
    reg_opcode: u3,
    mod: u2,
};

const Sib = packed struct(u8) {
    base: u3,
    index: u3,
    scaled: u2,
};

const Prefix = union(enum) {
    const REX_W = Prefix{ .rex = Rex{ .w = 1 } };

    rex: Rex,
};

const Encoded = struct {
    const Self = @This();

    prefix: ?Prefix = null,
    opcode: []const u8,
    opcode_reg: ?Register = null,
    modrm: ?ModRm = null,
    sib: ?Sib = null,
    /// 0, 1, 2, 4, or 8 byte address displacement
    displacement: []const u8 = &.{},
    immediate: ?Immediate = null,

    fn immediateBytes(imm: Immediate) [8]u8 {
        switch (imm) {
            inline else => |*data| {
                var buf: [8]u8 = undefined;
                @memcpy(&buf, @as(*const [8] u8, @ptrCast(data)));
                return buf;
            },
        }
    }

    fn write(self: Self, buf: []u8) []const u8 {
        var bb = ByteBuffer.init(buf);

        if (self.prefix) |prefix| {
            switch (prefix) {
                .rex => |rex| bb.write(rex.byte()),
            }
        }

        std.debug.assert(self.opcode.len > 0);
        if (self.opcode_reg) |reg| {
            bb.writeSlice(self.opcode[0..self.opcode.len - 1]);

            const last_opcode_byte = self.opcode[self.opcode.len - 1];
            const last_byte = last_opcode_byte + @intFromEnum(reg);
            bb.write(last_byte);
        } else {
            bb.writeSlice(self.opcode);
        }

        if (self.modrm) |modrm| bb.write(@bitCast(modrm));
        if (self.sib) |sib| bb.write(@bitCast(sib));

        bb.writeSlice(self.displacement);

        if (self.immediate) |imm| {
            bb.writeSlice(&immediateBytes(imm));
        }

        return bb.slice();
    }
};

// interface ===================================================================

/// maximum possible encoding bytes
pub const MAX_OP_BYTES = 15;

pub const Register = enum(u3) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
};

pub const Immediate = union(enum) {
    sint: i64,
    uint: u64,
    ptr: *const anyopaque,
};

pub const Deref = struct {
    reg: Register,
    offset: u64,
};

pub const RRmArg = union(enum) {
    reg: Register,
    deref: Deref,
};

pub const RRmIArg = union(enum) {
    reg: Register,
    deref: Deref,
    imm: Immediate,
};

pub const RRmIOArg = union(enum) {
    reg: Register,
    deref: Deref,
    imm: Immediate,
    offset: u64,
};

pub const Op = union(enum) {
    const Self = @This();

    pub const Mov = struct {
        src: RRmIOArg,
        dst: RRmIOArg,
    };

    nop,
    ret,
    syscall,

    push: RRmIArg,
    pop: RRmArg,

    mov: Mov,

    pub const EncodingError = error { InvalidOp };
    const invalidOp = EncodingError.InvalidOp;

    fn encode(self: Self) EncodingError!Encoded {
        return switch (self) {
            .nop => Encoded{ .opcode = &.{0x90} },
            .ret => Encoded{ .opcode = &.{0xC3} },
            .syscall => Encoded{ .opcode = &.{0x0F, 0x05} },

            .push => |arg| switch (arg) {
                .imm => |imm| Encoded{
                    .opcode = &.{0x68},
                    .immediate = imm,
                },
                .reg => |reg| Encoded{
                    .opcode = &.{0x50},
                    .opcode_reg = reg,
                },
                .deref => @panic("TODO"),
            },
            .pop => |arg| switch (arg) {
                .reg => |reg| Encoded{
                    .opcode = &.{0x58},
                    .opcode_reg = reg,
                },
                .deref => @panic("TODO"),
            },

            .mov => |mov| switch (mov.dst) {
                .imm => invalidOp,
                .reg => |reg| switch (mov.src) {
                    .imm => |imm| Encoded{
                        .prefix = Prefix.REX_W,
                        .opcode = &.{0xB8},
                        .opcode_reg = reg,
                        .immediate = imm,
                    },
                    .reg => |src_reg| Encoded{
                        .prefix = Prefix.REX_W,
                        .opcode = &.{0x89},
                        .modrm = ModRm{
                            .mod = 0b11,
                            .reg_opcode = @intFromEnum(src_reg),
                            .rm = @intFromEnum(reg),
                        },
                    },
                    else => @panic("TODO"),
                },
                else => @panic("TODO"),
            },
        };
    }

    /// write encoded opcode bytes to buffer
    pub fn write(
        self: Self,
        buffer: *[MAX_OP_BYTES]u8,
    ) EncodingError![]const u8 {
        const encoded = try self.encode();
        return encoded.write(buffer);
    }
};

// function assembling =========================================================

pub const AssembleError =
    Allocator.Error || std.os.MProtectError || Op.EncodingError;

pub fn Assembled(comptime T: type) type {
    const info = @typeInfo(T);
    std.debug.assert(info == .Fn);
    std.debug.assert(info.Fn.calling_convention == .SysV);

    return struct {
        const Self = @This();
        const Slice = []align(std.mem.page_size) u8;

        /// NOTE reading/writing from/to this memory is a segfault
        mem: Slice,

        // call mprotect on each page of the slice
        fn setProtection(
            slice: Slice,
            protection: u32,
        ) std.os.MProtectError!void {
            var offset: usize = 0;
            while (offset < slice.len) : (offset += std.mem.page_size) {
                const stop = @min(offset + std.mem.page_size, slice.len);
                const window: Slice = @alignCast(slice[offset..stop]);
                try std.os.mprotect(window, protection);
            }
        }

        /// make mem executable for wrapping
        /// (bytecode ownership is moved)
        fn from(ally: Allocator, bytecode: Slice) AssembleError!Self {
            var mem = bytecode;

            // TODO there should probably be some kind of jit page allocator
            // instead of doing this hacky alignment and mprotect over a
            // std.mem.Allocator. I should definitely be acquiring memory from
            // the os directly
            const aligned_len =
                std.mem.alignForward(usize, mem.len, std.mem.page_size);
            if (aligned_len != mem.len) {
                mem = try ally.realloc(mem, aligned_len);
            }

            try setProtection(mem, std.os.linux.PROT.EXEC);
            return Self{ .mem = mem };
        }

        pub fn deinit(self: Self, ally: Allocator) void {
            const prot = std.os.linux.PROT.READ | std.os.linux.PROT.WRITE;
            if (setProtection(self.mem, prot)) {
                ally.free(self.mem);
            } else |_| {
                // ignore error
            }
        }

        pub fn func(self: Self) *const T {
            return @ptrCast(self.mem.ptr);
        }
    };
}

/// assemble ops to executable machine code
pub fn assemble(
    comptime T: type,
    ally: Allocator,
    ops: []const Op,
) AssembleError!Assembled(T) {
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(ally);
    errdefer code.deinit();

    for (ops) |op| {
        var buf: [MAX_OP_BYTES]u8 = undefined;
        const op_bytecode = try op.write(&buf);
        try code.appendSlice(op_bytecode);
    }

    return try Assembled(T).from(ally, try code.toOwnedSlice());
}