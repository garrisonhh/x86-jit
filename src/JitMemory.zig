//! specialized bump allocator for jit functions

const std = @import("std");
const Allocator = std.mem.Allocator;
const page_size = std.mem.page_size;
const os = std.os;

const Protection = enum { rw, exec };

fn mprotect(
    slice: []align(page_size) u8,
    protection: Protection,
) void {
    os.mprotect(slice, switch (protection) {
        .rw => os.PROT.READ | os.PROT.WRITE,
        .exec => os.PROT.READ | os.PROT.EXEC,
    }) catch {
        // having read the manpage, I'm about 99% sure that these errors
        // won't occur for my program as long as I'm using a zig allocator
        unreachable;
    };
}

const Self = @This();

const Page = struct {
    /// minimum bytes remaining for this page to be considered 'open'
    const MIN_BYTES = 32;

    mem: []align(page_size) u8,
    bump: usize,

    fn new(ally: Allocator, nbytes: usize) Allocator.Error!Page {
        std.debug.assert(nbytes % page_size == 0);
        const mem = try ally.alignedAlloc(u8, page_size, nbytes);
        mprotect(mem, .exec);

        return Page{
            .mem = mem,
            .bump = 0,
        };
    }

    fn free(self: Page, ally: Allocator) void {
        mprotect(self.mem, .rw);
        ally.free(self.mem);
    }

    fn alloc(self: *Page, comptime aln: u29, size: usize) ?[]align(aln) u8 {
        if (self.available() < size) return null;

        const start = std.mem.alignForward(usize, self.bump, aln);
        self.bump = start + size;

        return @alignCast(self.mem[start..self.bump]);
    }

    fn available(self: Page) usize {
        return self.mem.len - self.bump;
    }

    fn isOpen(self: Page) bool {
        return self.available() >= MIN_BYTES;
    }
};

open: std.ArrayListUnmanaged(Page) = .{},
closed: std.ArrayListUnmanaged(Page) = .{},

pub fn deinit(self: *Self, ally: Allocator) void {
    for (self.open.items) |*page| page.free(ally);
    for (self.closed.items) |*page| page.free(ally);
    self.open.deinit(ally);
    self.closed.deinit(ally);
}

/// ensures open pages are sorted from least to most memory available
fn insertOpenPage(
    self: *Self,
    ally: Allocator,
    page: Page,
) Allocator.Error!void {
    const lessThan = struct {
        fn lessThan(_: void, a: Page, b: Page) bool {
            return a.available() < b.available();
        }
    }.lessThan;

    try self.open.append(ally, page);
    std.sort.insertion(Page, self.open.items, {}, lessThan);
}

fn allocFromNewPage(
    self: *Self,
    ally: Allocator,
    comptime aln: u29,
    size: usize,
) Allocator.Error![]align(aln) u8 {
    const nbytes = std.mem.alignForward(usize, size, page_size);
    var page = try Page.new(ally, nbytes);
    const mem = page.alloc(aln, size).?;

    if (page.isOpen()) {
        try self.insertOpenPage(ally, page);
    } else {
        try self.closed.append(ally, page);
    }

    return mem;
}

/// allocates executable memory
pub fn alloc(
    self: *Self,
    ally: Allocator,
    comptime aln: u29,
    size: usize,
) Allocator.Error![]align(aln) u8 {
    // need a big page, make a new page
    if (size > page_size) {
        return try self.allocFromNewPage(ally, aln, size);
    }

    // attempt to find open memory
    for (self.open.items, 0..) |*page, i| {
        if (page.alloc(aln, size)) |mem| {
            // page may now be full
            if (!page.isOpen()) {
                const closed_page = self.open.orderedRemove(i);
                try self.closed.append(ally, closed_page);
            }

            return mem;
        }
    }

    // no open memory, make a new page
    return try self.allocFromNewPage(ally, aln, size);
}

/// copy memory to an executable slice allocated with a JitMemory instance
pub fn copy(dst: []u8, src: []const u8) void {
    const start = @intFromPtr(dst.ptr);
    const stop = @intFromPtr(dst.ptr) + dst.len;
    const aligned_start = std.mem.alignBackward(usize, start, page_size);
    const aligned_stop = std.mem.alignForward(usize, stop, page_size);

    const pages_ptr: [*]align(page_size) u8 = @ptrFromInt(aligned_start);
    const pages_len = aligned_stop - aligned_start;
    const pages = pages_ptr[0..pages_len];

    mprotect(pages, .rw);
    @memcpy(dst, src);
    mprotect(pages, .exec);
}