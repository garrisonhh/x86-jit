const std = @import("std");
const Allocator = std.mem.Allocator;
const com = @import("common");
const JitMemory = @import("JitMemory.zig");
const x86 = @import("x86.zig");

const Jit = @This();

pub const LinkError = error { LabelNotFound };
pub const BuildError = Allocator.Error || LinkError;

pub const Register = x86.Register;
pub const Label = com.Ref(.jit_label, 64);

pub const Op = union(enum) {
    const max_encoded_len = 15;

    pub const Constant = struct {
        value: u64,
        dst: Register,
    };

    pub const Binary = struct {
        src: Register,
        dst: Register,
    };

    pub const Cmp = struct {
        lhs: Register,
        rhs: Register,
    };

    pub const Condition = enum(u4) {
        z,
        nz,
        eq,
        ne,
        gt,
        lt,
        ge,
        le,

        /// numbers are associated with Jcc instruction opcodes, you can use
        /// these in the opcode_reg encoded field with 0x70 opcode for short
        /// jump and 0x0F80 opcode for long jump
        fn code(cond: Condition) u4 {
            return switch (cond) {
                .z, .eq => 0x4,
                .nz, .ne => 0x5,
                .gt => 0xF,
                .lt => 0xC,
                .ge => 0xD,
                .le => 0xE,
            };
        }

        fn inverse(cond: Condition) Condition {
            return switch (cond) {
                .z => .nz,
                .nz => .z,
                .eq => .ne,
                .ne => .eq,
                .gt => .le,
                .lt => .ge,
                .le => .gt,
                .ge => .lt,
            };
        }
    };

    pub const JumpIf = struct {
        cond: Condition,
        label: Label,
    };

    nop,

    // control flow
    /// enter stack frame and reserve provided stack size
    enter: u32,
    /// leave stack frame
    leave,
    ret,
    syscall,
    /// clobbers rax
    call: Label,
    /// clobbers rax
    jump: Label,
    cmp: Cmp,
    /// uses flags set by cmp or other instructions to determine whether to jump
    /// clobbers rax
    jump_if: JumpIf,

    // value twiddling
    constant: Constant,
    push: Register,
    pop: Register,
    mov: Binary,

    // logic/math
    add: Binary,
    sub: Binary,

    /// emits bytecode and linkable symbols for this op
    fn compile(op: Op, e: *Encoder) Allocator.Error!void {
        switch (op) {
            .nop => try e.encode(.{ .opcode = &.{0x90} }),

            .enter => |frame_size| {
                try compile(.{ .push = .rbp }, e);
                try compile(.{ .mov = .{ .src = .rsp, .dst = .rbp } }, e);

                if (frame_size > 0) {
                    // sub $frame_size, %rsp
                    try e.encode(.{
                        .prefix = x86.Prefix.REX_W,
                        .opcode = &.{0x81},
                        .modrm = x86.ModRm{
                            .mod = 0b11,
                            .reg_opcode = 5,
                            .rm = @intFromEnum(Register.rsp),
                        },
                        .immediate = std.mem.asBytes(&frame_size),
                    });
                }
            },
            .leave => try e.encode(.{ .opcode = &.{0xC9} }),
            .ret => try e.encode(.{ .opcode = &.{0xC3} }),
            .syscall => try e.encode(.{ .opcode = &.{0x0F, 0x05} }),
            .call => |label| {
                const reg: Register = .rax;
                try e.movLabel(reg, label);
                try e.encode(.{
                    .opcode = &.{0xFF},
                    .modrm = x86.ModRm{
                        .mod = 0b11,
                        .reg_opcode = 2,
                        .rm = @intFromEnum(reg),
                    },
                });
            },
            .jump => |label| {
                const reg: Register = .rax;
                try e.movLabel(reg, label);
                try e.encode(.{
                    .opcode = &.{0xFF},
                    .modrm = x86.ModRm{
                        .mod = 0b11,
                        .reg_opcode = 4,
                        .rm = @intFromEnum(reg),
                    },
                });
            },
            .cmp => |cmp| try e.encode(.{
                .prefix = x86.Prefix.REX_W,
                .opcode = &.{0x3B},
                .modrm = x86.ModRm{
                    .mod = 0b11,
                    .reg_opcode = @intFromEnum(cmp.lhs),
                    .rm = @intFromEnum(cmp.rhs),
                },
            }),
            .jump_if => |jump_if| {
                // rel8 size of absolute jump instruction (movabs + jump)
                const offset: i8 = 12;
                // short conditional jump over $offset if inverse of condition
                // is true
                const cond_code: u8 = jump_if.cond.inverse().code();
                try e.encode(.{
                    .opcode = &.{0x70 + cond_code},
                    .immediate = std.mem.asBytes(&offset),
                });
                try compile(.{ .jump = jump_if.label }, e);
            },

            .constant => |constant| {
                try e.encode(.{
                    .prefix = x86.Prefix.REX_W,
                    .opcode = &.{0xB8},
                    .opcode_reg = constant.dst,
                    .immediate = std.mem.asBytes(&constant.value),
                });
            },
            .push => |reg| try e.encode(.{
                .opcode = &.{0x50},
                .opcode_reg = reg,
            }),
            .pop => |reg| try e.encode(.{
                .opcode = &.{0x58},
                .opcode_reg = reg,
            }),
            .mov => |mov| try e.encode(.{
                .prefix = x86.Prefix.REX_W,
                .opcode = &.{0x89},
                .modrm = x86.ModRm{
                    .mod = 0b11,
                    .reg_opcode = @intFromEnum(mov.src),
                    .rm = @intFromEnum(mov.dst),
                },
            }),

            inline .add, .sub => |bin, opcode| try e.encode(.{
                .prefix = x86.Prefix.REX_W,
                .opcode = switch (opcode) {
                    .add => &.{0x03},
                    .sub => &.{0x2B},
                    else => unreachable,
                },
                .modrm = x86.ModRm{
                    .mod = 0b11,
                    .reg_opcode = @intFromEnum(bin.dst),
                    .rm = @intFromEnum(bin.src),
                },
            }),
        }
    }
};

