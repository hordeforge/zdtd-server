//! traders.xml: trader_item_groups with nested group refs (cycle-safe expand).

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

pub const max_entries: usize = 128;
pub const max_groups: usize = 256;
pub const max_expand: usize = 64;
pub const max_group_depth: usize = 8;
pub const max_traders: usize = 32;

pub const Entry = struct {
    name: []const u8 = "",
    count: u16 = 1,
};

/// One `<item .../>` ref inside a trader_info `<trader_items>` block. A group
/// ref expands to the group's items at fill time; a name ref is a direct item.
pub const ItemRef = struct {
    name: []const u8 = "",
    count: u16 = 1,
    group: bool = false,
};

/// traders.xml `<trader_info id="N">` block: per-trader hours, vending /
/// player-owned flags and the `<trader_items>` refs that make that trader's
/// stock (stock maps entity class → trader_id via npc.xml).
pub const TraderInfo = struct {
    id: u16 = 0,
    /// "4:05" stock format; "" = no hours gate (always open).
    open_time: []const u8 = "",
    close_time: []const u8 = "",
    is_vending: bool = false,
    /// false → the trader does not buy from players (vending, player-owned).
    allow_sell: bool = true,
    /// 0 = unset (root economy / pricing row owns the price math).
    override_buy_markup: f32 = 0,
    override_sell_markup: f32 = 0,
    /// -1 = never; >0 = days between restock (restock row owns the timer).
    reset_interval: i32 = 0,
    player_owned: bool = false,
    rentable: bool = false,
    rent_cost: i32 = 0,
    rent_time: i32 = 0,
    /// Union of every `<trader_items>` block, in XML order (SPECIALTY first).
    refs: []const ItemRef = &.{},
};

pub const Group = struct {
    name: []const u8 = "",
    /// Direct item names in this group (not nested group refs).
    items: []const Entry = &.{},
    /// Nested group names.
    child_groups: []const []const u8 = &.{},
};

pub const TraderTable = struct {
    /// Expanded traderAlways stock (direct + resolved groups, deterministic first picks).
    entries: []const Entry = &.{},
    groups: []const Group = &.{},
    /// Per-trader `<trader_info>` blocks keyed by id.
    trader_infos: []const TraderInfo = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *TraderTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
        }
        self.* = .{};
    }

    pub fn empty() TraderTable {
        return .{};
    }

    pub fn groupByName(self: *const TraderTable, name: []const u8) ?Group {
        for (self.groups) |g| {
            if (std.mem.eql(u8, g.name, name)) return g;
        }
        return null;
    }

    /// Expand a named group into out[] (direct items + recursive children).
    /// Depth-limited; visits set prevents cycles. Returns count written.
    pub fn expandGroup(self: *const TraderTable, name: []const u8, out: []Entry) usize {
        var visited: [max_groups]bool = .{false} ** max_groups;
        return expandGroupRec(self, name, out, 0, &visited);
    }

    fn expandGroupRec(self: *const TraderTable, name: []const u8, out: []Entry, depth: usize, visited: *[max_groups]bool) usize {
        if (depth >= max_group_depth or out.len == 0) return 0;
        const g = self.groupByName(name) orelse return 0;
        // Find group index for visit bit
        var gi: usize = 0;
        while (gi < self.groups.len) : (gi += 1) {
            if (std.mem.eql(u8, self.groups[gi].name, name)) break;
        }
        if (gi < max_groups) {
            if (visited[gi]) return 0;
            visited[gi] = true;
        }
        var n: usize = 0;
        for (g.items) |e| {
            if (n >= out.len) break;
            out[n] = e;
            n += 1;
        }
        for (g.child_groups) |cg| {
            if (n >= out.len) break;
            n += expandGroupRec(self, cg, out[n..], depth + 1, visited);
        }
        return n;
    }

    pub fn traderInfo(self: *const TraderTable, id: u16) ?TraderInfo {
        for (self.trader_infos) |ti| {
            if (ti.id == id) return ti;
        }
        return null;
    }

    /// Expand a trader_info's refs into out[]: direct names keep their ref
    /// count, group refs expand via expandGroup (pick-count/RNG is the
    /// inventory-roll row). Returns count written; preserves ref order.
    pub fn expandTraderRefs(self: *const TraderTable, info: TraderInfo, out: []Entry) usize {
        var n: usize = 0;
        var group_buf: [max_expand]Entry = undefined;
        for (info.refs) |r| {
            if (n >= out.len) break;
            if (r.group) {
                const en = self.expandGroup(r.name, &group_buf);
                const k = @min(en, out.len - n);
                @memcpy(out[n..][0..k], group_buf[0..k]);
                n += k;
            } else {
                out[n] = .{ .name = r.name, .count = r.count };
                n += 1;
            }
        }
        return n;
    }
};

fn lowCount(v: []const u8) u16 {
    const comma = std.mem.indexOfScalar(u8, v, ',') orelse v.len;
    return std.fmt.parseInt(u16, v[0..comma], 10) catch 1;
}

