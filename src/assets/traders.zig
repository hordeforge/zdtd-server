//! traders.xml: trader_item_groups, trader_info blocks, and the stock
//! inventory roll (TraderInfo::Spawn, asm.il 862758-863520).
//!
//! The roll is a faithful port of stock TraderInfo spawning: top-level refs
//! always spawn (SpawnAllItemsFromList), group members are picked
//! prob-weighted with dedupe (SpawnLootItemsFromList), counts roll uniform in
//! [min,max] (RandomSpawnCount), and quality rolls uniform in the entry's
//! quality range. The RNG is caller-supplied and seeded, so the same
//! (world, trader, day) reproduces the same stock (sim rule: deterministic
//! inputs), unlike stock's per-ItemValue time-seeded GameRandom.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");
const rng_util = @import("../util/rng.zig");

pub const max_groups: usize = 256;
pub const max_expand: usize = 64;
pub const max_group_depth: usize = 8;
pub const max_traders: usize = 32;

/// One `<item .../>` ref inside a trader_info `<trader_items>` block or a
/// group body. A group ref expands to the group's items at roll time; a name
/// ref is a direct item.
pub const ItemRef = struct {
    name: []const u8 = "",
    count_min: u16 = 1,
    count_max: u16 = 1,
    /// prob attr (default 1). Group-internal picks are weighted by prob share
    /// (stock TraderInfo::SpawnLootItemsFromList: acc += prob / sum), so 120
    /// is a heavier weight, 0.5 is half weight, 0 never picks.
    prob: f32 = 1,
    /// quality="lo,hi" roll bounds; 0/0 = unset (wire quality 1).
    quality_lo: u8 = 0,
    quality_hi: u8 = 0,
    unique_only: bool = false,
    group: bool = false,
};

/// traders.xml `<trader_item_group>`: the refs and the group-level count
/// (rounds per ref expansion) and uniqueOnly flag.
pub const Group = struct {
    name: []const u8 = "",
    refs: []const ItemRef = &.{},
    /// count="N" or "lo,hi": each group-ref round rolls this many picks from
    /// the group (stock TraderInfo::SpawnItemsFromGroup inner roll). Default
    /// 1/1.
    count_min: u16 = 1,
    count_max: u16 = 1,
    /// count="all": every group item spawns each round (-1 sentinel in stock).
    count_all: bool = false,
    unique_only: bool = false,
};

