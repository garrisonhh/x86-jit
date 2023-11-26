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
        @memcpy(dst, src);
        self.index += src.len;
    }

    fn slice(self: Self) []const u8 {
        return self.buffer[0..self.index];
    }
};

// bit smashing ================================================================

// manual figure 2.1 is super helpful for this, as well as section 3.1

pub const Rex = packed struct(u4) {
    b: u1 = 0,
    x: u1 = 0,
    r: u1 = 0,
    w: u1 = 0,

    fn byte(rex: Rex) u8 {
        return 0b0100_0000 | @as(u8, @as(u4, @bitCast(rex)));
    }
};

pub const Prefix = union(enum) {
    pub const REX_W = Prefix{ .rex = Rex{ .w = 1 } };

    rex: Rex,
    override16bit,
};

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

pub const ModRm = packed struct(u8) {
    rm: u3,
    reg_opcode: u3,
    mod: u2,
};

pub const Sib = packed struct(u8) {
    base: u3,
    index: u3,
    scaled: u2,
};

pub const Encoded = struct {
    const Self = @This();

    prefix: ?Prefix = null,
    opcode: []const u8,
    opcode_reg: ?Register = null,
    modrm: ?ModRm = null,
    sib: ?Sib = null,
    /// 0, 1, 2, 4, or 8 byte address displacement
    displacement: []const u8 = &.{},
    /// 0, 1, 2, 4, or 8 byte value
    immediate: []const u8 = &.{},

    pub fn write(self: Self, buf: []u8) []const u8 {
        var bb = ByteBuffer.init(buf);

        if (self.prefix) |prefix| {
            switch (prefix) {
                .rex => |rex| bb.write(rex.byte()),
                .override16bit => bb.write(0x66),
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
        bb.writeSlice(self.immediate);

        return bb.slice();
    }
};