fn parseGroupBody(arena: std.mem.Allocator, gpa: std.mem.Allocator, body: []const u8) !struct { []Entry, [][]const u8 } {
    var items: std.ArrayList(Entry) = .empty;
    defer items.deinit(gpa);
    var children: std.ArrayList([]const u8) = .empty;
    defer children.deinit(gpa);
    var i: usize = 0;
    while (i < body.len) {
        const ii = std.mem.indexOfPos(u8, body, i, "<item ") orelse break;
        i = ii + 6;
        if (xml.attr(body, ii, "group")) |gname| {
            try children.append(gpa, try arena.dupe(u8, gname));
            continue;
        }
        const name = xml.attr(body, ii, "name") orelse continue;
        const count: u16 = if (xml.attr(body, ii, "count")) |cv| lowCount(cv) else 1;
        try items.append(gpa, .{ .name = try arena.dupe(u8, name), .count = count });
    }
    const islice = try arena.alloc(Entry, items.items.len);
    @memcpy(islice, items.items);
    const cslice = try arena.alloc([]const u8, children.items.len);
    @memcpy(cslice, children.items);
    return .{ islice, cslice };
}

/// Parse one `<trader_items>` body into ItemRefs (group and name refs kept).
fn parseTraderRefs(arena: std.mem.Allocator, gpa: std.mem.Allocator, body: []const u8) ![]const ItemRef {
    var refs: std.ArrayList(ItemRef) = .empty;
    defer refs.deinit(gpa);
    var i: usize = 0;
    while (i < body.len) {
        const ii = std.mem.indexOfPos(u8, body, i, "<item ") orelse break;
        i = ii + 6;
        const count: u16 = if (xml.attr(body, ii, "count")) |cv| lowCount(cv) else 1;
        if (xml.attr(body, ii, "group")) |gname| {
            try refs.append(gpa, .{ .name = try arena.dupe(u8, gname), .count = count, .group = true });
            continue;
        }
        const name = xml.attr(body, ii, "name") orelse continue;
        try refs.append(gpa, .{ .name = try arena.dupe(u8, name), .count = count });
    }
    const rsl = try arena.alloc(ItemRef, refs.items.len);
    @memcpy(rsl, refs.items);
    return rsl;
}

fn attrBool(v: []const u8, dflt: bool) bool {
    if (v.len == 0) return dflt;
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "True");
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !TraderTable {
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

    var groups: std.ArrayList(Group) = .empty;
    defer groups.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and groups.items.len < max_groups) {
        const gi = std.mem.indexOfPos(u8, clean, i, "<trader_item_group ") orelse break;
        const gname = xml.attr(clean, gi, "name") orelse {
            i = gi + 18;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, gi, ">") orelse break;
        const close = std.mem.indexOfPos(u8, clean, gt, "</trader_item_group>") orelse break;
        const body = clean[gt + 1 .. close];
        const parsed = try parseGroupBody(arena, allocator, body);
        try groups.append(allocator, .{
            .name = try arena.dupe(u8, gname),
            .items = parsed[0],
            .child_groups = parsed[1],
        });
        i = close + 20;
    }
    if (groups.items.len == 0) return error.OpenFailed;

    // Per-trader `<trader_info>` blocks: id + hours/vending/player-owned attrs
    // + the `<trader_items>` refs that make that trader's own stock.
    var trader_infos: std.ArrayList(TraderInfo) = .empty;
    defer trader_infos.deinit(allocator);
    var j: usize = 0;
    while (j < clean.len and trader_infos.items.len < max_traders) {
        const ti = std.mem.indexOfPos(u8, clean, j, "<trader_info ") orelse break;
        j = ti + 13;
        const idv = xml.attr(clean, ti, "id") orelse continue;
        const id = std.fmt.parseInt(u16, idv, 10) catch continue;
        const gt = std.mem.indexOfPos(u8, clean, ti, ">") orelse break;
        const self_closing = gt > ti and clean[gt - 1] == '/';
        var refs: []const ItemRef = &.{};
        if (!self_closing) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</trader_info>") orelse break;
            refs = try parseTraderRefs(arena, allocator, clean[gt + 1 .. close]);
            j = close + 15;
        }
        try trader_infos.append(allocator, .{
            .id = id,
            .open_time = try arena.dupe(u8, xml.attr(clean, ti, "open_time") orelse ""),
            .close_time = try arena.dupe(u8, xml.attr(clean, ti, "close_time") orelse ""),
            .is_vending = attrBool(xml.attr(clean, ti, "is_vending") orelse "", false),
            .allow_sell = attrBool(xml.attr(clean, ti, "allow_sell") orelse "", true),
            .override_buy_markup = std.fmt.parseFloat(f32, xml.attr(clean, ti, "override_buy_markup") orelse "0") catch 0,
            .override_sell_markup = std.fmt.parseFloat(f32, xml.attr(clean, ti, "override_sell_markup") orelse "0") catch 0,
            .reset_interval = std.fmt.parseInt(i32, xml.attr(clean, ti, "reset_interval") orelse "0", 10) catch 0,
            .player_owned = attrBool(xml.attr(clean, ti, "player_owned") orelse "", false),
            .rentable = attrBool(xml.attr(clean, ti, "rentable") orelse "", false),
            .rent_cost = std.fmt.parseInt(i32, xml.attr(clean, ti, "rent_cost") orelse "0", 10) catch 0,
            .rent_time = std.fmt.parseInt(i32, xml.attr(clean, ti, "rent_time") orelse "0", 10) catch 0,
            .refs = refs,
        });
    }
    const tisl = try arena.alloc(TraderInfo, trader_infos.items.len);
    @memcpy(tisl, trader_infos.items);

    const gsl = try arena.alloc(Group, groups.items.len);
    @memcpy(gsl, groups.items);

    var table: TraderTable = .{ .groups = gsl, .arena_ptr = arena_holder, .trader_infos = tisl };

    // Expand traderAlways into entries (primary stock list).
    var expand_buf: [max_expand]Entry = undefined;
    const en = table.expandGroup("traderAlways", &expand_buf);
    if (en == 0) {
        // Fallback: first group with direct items
        for (table.groups) |g| {
            if (g.items.len > 0) {
                const n = @min(g.items.len, max_entries);
                const entries = try arena.alloc(Entry, n);
                @memcpy(entries, g.items[0..n]);
                table.entries = entries;
                return table;
            }
        }
        return error.OpenFailed;
    }
    const n = @min(en, max_entries);
    const entries = try arena.alloc(Entry, n);
    @memcpy(entries, expand_buf[0..n]);
    table.entries = entries;
    return table;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) ?TraderTable {
    return paths.tryLoadConfig("traders.xml", TraderTable, loadFromPath, allocator, game_dir, config_dir) catch null;
}