/// Result of a stock roll: one concrete stack to put in a trader window.
pub const RolledItem = struct {
    name: []const u8 = "",
    count: u16 = 0,
    quality: u8 = 1,
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

pub const TraderTable = struct {
    groups: []const Group = &.{},
    /// Per-trader `<trader_info>` blocks keyed by id.
    trader_infos: []const TraderInfo = &.{},
    /// The traderAlways group's refs (fallback stock for traders without
    /// their own `<trader_items>`).
    trader_always_refs: []const ItemRef = &.{},
    /// Root `<traders>` economy row: default buy/sell multipliers (stock
    /// GetBuyPrice/GetSellPrice; per-trader Override* wins when set).
    buy_markup: f32 = 0,
    sell_markdown: f32 = 0,
    /// Root `currency_item` name (stock traders.xml: "casinoCoin"). Game pays
    /// trade/rent in this item; empty = the stock-name fallback.
    currency_item: []const u8 = "",
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

    pub fn traderInfo(self: *const TraderTable, id: u16) ?TraderInfo {
        for (self.trader_infos) |ti| {
            if (ti.id == id) return ti;
        }
        return null;
    }

    /// Roll every ref in a list the way stock TraderInfo::Spawn does
    /// (SpawnAllItemsFromList, asm.il 863190): each ref always spawns, its
    /// count rolls in [min,max], and a group ref expands through
    /// spawnItemsFromGroup. Writes into out[]; returns count written.
    pub fn rollAllRefs(self: *const TraderTable, refs: []const ItemRef, rng: *rng_util.XorShift32, out: []RolledItem) usize {
        var n: usize = 0;
        for (refs) |r| {
            const count = randomSpawnCount(rng, r.count_min, r.count_max);
            // Stock abundance is 1.0 by default (TraderItemAbundance); the
            // FastMax(1, count*abundance) floor stays so a 0 roll still sells 1.
            const count_final: i32 = @max(1, count);
            if (r.group) {
                spawnItemsFromGroup(self, r.name, count_final, rng, r.unique_only, out, &n, 0);
            } else {
                spawnItem(r, count_final, rng, out, &n);
            }
        }
        return n;
    }

    /// Prob-weighted picks from a group's refs, stock
    /// SpawnLootItemsFromList (asm.il 863343): one RandomFloat per pick, walk
    /// the refs accumulating prob share, first ref whose share passes the
    /// roll is spawned and (when unique) removed from the pool.
    fn spawnLootItemsFromList(self: *const TraderTable, refs: []const ItemRef, num_to_spawn: i32, rng: *rng_util.XorShift32, used: ?[]bool, out: []RolledItem, n: *usize, depth: usize) void {
        if (num_to_spawn < 0) {
            spawnAllRefs(self, refs, rng, out, n, depth);
            return;
        }
        if (num_to_spawn == 0) return;
        var sum: f32 = 0;
        for (refs, 0..) |r, i| {
            if (used != null and used.?[i]) continue;
            sum += r.prob;
        }
        if (sum == 0) return;
        var pick: i32 = 0;
        while (pick < num_to_spawn) : (pick += 1) {
            const roll = rngFloat(rng);
            var acc: f32 = 0;
            var picked = false;
            for (refs, 0..) |r, i| {
                if (used != null and used.?[i]) continue;
                acc += r.prob / sum;
                if (roll > acc) continue;
                if (used != null) used.?[i] = true;
                const count = randomSpawnCount(rng, r.count_min, r.count_max);
                if (r.group) {
                    spawnItemsFromGroup(self, r.name, count, rng, r.unique_only, out, n, depth);
                } else {
                    spawnItem(r, count, rng, out, n);
                }
                picked = true;
                break;
            }
            if (!picked) return;
        }
    }

    /// Stock SpawnAllItemsFromList (asm.il 863190) used by both the top-level
    /// spawn (numToSpawn -1) and count="all" groups: every ref spawns with a
    /// count roll and no prob gate.
    fn spawnAllRefs(self: *const TraderTable, refs: []const ItemRef, rng: *rng_util.XorShift32, out: []RolledItem, n: *usize, depth: usize) void {
        for (refs) |r| {
            const count: i32 = @max(1, randomSpawnCount(rng, r.count_min, r.count_max));
            if (r.group) {
                spawnItemsFromGroup(self, r.name, count, rng, r.unique_only, out, n, depth);
            } else {
                spawnItem(r, count, rng, out, n);
            }
        }
    }

    /// Stock SpawnItemsFromGroup (asm.il 863290): num_to_spawn rounds, each
    /// rolling the group's own count and picking that many refs from it.
    fn spawnItemsFromGroup(self: *const TraderTable, group_name: []const u8, num_to_spawn: i32, rng: *rng_util.XorShift32, unique: bool, out: []RolledItem, n: *usize, depth: usize) void {
        if (depth >= max_group_depth or n.* >= out.len) return;
        const g = self.groupByName(group_name) orelse return;
        if (g.refs.len == 0) return;
        var used_buf: [max_expand]bool = .{false} ** max_expand;
        const use_unique = g.unique_only or unique;
        const used: ?[]bool = if (use_unique) used_buf[0..g.refs.len] else null;
        var round: i32 = 0;
        while (round < num_to_spawn and n.* < out.len) : (round += 1) {
            var picks: i32 = undefined;
            if (g.count_all) {
                picks = -1;
            } else {
                picks = randomSpawnCount(rng, g.count_min, g.count_max);
            }
            spawnLootItemsFromList(self, g.refs, picks, rng, used, out, n, depth + 1);
        }
    }

    /// Stock TraderInfo::SpawnItem tail (asm.il 862810): one stack with the
    /// rolled count and a quality rolled uniform in the entry's range when the
    /// XML set one (stock ItemValue ctor: RandomRange(min, max+1), asm.il
    /// 616396); unset stays quality 1 (stackables have no quality).
    fn spawnItem(r: ItemRef, count: i32, rng: *rng_util.XorShift32, out: []RolledItem, n: *usize) void {
        if (count < 1 or n.* >= out.len) return;
        var quality: u8 = 1;
        if (r.quality_lo > 0 and r.quality_hi >= r.quality_lo) {
            quality = @intCast(r.quality_lo + rng.nextBounded(@as(u32, r.quality_hi) - @as(u32, r.quality_lo) + 1));
        }
        out[n.*] = .{ .name = r.name, .count = @intCast(count), .quality = quality };
        n.* += 1;
    }
};

/// Stock TraderInfo::RandomSpawnCount (asm.il 863128): uniform float in
/// [min-0.49, max+0.49] clamped to [min, max], rounded up with probability
/// equal to the fraction, so ints land ~uniform in [min, max]. max < 0 (the
/// "all" sentinel) returns -1.
fn randomSpawnCount(rng: *rng_util.XorShift32, min: u16, max: u16) i32 {
    var v = randomRangeF(rng, @as(f32, @floatFromInt(min)) - 0.49, @as(f32, @floatFromInt(max)) + 0.49);
    if (v <= @as(f32, @floatFromInt(min))) return min;
    if (v > @as(f32, @floatFromInt(max))) v = @floatFromInt(max);
    const iv: i32 = @trunc(v);
    const frac = v - @as(f32, @floatFromInt(iv));
    if (rngFloat(rng) < frac) return iv + 1;
    return iv;
}

/// GameRandom.RandomFloat equivalent: uniform float in [0, 1).
fn rngFloat(rng: *rng_util.XorShift32) f32 {
    return @as(f32, @floatFromInt(rng.next() >> 8)) / 16777216.0;
}

/// GameRandom.RandomRange(float, float) equivalent (Unity float semantics:
/// min inclusive, max exclusive).
fn randomRangeF(rng: *rng_util.XorShift32, min: f32, max: f32) f32 {
    if (max <= min) return min;
    return min + (max - min) * rngFloat(rng);
}

/// Parse a count/quality "N" or "lo,hi" attribute. "all" is handled by the
/// caller (count_all flag); anything unparsable falls back to the default.
fn parseMinMax(v: []const u8, dflt: u16) struct { u16, u16 } {
    if (v.len == 0 or std.mem.eql(u8, v, "all")) return .{ dflt, dflt };
    const comma = std.mem.findScalar(u8, v, ',') orelse {
        const n = std.fmt.parseInt(u16, v, 10) catch return .{ dflt, dflt };
        return .{ n, n };
    };
    const lo = std.fmt.parseInt(u16, v[0..comma], 10) catch return .{ dflt, dflt };
    const hi = std.fmt.parseInt(u16, v[comma + 1 ..], 10) catch lo;
    return .{ lo, @max(lo, hi) };
}

fn parseProb(v: []const u8) f32 {
    if (v.len == 0) return 1;
    return std.fmt.parseFloat(f32, v) catch 1;
}

/// quality="lo,hi" (both 1..6 in stock XML); 0/0 = unset.
fn parseQuality(v: []const u8) struct { u8, u8 } {
    if (v.len == 0) return .{ 0, 0 };
    const comma = std.mem.findScalar(u8, v, ',') orelse {
        const q = std.fmt.parseInt(u8, v, 10) catch return .{ 0, 0 };
        return .{ q, q };
    };
    const lo = std.fmt.parseInt(u8, v[0..comma], 10) catch return .{ 0, 0 };
    const hi = std.fmt.parseInt(u8, v[comma + 1 ..], 10) catch lo;
    return .{ lo, @max(lo, hi) };
}

fn parseItemRef(arena: std.mem.Allocator, body: []const u8, ii: usize) ?ItemRef {
    const gname = xml.attr(body, ii, "group");
    const name = xml.attr(body, ii, "name") orelse {
        // A ref must carry `group` or `name` (stock throws otherwise).
        if (gname == null) return null;
        return parseItemRefNamed(arena, body, ii, gname.?, true);
    };
    return parseItemRefNamed(arena, body, ii, name, gname != null);
}

fn parseItemRefNamed(arena: std.mem.Allocator, body: []const u8, ii: usize, ref_name: []const u8, is_group: bool) ?ItemRef {
    const mm = parseMinMax(xml.attr(body, ii, "count") orelse "", 1);
    const q = parseQuality(xml.attr(body, ii, "quality") orelse "");
    const unique = xml.attr(body, ii, "unique_only") orelse "";
    return .{
        .name = arena.dupe(u8, ref_name) catch return null,
        .count_min = mm[0],
        .count_max = mm[1],
        .prob = parseProb(xml.attr(body, ii, "prob") orelse ""),
        .quality_lo = q[0],
        .quality_hi = q[1],
        .unique_only = std.mem.eql(u8, unique, "true") or std.mem.eql(u8, unique, "True"),
        .group = is_group,
    };
}

fn parseRefsBody(arena: std.mem.Allocator, gpa: std.mem.Allocator, body: []const u8) ![]const ItemRef {
    var refs: std.ArrayList(ItemRef) = .empty;
    defer refs.deinit(gpa);
    var i: usize = 0;
    while (i < body.len and refs.items.len < max_expand) {
        const ii = std.mem.findPos(u8, body, i, "<item ") orelse break;
        i = ii + 6;
        if (parseItemRef(arena, body, ii)) |r| {
            try refs.append(gpa, r);
        }
    }
    const sl = try arena.alloc(ItemRef, refs.items.len);
    @memcpy(sl, refs.items);
    return sl;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !TraderTable {
    const clean = try xml.readCleanFile(allocator, path);
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
        const gi = std.mem.findPos(u8, clean, i, "<trader_item_group ") orelse break;
        const gname = xml.attr(clean, gi, "name") orelse {
            i = gi + 18;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, gi, ">") orelse break;
        const close = std.mem.findPos(u8, clean, gt, "</trader_item_group>") orelse break;
        const body = clean[gt + 1 .. close];
        const refs = try parseRefsBody(arena, allocator, body);
        const cnt = xml.attr(clean, gi, "count") orelse "";
        const count_all = std.mem.eql(u8, cnt, "all");
        const mm = parseMinMax(cnt, 1);
        const uniq = xml.attr(clean, gi, "unique_only") orelse "";
        try groups.append(allocator, .{
            .name = try arena.dupe(u8, gname),
            .refs = refs,
            .count_min = mm[0],
            .count_max = mm[1],
            .count_all = count_all,
            .unique_only = std.mem.eql(u8, uniq, "true") or std.mem.eql(u8, uniq, "True"),
        });
        i = close + 20;
    }
    if (groups.items.len == 0) return error.OpenFailed;

    // Root `<traders>` economy row (buy_markup / sell_markdown) used by the
    // per-item price math unless a trader_info Override* is set.
    var root_buy_markup: f32 = 0;
    var root_sell_markdown: f32 = 0;
    var root_currency: []const u8 = "";
    if (std.mem.findPos(u8, clean, 0, "<traders")) |tr| {
        if (xml.attr(clean, tr, "buy_markup")) |v| root_buy_markup = std.fmt.parseFloat(f32, v) catch 0;
        if (xml.attr(clean, tr, "sell_markdown")) |v| root_sell_markdown = std.fmt.parseFloat(f32, v) catch 0;
        if (xml.attr(clean, tr, "currency_item")) |v| root_currency = try arena.dupe(u8, v);
    }

    // traderAlways group refs = the shared fallback stock list.
    var trader_always: []const ItemRef = &.{};
    for (groups.items) |g| {
        if (std.mem.eql(u8, g.name, "traderAlways")) {
            trader_always = g.refs;
            break;
        }
    }

    // trader_info blocks (the previous loop advanced i past the groups).
    var trader_infos: std.ArrayList(TraderInfo) = .empty;
    defer trader_infos.deinit(allocator);
    i = 0;
    while (i < clean.len and trader_infos.items.len < max_traders) {
        const ti = std.mem.findPos(u8, clean, i, "<trader_info ") orelse break;
        i = ti + 13;
        const idv = xml.attr(clean, ti, "id") orelse continue;
        const id = std.fmt.parseInt(u16, idv, 10) catch continue;
        const gt = std.mem.findPos(u8, clean, ti, ">") orelse break;
        const self_closing = gt > ti and clean[gt - 1] == '/';
        var refs: []const ItemRef = &.{};
        if (!self_closing) {
            const close = std.mem.findPos(u8, clean, gt, "</trader_info>") orelse break;
            refs = try parseRefsBody(arena, allocator, clean[gt + 1 .. close]);
            i = close + "</trader_info>".len;
        }
        const open_time = xml.attr(clean, ti, "open_time") orelse "";
        const close_time = xml.attr(clean, ti, "close_time") orelse "";
        const is_vending = xml.attr(clean, ti, "is_vending") orelse "";
        const allow_sell = xml.attr(clean, ti, "allow_sell") orelse "";
        const player_owned = xml.attr(clean, ti, "player_owned") orelse "";
        const rentable = xml.attr(clean, ti, "rentable") orelse "";
        const buy_ov = xml.attr(clean, ti, "override_buy_markup") orelse "";
        const sell_ov = xml.attr(clean, ti, "override_sell_markup") orelse "";
        const reset = xml.attr(clean, ti, "reset_interval") orelse "";
        const rent_cost_v = xml.attr(clean, ti, "rent_cost") orelse "";
        const rent_time_v = xml.attr(clean, ti, "rent_time") orelse "";
        try trader_infos.append(allocator, .{
            .id = id,
            .open_time = try arena.dupe(u8, open_time),
            .close_time = try arena.dupe(u8, close_time),
            .is_vending = std.mem.eql(u8, is_vending, "true") or std.mem.eql(u8, is_vending, "True"),
            .allow_sell = !(std.mem.eql(u8, allow_sell, "false") or std.mem.eql(u8, allow_sell, "False")),
            .override_buy_markup = if (buy_ov.len > 0) std.fmt.parseFloat(f32, buy_ov) catch 0 else 0,
            .override_sell_markup = if (sell_ov.len > 0) std.fmt.parseFloat(f32, sell_ov) catch 0 else 0,
            .reset_interval = if (reset.len > 0) std.fmt.parseInt(i32, reset, 10) catch 0 else 0,
            .player_owned = std.mem.eql(u8, player_owned, "true") or std.mem.eql(u8, player_owned, "True"),
            .rentable = std.mem.eql(u8, rentable, "true") or std.mem.eql(u8, rentable, "True"),
            .rent_cost = if (rent_cost_v.len > 0) std.fmt.parseInt(i32, rent_cost_v, 10) catch 0 else 0,
            .rent_time = if (rent_time_v.len > 0) std.fmt.parseInt(i32, rent_time_v, 10) catch 0 else 0,
            .refs = refs,
        });
    }
    if (trader_infos.items.len == 0) return error.OpenFailed;

    const gsl = try arena.alloc(Group, groups.items.len);
    @memcpy(gsl, groups.items);
    const tisl = try arena.alloc(TraderInfo, trader_infos.items.len);
    @memcpy(tisl, trader_infos.items);

    return .{
        .groups = gsl,
        .trader_infos = tisl,
        .trader_always_refs = trader_always,
        .buy_markup = root_buy_markup,
        .sell_markdown = root_sell_markdown,
        .currency_item = root_currency,
        .arena_ptr = arena_holder,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?TraderTable {
    return paths.tryLoadConfig("traders.xml", TraderTable, loadFromPath, allocator, game_dir, config_dir);
}

test "trader table parses stock traderAlways and group refs with attrs" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/traders.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.groups.len >= 5);
    try std.testing.expect(t.trader_always_refs.len >= 5);
    // Group refs keep their count ranges and unique_only (the old parser
    // dropped them): traderAlways lists groupDyeMods unique_only count=4.
    var saw_dye_unique = false;
    for (t.trader_always_refs) |r| {
        if (r.group and std.mem.eql(u8, r.name, "groupDyeMods")) {
            saw_dye_unique = r.unique_only and r.count_min == 4 and r.count_max == 4;
        }
    }
    try std.testing.expect(saw_dye_unique);
    // Ammo refs carry count ranges (40,150), and a prob-gated ref parses.
    var saw_ammo_range = false;
    var saw_prob = false;
    for (t.trader_always_refs) |r| {
        if (!r.group and std.mem.eql(u8, r.name, "ammoGasCan")) {
            saw_ammo_range = r.count_min == 5000 and r.count_max == 10000;
        }
    }
    if (t.groupByName("ammoAll")) |g| {
        for (g.refs) |r| {
            if (r.prob < 1) saw_prob = true;
        }
    }
    try std.testing.expect(saw_ammo_range);
    try std.testing.expect(saw_prob);
}

test "trader table parses trader_info blocks with per-trader items and attrs" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/traders.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
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
    // Jen (2) is a different list from Joel (1): roll both with a seeded rng
    // and the first rolled names differ (Jen sells food, Joel armor).
    const jen = t.traderInfo(2).?;
    var outj: [128]RolledItem = undefined;
    var rng_j = rng_util.XorShift32.init(7);
    const ojn = t.rollAllRefs(jen.refs, &rng_j, &outj);
    try std.testing.expect(ojn > 0);
    var out_joel: [128]RolledItem = undefined;
    var rng_j2 = rng_util.XorShift32.init(7);
    const ojn2 = t.rollAllRefs(joel.refs, &rng_j2, &out_joel);
    try std.testing.expect(ojn2 > 0);
    try std.testing.expect(!std.mem.eql(u8, out_joel[0].name, outj[0].name));
}

