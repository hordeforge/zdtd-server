//! buffs.xml: metadata + passive_effect rows. Full triggered_effect VM is later.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

pub const max_buffs: usize = 2048;
pub const max_passives_per_buff: usize = 16;
pub const max_passives_total: usize = 8192;

pub const Op = enum(u8) { base_set = 0, base_add = 1, perc_set = 2, perc_add = 3, unknown = 255 };

pub const Passive = struct {
    name: []const u8 = "",
    op: Op = .unknown,
    value: f32 = 0,
    tags: []const u8 = "",
};

pub const BuffDef = struct {
    name: []const u8 = "",
    duration: f32 = 0,
    stack_type: []const u8 = "",
    passives: []const Passive = &.{},
};

pub const Table = struct {
    defs: []const BuffDef = &.{},
    passive_pool: []const Passive = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            self.defs = &.{};
            self.passive_pool = &.{};
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn byName(self: *const Table, name: []const u8) ?BuffDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    /// Aggregate passive effect value for a buff (base_set overwrites, base_add sums).
    pub fn passiveValue(self: *const Table, buff_name: []const u8, effect: []const u8) ?f32 {
        const b = self.byName(buff_name) orelse return null;
        var acc: ?f32 = null;
        for (b.passives) |p| {
            if (!std.mem.eql(u8, p.name, effect)) continue;
            switch (p.op) {
                .base_set, .perc_set => acc = p.value,
                .base_add, .perc_add => acc = (acc orelse 0) + p.value,
                .unknown => {},
            }
        }
        return acc;
    }
};

fn parseOp(s: []const u8) Op {
    if (std.mem.eql(u8, s, "base_set")) return .base_set;
    if (std.mem.eql(u8, s, "base_add")) return .base_add;
    if (std.mem.eql(u8, s, "perc_set")) return .perc_set;
    if (std.mem.eql(u8, s, "perc_add")) return .perc_add;
    return .unknown;
}

fn firstF32(s: []const u8) f32 {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse s.len;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, s[0..comma], " \t")) catch 0;
}

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

    var ranges: std.ArrayList(struct { usize, usize }) = .empty; // passive start,len per def
    defer ranges.deinit(allocator);
    var passives_list: std.ArrayList(Passive) = .empty;
    defer passives_list.deinit(allocator);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var durs: std.ArrayList(f32) = .empty;
    defer durs.deinit(allocator);
    var stacks: std.ArrayList([]const u8) = .empty;
    defer stacks.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and names.items.len < max_buffs) {
        const bi = std.mem.indexOfPos(u8, clean, i, "<buff ") orelse break;
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 6;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, bi, ">") orelse break;
        var body_end = gt + 1;
        if (!(gt > bi and clean[gt - 1] == '/')) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</buff>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];
        var dur: f32 = 0;
        var stack: []const u8 = "";
        if (xml.attr(clean, bi, "duration")) |d| {
            dur = std.fmt.parseFloat(f32, d) catch 0;
        } else if (std.mem.indexOf(u8, body, "<duration")) |di| {
            if (xml.attr(body, di, "value")) |v| dur = std.fmt.parseFloat(f32, v) catch 0;
        }
        if (std.mem.indexOf(u8, body, "<stack_type")) |si| {
            if (xml.attr(body, si, "value")) |v| stack = try arena.dupe(u8, v);
        }
        const p0 = passives_list.items.len;
        var j: usize = 0;
        var pn: usize = 0;
        while (j < body.len and pn < max_passives_per_buff and passives_list.items.len < max_passives_total) {
            const pi = std.mem.indexOfPos(u8, body, j, "<passive_effect ") orelse break;
            const en = xml.attr(body, pi, "name") orelse {
                j = pi + 16;
                continue;
            };
            const op_s = xml.attr(body, pi, "operation") orelse "base_add";
            const val_s = xml.attr(body, pi, "value") orelse "0";
            const tags = xml.attr(body, pi, "tags") orelse "";
            try passives_list.append(allocator, .{
                .name = try arena.dupe(u8, en),
                .op = parseOp(op_s),
                .value = firstF32(val_s),
                .tags = try arena.dupe(u8, tags),
            });
            pn += 1;
            j = pi + 16;
        }
        try names.append(allocator, try arena.dupe(u8, name));
        try durs.append(allocator, dur);
        try stacks.append(allocator, stack);
        try ranges.append(allocator, .{ p0, passives_list.items.len - p0 });
        i = body_end + 1;
    }

    const pool = try arena.alloc(Passive, passives_list.items.len);
    @memcpy(pool, passives_list.items);
    const defs = try arena.alloc(BuffDef, names.items.len);
    for (names.items, durs.items, stacks.items, ranges.items, 0..) |nm, dur, st, rg, di| {
        defs[di] = .{
            .name = nm,
            .duration = dur,
            .stack_type = st,
            .passives = pool[rg[0] .. rg[0] + rg[1]],
        };
    }
    return .{ .defs = defs, .passive_pool = pool, .arena_ptr = arena_holder };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("buffs.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "load buffs.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    var t = loadFromPath(std.testing.allocator, p) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.defs.len > 10);
    try std.testing.expect(t.passive_pool.len > 0);
}