test "trader table parses stock traderAlways when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/traders.xml";
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.groups.len >= 5);
    try std.testing.expect(t.entries.len >= 5);
    var found_bandage = false;
    for (t.entries) |e| {
        if (std.mem.eql(u8, e.name, "medicalBandage")) {
            found_bandage = true;
            try std.testing.expect(e.count >= 3);
        }
    }
    try std.testing.expect(found_bandage);
    // Nested expand of a known group with children
    var buf: [64]Entry = undefined;
    const n = t.expandGroup("groupAllAmmo", &buf);
    try std.testing.expect(n > 0);
}

test "trader table parses trader_info blocks with per-trader items and attrs" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/traders.xml";
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    // The five NPC traders (joel=1 jen=2 bob=6 hugh=7 rekt=8) plus vending
    // (4,10) and player-owned/rentable (3,5) all exist as trader_info blocks.
    try std.testing.expect(t.trader_infos.len >= 10);
    for ([_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) |want| {
        try std.testing.expect(t.traderInfo(want) != null);
    }
    // Joel (1): armor specialty + general blocks, refs preserved in order.
    const joel = t.traderInfo(1).?;
    try std.testing.expect(joel.open_time.len > 0);
    try std.testing.expectEqualStrings("4:05", joel.open_time);
    try std.testing.expectEqualStrings("21:50", joel.close_time);
    try std.testing.expect(!joel.is_vending);
    try std.testing.expect(joel.allow_sell);
    try std.testing.expect(joel.refs.len >= 10);
    var saw_armor_group = false;
    var saw_direct_name = false;
    for (joel.refs) |r| {
        if (r.group and std.mem.eql(u8, r.name, "groupArmorLight")) saw_armor_group = true;
        if (!r.group and std.mem.eql(u8, r.name, "armorParts")) saw_direct_name = true;
    }
    try std.testing.expect(saw_armor_group);
    try std.testing.expect(saw_direct_name);
    // Vending trader 4 is always open (no hours), does not buy from players.
    const vend = t.traderInfo(4).?;
    try std.testing.expect(vend.is_vending);
    try std.testing.expect(!vend.allow_sell);
    // Player-owned 3 and rentable 5 carry their flags; 5 has hours like the NPCs.
    const po = t.traderInfo(3).?;
    try std.testing.expect(po.player_owned);
    try std.testing.expect(!po.allow_sell);
    try std.testing.expectEqual(@as(f32, 1.0), po.override_buy_markup);
    const rent = t.traderInfo(5).?;
    try std.testing.expect(rent.rentable);
    try std.testing.expectEqual(@as(i32, 2500), rent.rent_cost);
    try std.testing.expectEqual(@as(i32, 30), rent.rent_time);
    // expandTraderRefs resolves group refs (Joel's specialty has no traderAlways).
    var out: [128]Entry = undefined;
    const on = t.expandTraderRefs(joel, &out);
    try std.testing.expect(on > joel.refs.len);
    try std.testing.expect(on <= out.len);
    // Jen (2) is a different list from Joel (1): different direct names.
    const jen = t.traderInfo(2).?;
    var outj: [128]Entry = undefined;
    const ojn = t.expandTraderRefs(jen, &outj);
    try std.testing.expect(ojn > 0);
    var same_lead = true;
    const k = @min(on, ojn);
    for (out[0..k], outj[0..k]) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name)) same_lead = false;
    }
    try std.testing.expect(!same_lead);
}