test "roll stays deterministic and honours count ranges and unique_only" {
    const refs = [_]ItemRef{
        .{ .name = "ammoA", .count_min = 40, .count_max = 150 },
        .{ .name = "ammoB", .count_min = 1, .count_max = 1 },
        .{ .name = "gunA", .quality_lo = 2, .quality_hi = 6 },
    };
    var t = TraderTable.empty();
    var out: [16]RolledItem = undefined;
    var rng_a = rng_util.XorShift32.init(99);
    const n = t.rollAllRefs(&refs, &rng_a, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(out[0].count >= 40 and out[0].count <= 150);
    try std.testing.expectEqual(@as(u16, 1), out[1].count);
    try std.testing.expect(out[2].quality >= 2 and out[2].quality <= 6);
    // Same seed → same roll (deterministic sim input).
    var rng_b = rng_util.XorShift32.init(99);
    var out2: [16]RolledItem = undefined;
    const n2 = t.rollAllRefs(&refs, &rng_b, &out2);
    try std.testing.expectEqual(n, n2);
    for (out[0..n], out2[0..n2]) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqual(a.count, b.count);
        try std.testing.expectEqual(a.quality, b.quality);
    }
}

test "unique_only group picks distinct refs" {
    var arena_holder = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer {
        arena_holder.deinit();
        std.testing.allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();
    const items = [_]ItemRef{
        .{ .name = "modA", .prob = 100 },
        .{ .name = "modB", .prob = 100 },
        .{ .name = "modC", .prob = 100 },
    };
    const gname = arena.dupe(u8, "groupMods") catch return error.OutOfMemory;
    const g = Group{ .name = gname, .refs = &items, .count_min = 3, .count_max = 3, .unique_only = true };
    var t = TraderTable.empty();
    t.groups = &[_]Group{g};
    // The group ref: count=3 rounds × group count=3 picks = 9 picks from 3
    // items, unique → each item at most once per group roll, so at most 3
    // distinct names per roll and every name appears at most once per round.
    const refs = [_]ItemRef{.{ .name = gname, .group = true, .count_min = 3, .count_max = 3 }};
    var out: [16]RolledItem = undefined;
    var rng = rng_util.XorShift32.init(5);
    const n = t.rollAllRefs(&refs, &rng, &out);
    try std.testing.expect(n >= 3);
    var seen: [3]bool = .{false} ** 3;
    for (out[0..n]) |r| {
        if (std.mem.eql(u8, r.name, "modA")) seen[0] = true;
        if (std.mem.eql(u8, r.name, "modB")) seen[1] = true;
        if (std.mem.eql(u8, r.name, "modC")) seen[2] = true;
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2]);
}

