//! traders.xml: trader_item_groups, trader_info blocks, and the stock
//! inventory roll (TraderInfo::Spawn, asm.il 862758-863520).
//!
//! The roll is a faithful port of stock TraderInfo spawning: top-level refs
//! always spawn (SpawnAllItemsFromList), group members are picked
//! prob-weighted with dedupe (SpawnLootItemsFromList), counts roll uniform in
//! [min,max] (RandomSpawnCount), and quality rolls uniform in the entry's
//! quality range or, for the 653 stock refs that carry no `quality` attribute,
//! the QualityPolicy default range under the TraderMaxTier ceiling. The RNG is
//! caller-supplied and seeded, so the same
//! (world, trader, day) reproduces the same stock (sim rule: deterministic
//! inputs), unlike stock's per-ItemValue time-seeded GameRandom.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
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
    /// quality="lo,hi" roll bounds. -1/-1 = the attribute is absent, which is
    /// what stock `TradersFromXml::parseItemList` passes for minQualityBase /
    /// maxQualityBase (the `ldc.i4.m1` pair, TradersFromXml.il:558-563 and
    /// :790-792); `SpawnItem` substitutes the default range for those.
    quality_lo: i16 = -1,
    quality_hi: i16 = -1,
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

/// `ItemClass.HasQuality` for an items.xml name. The Game backs this with the
/// items table; null in offline tests means no item has quality, which keeps
/// every roll at the unset wire quality.
pub const HasQualityResolver = *const fn (ctx: ?*anyopaque, name: []const u8) bool;

/// The quality half of stock `TraderInfo::SpawnItem` (TraderInfo.il:876-905):
/// which items can carry quality at all, the fallback range for entries with
/// no `quality` attribute, and the `TraderMaxTier` ceiling. Carried from
/// `[rules.trader]` through the roll so nothing reads a global.
pub const QualityPolicy = struct {
    /// Stock `TraderInfo.TraderMaxTier` (static, ctor default 6): rolled
    /// quality clamps to it, `-1` disables the clamp, and `0` drops every
    /// quality-bearing item from the stock (SpawnItem IL_0011-0020).
    max_tier: i32 = 6,
    /// Substituted for a `quality`-less entry (stock parses those as -1/-1 and
    /// SpawnItem replaces the pair with 1..6).
    default_min: u8 = 1,
    default_max: u8 = 6,
    /// Per-name HasQuality lookup (null = nothing has quality).
    has_quality: ?HasQualityResolver = null,
    has_quality_ctx: ?*anyopaque = null,

    fn itemHasQuality(self: QualityPolicy, name: []const u8) bool {
        const resolve = self.has_quality orelse return false;
        return resolve(self.has_quality_ctx, name);
    }
};

/// Wire quality for an item stock says has no quality at all. Stock leaves the
/// ItemValue at its default tier and the client shows no quality bar.
const no_quality_wire: u8 = 1;