/// encodes ops into an object
const Encoder = struct {
    jit: *Jit,
    code: std.ArrayListUnmanaged(u8) = .{},
    symbols: std.ArrayListUnmanaged(Object.Symbol) = .{},

    fn deinit(self: *Encoder) void {
        const ally = self.jit.ally;
        self.code.deinit(ally);
        self.symbols.deinit(ally);
    }

    /// add a raw encoded op
    fn encode(self: *Encoder, encoded: x86.Encoded) Allocator.Error!void {
        var buf: [Op.max_encoded_len]u8 = undefined;
        const code = encoded.write(&buf);

        try self.code.appendSlice(self.jit.ally, code);
    }

    /// encode moving a label to a register by storing the label as a symbol
    /// to be linked in the future
    fn movLabel(
        self: *Encoder,
        reg: Register,
        label: Label,
    ) Allocator.Error!void {
        const placeholder: [8]u8 = undefined;
        try self.encode(.{
            .prefix = x86.Prefix.REX_W,
            .opcode = &.{0xB8},
            .opcode_reg = reg,
            .immediate = &placeholder,
        });

        // immediate bytes are added at the end
        const symbol_index = self.code.items.len - placeholder.len;
        try self.symbols.append(self.jit.ally, Object.Symbol{
            .label = label,
            .index = symbol_index,
        });
    }

    fn build(self: *Encoder) Allocator.Error!Object {
        return Object.init(
            self.jit,
            try self.symbols.toOwnedSlice(self.jit.ally),
            try self.code.toOwnedSlice(self.jit.ally),
        );
    }
};

/// a block of compiled but unlinked code
const Object = struct {
    /// index points to 4 bytes in `code` which must be replaced with the actual
    /// address of the label
    const Symbol = struct {
        label: Label,
        index: usize,
    };

    jit: *Jit,
    /// symbols needed for linking
    symbols: []const Symbol,
    /// unlinked code
    code: []u8,
    /// actual executable memory (must be allocated on init for linking)
    executable: []u8,

    /// takes ownership of symbols and code
    fn init(
        jit: *Jit,
        symbols: []const Symbol,
        code: []u8,
    ) Allocator.Error!Object {
        const executable = try jit.memory.alloc(
            jit.ally,
            @alignOf(@TypeOf(code)),
            code.len,
        );

        return Object{
            .jit = jit,
            .symbols = symbols,
            .code = code,
            .executable = executable,
        };
    }

    fn deinit(self: *Object) void {
        const ally = self.jit.ally;
        ally.free(self.symbols);
        ally.free(self.code);
    }

    const LinkMap = std.AutoHashMapUnmanaged(Label, Object);

    /// find address of label
    fn findLabel(
        jit: *const Jit,
        map: *const LinkMap,
        label: Label,
    ) LinkError!*const anyopaque {
        if (jit.functions.get(label)) |func| {
            return func.mem.ptr;
        }

        if (map.get(label)) |object| {
            return object.executable.ptr;
        }

        return LinkError.LabelNotFound;
    }

    fn linkSymbol(
        self: *Object,
        map: *const LinkMap,
        symbol: Symbol,
    ) LinkError!void {
        const symbol_ptr = try findLabel(self.jit, map, symbol.label);
        const symbol_bytes: *const [8]u8 = @ptrCast(&symbol_ptr);
        @memcpy(self.code[symbol.index..symbol.index + 8], symbol_bytes);
    }

    fn link(self: *Object, map: *const LinkMap) LinkError!Function {
        for (self.symbols) |symbol| {
            try self.linkSymbol(map, symbol);
        }

        JitMemory.copy(self.executable, self.code);

        return Function{ .mem = self.executable };
    }
};