test "trader_info scan survives adjacent blocks with no whitespace" {
    const xml_text =
        \\<traders>
        \\  <trader_item_group name="traderAlways"><item name="medicalBandage" count="3,5"/></trader_item_group>
        \\  <trader_info id="1" open_time="4:05" close_time="21:50"><trader_items><item name="armorParts"/></trader_items></trader_info><trader_info id="2" is_vending="true"><trader_items><item group="traderAlways"/></trader_items></trader_info>
        \\</traders>
    ;
    var arena_holder = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer {
        arena_holder.deinit();
        std.testing.allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();
    const clean = try xml.stripComments(std.testing.allocator, xml_text);
    defer std.testing.allocator.free(clean);
    var infos: std.ArrayList(TraderInfo) = .empty;
    defer infos.deinit(std.testing.allocator);
    var j: usize = 0;
    while (j < clean.len and infos.items.len < max_traders) {
        const ti = std.mem.findPos(u8, clean, j, "<trader_info ") orelse break;
        j = ti + 13;
        const idv = xml.attr(clean, ti, "id") orelse continue;
        const id = std.fmt.parseInt(u16, idv, 10) catch continue;
        const gt = std.mem.findPos(u8, clean, ti, ">") orelse break;
        const self_closing = gt > ti and clean[gt - 1] == '/';
        var refs: []const ItemRef = &.{};
        if (!self_closing) {
            const close = std.mem.findPos(u8, clean, gt, "</trader_info>") orelse break;
            refs = try parseRefsBody(arena, std.testing.allocator, clean[gt + 1 .. close]);
            j = close + "</trader_info>".len;
        }
        try infos.append(std.testing.allocator, .{ .id = id, .refs = refs });
    }
    try std.testing.expectEqual(@as(usize, 2), infos.items.len);
    try std.testing.expectEqual(@as(u16, 1), infos.items[0].id);
    try std.testing.expectEqual(@as(u16, 2), infos.items[1].id);
    try std.testing.expectEqual(@as(usize, 1), infos.items[0].refs.len);
}

test "traders root economy attributes parse (currency_item, markup)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/traders.xml", .{dir});
    try io_fs.writeFile(path, "<traders buy_markup=\"3\" sell_markdown=\"0.2\" currency_item=\"dukeCoin\" >\n" ++
        "  <trader_item_group name=\"groupTest\">\n" ++
        "    <item name=\"resourceWood\" count=\"10\"/>\n" ++
        "  </trader_item_group>\n" ++
        "  <trader_info id=\"1\" name=\"Joel\">\n" ++
        "    <trader_items>\n" ++
        "      <item name=\"resourceWood\" count=\"10\"/>\n" ++
        "    </trader_items>\n" ++
        "  </trader_info>\n" ++
        "</traders>\n");
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 3), t.buy_markup);
    try std.testing.expectEqual(@as(f32, 0.2), t.sell_markdown);
    try std.testing.expectEqualStrings("dukeCoin", t.currency_item);
    // Unset currency_item stays empty (Game falls back to the stock name).
    var p2: [std.fs.max_path_bytes]u8 = undefined;
    const path2 = try std.fmt.bufPrint(&p2, "{s}/traders2.xml", .{dir});
    try io_fs.writeFile(path2, "<traders buy_markup=\"2\" >\n" ++
        "  <trader_item_group name=\"groupTest\">\n" ++
        "    <item name=\"resourceWood\" count=\"1\"/>\n" ++
        "  </trader_item_group>\n" ++
        "  <trader_info id=\"1\" name=\"Joel\">\n" ++
        "    <trader_items><item name=\"resourceWood\" count=\"1\"/></trader_items>\n" ++
        "  </trader_info>\n" ++
        "</traders>\n");
    var t2 = try loadFromPath(std.testing.allocator, path2);
    defer t2.deinit();
    try std.testing.expectEqualStrings("", t2.currency_item);
}