/// Price multipliers used when neither a `<trader_info>` override nor the
/// `<traders>` root row supplies one, which happens only with no game-dir
/// (the offline builtin catalog). Stock traders.xml ships both attributes, so
/// a real install always overrides these before they are read.
/// `default_buy_markup` 1.0 means "pay the item's economic value"; the sell
/// markdown is the stock root value.
pub const default_buy_markup: f32 = 1.0;
pub const default_sell_markdown: f32 = 0.02;

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
    /// Stock default when `rent_time` is omitted (traders.xml rentable rows
    /// write 30; Match stock `TraderInfo` ctor default).
    rent_time: i32 = 30,
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
    /// Root `quality_mod="min,max"` (stock "1,2"): the buy/sell price lerp
    /// for items with a quality tier, QL1 -> min, QL6 -> max (traders.xml
    /// comment; RE GetBuyPrice/GetSellPrice asm.il 1830625-1830948). 1,1 =
    /// no quality effect.
    quality_min_mod: f32 = 1,
    quality_max_mod: f32 = 1,
    /// Root `quest_tier_mod="0,0.05,…,0.3"` (stock): GetTraderStage scales
    /// the quest-reward loot stage by the quest tier, Level*(1+mod[tier-1])
    /// (RE progression.md GetTraderStage IL=46).
    quest_tier_mod: []const f32 = &.{},
    /// Root `currency_item` name (stock traders.xml: "casinoCoin"). Game pays
    /// trade/rent in this item; empty = the stock-name fallback.
    currency_item: []const u8 = "",
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *TraderTable) void {
        arena_util.destroyHolder(&self.arena_ptr);
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

    /// Row for a TraderID. Takes the i32 the data carries (blocks.xml
    /// `TraderID`, the vending save record) so an out-of-range value fails
    /// closed here instead of trapping in a narrowing cast at the call site.
    /// 0 is "not declared" (blocks.zig floors an absent TraderID to 0), so it
    /// resolves to no row even if traders.xml declares an id 0 block.
    pub fn traderInfo(self: *const TraderTable, id: i32) ?TraderInfo {
        if (id <= 0 or id > std.math.maxInt(u16)) return null;
        const want: u16 = @intCast(id);
        for (self.trader_infos) |ti| {
            if (ti.id == want) return ti;
        }
        return null;
    }

    /// Roll every ref in a list the way stock TraderInfo::Spawn does
    /// (SpawnAllItemsFromList, asm.il 863190): each ref always spawns, its
    /// count rolls in [min,max] and multiplies by the sandbox abundance
    /// (TraderItemAbundance for traders, VendingItemAbundance for vending;
    /// both 1.0 in the stock default), then `FastMax(1, ...)` floors it, and
    /// a group ref expands through spawnItemsFromGroup. Writes into out[];
    /// returns count written.
    pub fn rollAllRefs(self: *const TraderTable, refs: []const ItemRef, rng: *rng_util.XorShift32, policy: QualityPolicy, abundance: f32, out: []RolledItem) usize {
        var n: usize = 0;
        for (refs) |r| {
            const count = randomSpawnCount(rng, r.count_min, r.count_max);
            const count_final: i32 = @trunc(@max(1.0, @as(f32, @floatFromInt(count)) * abundance));
            if (r.group) {
                spawnItemsFromGroup(self, r.name, count_final, rng, r.unique_only, policy, out, &n, 0);
            } else {
                spawnItem(r, count_final, rng, policy, out, &n);
            }
        }
        return n;
    }

    /// Prob-weighted picks from a group's refs, stock
    /// SpawnLootItemsFromList (asm.il 863343): one RandomFloat per pick, walk
    /// the refs accumulating prob share, first ref whose share passes the
    /// roll is spawned and (when unique) removed from the pool.
    fn spawnLootItemsFromList(self: *const TraderTable, refs: []const ItemRef, num_to_spawn: i32, rng: *rng_util.XorShift32, used: ?[]bool, policy: QualityPolicy, out: []RolledItem, n: *usize, depth: usize) void {
        if (num_to_spawn < 0) {
            spawnAllRefs(self, refs, rng, policy, out, n, depth);
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
                    spawnItemsFromGroup(self, r.name, count, rng, r.unique_only, policy, out, n, depth);
                } else {
                    spawnItem(r, count, rng, policy, out, n);
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
    fn spawnAllRefs(self: *const TraderTable, refs: []const ItemRef, rng: *rng_util.XorShift32, policy: QualityPolicy, out: []RolledItem, n: *usize, depth: usize) void {
        for (refs) |r| {
            const count: i32 = @max(1, randomSpawnCount(rng, r.count_min, r.count_max));
            if (r.group) {
                spawnItemsFromGroup(self, r.name, count, rng, r.unique_only, policy, out, n, depth);
            } else {
                spawnItem(r, count, rng, policy, out, n);
            }
        }
    }

    /// Stock SpawnItemsFromGroup (asm.il 863290): num_to_spawn rounds, each
    /// rolling the group's own count and picking that many refs from it.
    fn spawnItemsFromGroup(self: *const TraderTable, group_name: []const u8, num_to_spawn: i32, rng: *rng_util.XorShift32, unique: bool, policy: QualityPolicy, out: []RolledItem, n: *usize, depth: usize) void {
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
            spawnLootItemsFromList(self, g.refs, picks, rng, used, policy, out, n, depth + 1);
        }
    }

    /// Stock TraderInfo::SpawnItem (TraderInfo.il:750): one stack with the
    /// rolled count and the entry's quality, in stock's order:
    ///   1. a quality-bearing item does not spawn at all when TraderMaxTier is
    ///      0 (IL_0011-0020);
    ///   2. an item with no quality skips the rest and keeps the wire default
    ///      (IL_014B-0151);
    ///   3. a `quality`-less entry (-1/-1) takes the policy default range,
    ///      stock 1..6 (IL_0156-015D);
    ///   4. maxQuality clamps to TraderMaxTier unless that is -1 (IL_015F-0175);
    ///   5. maxQuality below minQuality drops the item (IL_0177-017C);
    ///   6. otherwise quality rolls uniform in [min, max] (stock ItemValue ctor
    ///      RandomRange(min, max+1), asm.il 616396).
    /// A dropped item is never written to out[], so it does not occupy a stock
    /// slot. The roll only draws when it reaches step 6, keeping the seeded
    /// stream stable for entries that do not roll.
    fn spawnItem(r: ItemRef, count: i32, rng: *rng_util.XorShift32, policy: QualityPolicy, out: []RolledItem, n: *usize) void {
        if (count < 1 or n.* >= out.len) return;
        const has_quality = policy.itemHasQuality(r.name);
        if (has_quality and policy.max_tier == 0) return;
        var quality: u8 = no_quality_wire;
        if (has_quality) {
            var q_min: i32 = r.quality_lo;
            var q_max: i32 = r.quality_hi;
            if (q_min <= -1) {
                q_min = policy.default_min;
                q_max = policy.default_max;
            }
            if (policy.max_tier != -1 and q_max > policy.max_tier) q_max = policy.max_tier;
            if (q_max < q_min) return;
            const span: u32 = @intCast(q_max - q_min + 1);
            quality = @intCast(q_min + @as(i32, @intCast(rng.nextBounded(span))));
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

/// minQualityBase / maxQualityBase for an entry with no `quality` attribute.
const quality_unset: i16 = -1;

/// Largest quality a parsed bound may carry. Stock quality is an ItemValue
/// byte, so a modlet writing `quality="300"` cannot be represented on the
/// wire; clamping here keeps the roll inside the wire type when the
/// `max_tier` ceiling is disabled.
const quality_parse_max: i16 = 255;

/// quality="lo,hi" (both 1..6 in stock XML). An absent or unparsable attribute
/// yields stock's -1/-1 base pair (TradersFromXml.il:558-563), which SpawnItem
/// replaces with the policy default range.
fn parseQuality(v: []const u8) struct { i16, i16 } {
    if (v.len == 0) return .{ quality_unset, quality_unset };
    const comma = std.mem.findScalar(u8, v, ',') orelse {
        const q = std.fmt.parseInt(i16, v, 10) catch return .{ quality_unset, quality_unset };
        const c = clampQuality(q);
        return .{ c, c };
    };
    const lo = clampQuality(std.fmt.parseInt(i16, v[0..comma], 10) catch return .{ quality_unset, quality_unset });
    const hi = clampQuality(std.fmt.parseInt(i16, v[comma + 1 ..], 10) catch lo);
    return .{ lo, @max(lo, hi) };
}

/// Keep a declared bound inside the wire byte range, leaving any negative
/// value as the unset sentinel SpawnItem substitutes for.
fn clampQuality(q: i16) i16 {
    if (q < 0) return quality_unset;
    return @min(q, quality_parse_max);
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

pub fn parseRefsBody(arena: std.mem.Allocator, gpa: std.mem.Allocator, body: []const u8) ![]const ItemRef {
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

    const arena_holder = try arena_util.newArenaHolder(allocator);
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
    var root_quality_min: f32 = 1;
    var root_quality_max: f32 = 1;
    var root_quest_tier_mod: []const f32 = &.{};
    var root_currency: []const u8 = "";
    if (std.mem.findPos(u8, clean, 0, "<traders")) |tr| {
        if (xml.attr(clean, tr, "buy_markup")) |v| root_buy_markup = std.fmt.parseFloat(f32, v) catch 0;
        if (xml.attr(clean, tr, "sell_markdown")) |v| root_sell_markdown = std.fmt.parseFloat(f32, v) catch 0;
        if (xml.attr(clean, tr, "currency_item")) |v| root_currency = try arena.dupe(u8, v);
        if (xml.attr(clean, tr, "quest_tier_mod")) |v| {
            var qtm: std.ArrayList(f32) = .empty;
            defer qtm.deinit(allocator);
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |tok| {
                const t = std.mem.trim(u8, tok, " \t");
                if (t.len == 0) continue;
                qtm.append(allocator, std.fmt.parseFloat(f32, t) catch 0) catch break;
            }
            root_quest_tier_mod = try arena.dupe(f32, qtm.items);
        }
        if (xml.attr(clean, tr, "quality_mod")) |qm| {
            if (std.mem.cutScalar(u8, qm, ',')) |parts| {
                root_quality_min = std.fmt.parseFloat(f32, std.mem.trim(u8, parts[0], " \t")) catch 1;
                root_quality_max = std.fmt.parseFloat(f32, std.mem.trim(u8, parts[1], " \t")) catch 1;
            }
        }
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
            .rent_time = if (rent_time_v.len > 0) std.fmt.parseInt(i32, rent_time_v, 10) catch 30 else 30,
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
        .quality_min_mod = root_quality_min,
        .quality_max_mod = root_quality_max,
        .quest_tier_mod = root_quest_tier_mod,
        .sell_markdown = root_sell_markdown,
        .currency_item = root_currency,
        .arena_ptr = arena_holder,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?TraderTable {
    return paths.tryLoadConfig("traders.xml", TraderTable, loadFromPath, allocator, game_dir, config_dir);
}
