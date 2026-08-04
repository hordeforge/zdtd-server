//! Closed↔Open storage block pairs from blocks.xml DowngradeBlock.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

pub const max_pairs: usize = 128;

pub const Pair = struct {
    closed_name: []const u8 = "",
    open_name: []const u8 = "",
    closed_id: u16 = 0,
    open_id: u16 = 0,
};

pub const Table = struct {
    pairs: []const Pair = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    /// Map closed→open or open→closed id when both resolved.
    pub fn toggleId(self: *const Table, block_id: u16) ?u16 {
        for (self.pairs) |p| {
            if (p.closed_id != 0 and p.closed_id == block_id and p.open_id != 0) return p.open_id;
            if (p.open_id != 0 and p.open_id == block_id and p.closed_id != 0) return p.closed_id;
        }
        return null;
    }

    pub fn resolveIds(self: *Table, id_by_name: *const fn (?*anyopaque, []const u8) ?u16, ctx: ?*anyopaque) void {
        // pairs is const slice of arena data; need mutable — store as owned mutable via cast
        const mut: []Pair = @constCast(self.pairs);
        for (mut) |*p| {
            if (id_by_name(ctx, p.closed_name)) |id| p.closed_id = id;
            if (id_by_name(ctx, p.open_name)) |id| p.open_id = id;
        }
    }
};

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(Pair) = .empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and list.items.len < max_pairs) {
        const bi = std.mem.indexOfPos(u8, clean, i, "<block ") orelse break;
        const bname = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        if (!std.mem.endsWith(u8, bname, "Closed")) {
            i = bi + 7;
            continue;
        }
        const gt = std.mem.indexOfPos(u8, clean, bi, ">") orelse break;
        var body_end = gt + 1;
        if (!(gt > bi and clean[gt - 1] == '/')) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</block>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];
        const open = xml.propertyValue(body, "DowngradeBlock") orelse {
            i = body_end + 1;
            continue;
        };
        if (std.mem.indexOf(u8, open, "Open") == null) {
            i = body_end + 1;
            continue;
        }
        try list.append(allocator, .{
            .closed_name = try arena.dupe(u8, bname),
            .open_name = try arena.dupe(u8, open),
        });
        i = body_end + 1;
    }

    const pairs = try arena.alloc(Pair, list.items.len);
    @memcpy(pairs, list.items);
    return .{ .pairs = pairs, .arena_ptr = arena_holder };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("blocks.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "load storage pairs when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/blocks.xml";
    var t = loadFromPath(std.testing.allocator, p) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.pairs.len >= 5);
    var found = false;
    for (t.pairs) |pr| {
        if (std.mem.eql(u8, pr.closed_name, "cntWoodenChestClosed")) {
            found = true;
            try std.testing.expectEqualStrings("cntWoodenChestOpen", pr.open_name);
        }
    }
    try std.testing.expect(found);
}
