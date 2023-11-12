const std = @import("std");
const com = @import("common");
const Codepoint = com.utf8.Codepoint;

const logger = std.log.scoped(.lexer);

const LexError = error{InvalidInput};
pub const Error =
    Codepoint.ParseError ||
    LexError;

pub const Token = struct {
    const Self = @This();

    pub const Tag = enum {
        word,
        int,
        real,
    };

    tag: Tag,
    start: usize,
    stop: usize,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        try writer.print(
            "<{d}:{d} {s}>",
            .{ self.start, self.stop, @tagName(self.tag) },
        );
    }
};

const Lexer = @This();

const CodepointCache = com.BoundedRingBuffer(Codepoint, 8);
const TokenCache = com.BoundedRingBuffer(Token, 8);

iter: Codepoint.Iterator,
cache: TokenCache = .{},

pub fn init(text: []const u8) Lexer {
    return Lexer{ .iter = Codepoint.parse(text) };
}

pub fn slice(self: Lexer, tok: Token) []const u8 {
    return self.iter.text[tok.start..tok.stop];
}

// wrapped codepoint iterator ==================================================

fn index(self: Lexer) u32 {
    return @intCast(self.iter.byte_index);
}

fn peekC(self: *Lexer) Error!?Codepoint {
    return self.iter.peek();
}

fn acceptC(self: *Lexer, c: Codepoint) void {
    self.iter.accept(c);
}

fn peekSlice(self: *Lexer, buf: []Codepoint, n: usize) Error![]const Codepoint {
    return try self.iter.peekSlice(buf, n);
}

fn acceptSlice(self: *Lexer, str: []const Codepoint) void {
    for (str) |c| self.acceptC(c);
}

// codepoint classification ====================================================

fn isWord(c: Codepoint) bool {
    return !c.isSpace() and switch (c.getUnicodeBlock()) {
        .BasicLatin,
        .Latin1Supplement,
        => true,
        else => false,
    };
}

fn isDecimal(c: Codepoint) bool {
    return c.isDigit(10);
}

// tokenization ================================================================

fn skipSpaces(self: *Lexer) Error!void {
    while (try self.peekC()) |pk| {
        if (!pk.isSpace()) return;
        self.acceptC(pk);
    }
}

/// iterate to find the next token
fn lex(self: *Lexer) Error!?Token {
    try self.skipSpaces();

    const start_index = self.index();
    const start_ch = try self.peekC() orelse return null;

    const tag: Token.Tag = if (isDecimal(start_ch)) tok: {
        self.acceptC(start_ch);

        // integral
        while (try self.peekC()) |inner_ch| {
            if (!isDecimal(inner_ch)) break;
            self.acceptC(inner_ch);
        }

        const dot_ch = try self.peekC() orelse {
            break :tok .int;
        };
        if (dot_ch.c != '.') break :tok .int;
        self.acceptC(dot_ch);

        // fractional
        while (try self.peekC()) |inner_ch| {
            if (!isDecimal(inner_ch)) break;
            self.acceptC(inner_ch);
        }

        break :tok .real;
    } else if (isWord(start_ch)) tok: {
        // words
        self.acceptC(start_ch);
        while (try self.peekC()) |inner_ch| {
            if (!isWord(inner_ch)) break;
            self.acceptC(inner_ch);
        }

        break :tok .word;
    } else {
        std.debug.print("invalid input: `{}`\n", .{start_ch});
        return Error.InvalidInput;
    };

    const stop_index = self.index();

    const token = Token{
        .tag = tag,
        .start = start_index,
        .stop = stop_index,
    };

    return token;
}

/// fill cache with the next `count` tokens
/// fails if there aren't enough tokens; returns success
fn cacheTokens(self: *Lexer, count: usize) Error!bool {
    std.debug.assert(count <= TokenCache.cache_len);

    return while (self.cache.len < count) {
        const token = try self.lex() orelse {
            break false;
        };

        self.cache.push(token);
    } else true;
}

pub fn next(self: *Lexer) Error!?Token {
    const token = try self.peek() orelse {
        return null;
    };

    self.cache.advance();

    return token;
}

pub fn peek(self: *Lexer) Error!?Token {
    return self.peekIndex(0);
}

pub fn peekIndex(self: *Lexer, n: usize) Error!?Token {
    if (!try self.cacheTokens(n + 1)) {
        return null;
    }

    return self.cache.get(n);
}

pub fn accept(self: *Lexer, token: Token) void {
    std.debug.assert(std.meta.eql(token, self.cache.get(0)));
    self.cache.advance();
}