/// builder for a jit block
pub const BlockBuilder = struct {
    jit: *Jit,
    label: Label,
    ops: std.ArrayListUnmanaged(Op) = .{},

    fn deinit(self: *BlockBuilder) void {
        self.ops.deinit(self.jit.ally);
    }

    fn compile(self: *BlockBuilder) Allocator.Error!Object {
        var encoder = Encoder{ .jit = self.jit };
        defer encoder.deinit();

        for (self.ops.items) |o| try o.compile(&encoder);

        return try encoder.build();
    }

    pub fn op(self: *BlockBuilder, o: Op) Allocator.Error!void {
        try self.ops.append(self.jit.ally, o);
    }

    /// preserve stack for sysv function
    pub fn enterSysV(self: *BlockBuilder) Allocator.Error!void {
        try self.op(.{ .push = .rbp });
        try self.op(.{ .mov = .{ .src = .rsp, .dst = .rbp } });
    }

    /// restore stack and return from sysv function
    pub fn exitSysV(self: *BlockBuilder) Allocator.Error!void {
        try self.op(.{ .pop = .rbp });
        try self.op(.ret);
    }
};

pub const Builder = struct {
    jit: *Jit,
    block_builders: com.RefList(Label, BlockBuilder) = .{},

    pub fn deinit(self: *Builder) void {
        var bbuilders = self.block_builders.iterator();
        while (bbuilders.next()) |bbuilder| bbuilder.deinit();
        self.block_builders.deinit(self.jit.ally);
    }

    pub fn block(self: *Builder) Allocator.Error!*BlockBuilder {
        const label = try self.block_builders.new(self.jit.ally);
        self.block_builders.set(label, BlockBuilder{
            .jit = self.jit,
            .label = label,
        });

        return self.block_builders.get(label);
    }

    /// compile and link all of the blocks, and then add them to the jit
    pub fn build(self: *Builder) BuildError!void {
        const ally = self.jit.ally;

        // compile blocks to objects
        var objects = Object.LinkMap{};
        defer {
            var object_iter = objects.valueIterator();
            while (object_iter.next()) |object| object.deinit();
            objects.deinit(ally);
        }

        var bbuilders = self.block_builders.iterator();
        while (bbuilders.next()) |bbuilder| {
            const object = try bbuilder.compile();
            try objects.put(ally, bbuilder.label, object);
        }

        // link objects and add to jit
        var object_iter = objects.iterator();
        while (object_iter.next()) |entry| {
            const func = try entry.value_ptr.link(&objects);
            try self.jit.functions.put(ally, entry.key_ptr.*, func);
        }
    }
};

/// fully jit compiled result
pub const Function = struct {
    const Map = std.AutoHashMapUnmanaged(Label, Function);

    mem: []const u8,
};

ally: Allocator,
memory: JitMemory = .{},
functions: Function.Map = .{},

pub fn init(ally: Allocator) Jit {
    return Jit{ .ally = ally };
}

pub fn deinit(self: *Jit) void {
    self.functions.deinit(self.ally);
    self.memory.deinit(self.ally);
}

/// start building a set of potentially linked functions
///
/// you can use multiple builders in sequence, but two builder instances at once
/// will not be able to see each others blocks
pub fn builder(self: *Jit) Builder {
    return .{ .jit = self };
}

/// retrieve a compiled function
pub fn get(self: *const Jit, label: Label, comptime T: type) *const T {
    std.debug.assert(@typeInfo(T) == .Fn);
    const func = self.functions.get(label) orelse {
        std.debug.panic(
            "{} is not the label of a compiled jit function.",
            .{label},
        );
    };
    return @ptrCast(func.mem.ptr);
}