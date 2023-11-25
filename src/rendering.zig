const std = @import("std");
const Allocator = std.mem.Allocator;
const blox = @import("blox");
const Mason = blox.Mason;
const Div = blox.Div;
const Jit = @import("Jit.zig");

pub const Error = blox.Error;

const theme = struct {
    const c = blox.Color.init;
    const register = c(.normal, .green);
    const label = c(.normal, .cyan);
    const opcode = c(.normal, .red);
    const data = c(.normal, .magenta);
};

const span = blox.BoxOptions{ .direction = .right };

fn renderRegister(mason: *Mason, reg: Jit.Register) Error!Div {
    const str = try std.fmt.allocPrint(mason.ally, "%{s}", .{@tagName(reg)});
    defer mason.ally.free(str);
    return try mason.newPre(str, .{ .fg = theme.register });
}

fn renderLabel(mason: *Mason, label: Jit.Label) Error!Div {
    const str = try std.fmt.allocPrint(mason.ally, "{@}", .{label});
    defer mason.ally.free(str);
    return try mason.newPre(str, .{ .fg = theme.label });
}

pub fn renderOp(op: Jit.Op, mason: *Mason) Error!Div {
    const comma = try mason.newPre(", ", .{});
    const space = try mason.newSpacer(1, 1, .{});

    const ally = mason.ally;
    var divs = std.ArrayList(Div).init(ally);
    defer divs.deinit();

    const code_str = try std.fmt.allocPrint(ally, "{s} ", .{@tagName(op)});
    defer ally.free(code_str);

    const code = try mason.newPre(code_str, .{ .fg = theme.opcode });
    try divs.append(code);

    switch (op) {
        inline else => |data| switch (@TypeOf(data)) {
            void => {},
            u31 => {
                const str = try std.fmt.allocPrint(ally, "${d}", .{data});
                defer ally.free(str);

                try divs.append(try mason.newPre(str, .{ .fg = theme.data }));
            },
            Jit.Label => try divs.append(try renderLabel(mason, data)),
            Jit.Register => try divs.append(try renderRegister(mason, data)),

            Jit.Op.Constant => {
                std.debug.assert(data.bytes.len == 8);

                const byte_ptr: *const [8]u8 = @ptrCast(data.bytes.ptr);
                const n = std.mem.bytesToValue(u64, byte_ptr);
                const str = try std.fmt.allocPrint(ally, "$0x{x}", .{n});
                defer ally.free(str);

                try divs.appendSlice(&.{
                    try mason.newPre(str, .{ .fg = theme.data }),
                    comma,
                    try renderRegister(mason, data.dst),
                });
            },
            Jit.Op.Binary => {
                try divs.appendSlice(&.{
                    try renderRegister(mason, data.src),
                    comma,
                    try renderRegister(mason, data.dst),
                });
            },
            Jit.Op.Cmp => {
                try divs.appendSlice(&.{
                    try renderRegister(mason, data.lhs),
                    comma,
                    try renderRegister(mason, data.rhs),
                });
            },
            Jit.Op.JumpIf => {
                const cond_tag = @tagName(data.cond);

                try divs.appendSlice(&.{
                    try mason.newPre(cond_tag, .{ .fg = theme.opcode }),
                    space,
                    try renderLabel(mason, data.label),
                });
            },
            Jit.Op.Mem => {
                const size_tag = @tagName(data.size);

                try divs.appendSlice(&.{
                    try mason.newPre(size_tag, .{ .fg = theme.opcode }),
                    space,
                    try renderRegister(mason, data.src),
                    comma,
                    try renderRegister(mason, data.dst),
                });
            },
            Jit.Op.StackLoad => {
                const size_tag = @tagName(data.size);
                const offset_str =
                    try std.fmt.allocPrint(ally, "from {d} to", .{data.offset});
                defer ally.free(offset_str);

                try divs.appendSlice(&.{
                    try mason.newPre(size_tag, .{ .fg = theme.opcode }),
                    space,
                    try mason.newPre(offset_str, .{}),
                    space,
                    try renderRegister(mason, data.dst),
                });
            },
            Jit.Op.StackStore => {
                const size_tag = @tagName(data.size);
                const offset_str =
                    try std.fmt.allocPrint(ally, "to {d} from", .{data.offset});
                defer ally.free(offset_str);

                try divs.appendSlice(&.{
                    try mason.newPre(size_tag, .{ .fg = theme.opcode }),
                    space,
                    try mason.newPre(offset_str, .{}),
                    space,
                    try renderRegister(mason, data.src),
                });
            },

            else => |T| @panic("unknown op data type: " ++ @typeName(T)),
        }
    }

    return try mason.newBox(divs.items, span);
}

pub fn renderBlock(bb: *const Jit.BlockBuilder, mason: *Mason) Error!Div {
    var op_divs = std.ArrayList(Div).init(mason.ally);
    defer op_divs.deinit();

    for (bb.ops.items) |op| {
        try op_divs.append(try op.render(mason));
    }

    return try mason.newBox(&.{
        try renderLabel(mason, bb.label),
        try mason.newBox(&.{
            try mason.newSpacer(2, 0, .{}),
            try mason.newBox(op_divs.items, .{}),
        }, span),
    }, .{});
}

pub fn renderBuilder(b: *const Jit.Builder, mason: *Mason) Error!Div {
    var block_divs = std.ArrayList(Div).init(mason.ally);
    defer block_divs.deinit();

    var blocks = b.block_builders.valueIterator();
    while (blocks.next()) |bb| {
        try block_divs.append(try bb.*.render(mason));
    }

    return try mason.newBox(block_divs.items, .{});
}