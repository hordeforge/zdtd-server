//! Item gamestage stats: `<stat>` row shape, stock FindGSStat/AddGSStats
//! roll (ItemClass IL=90/100), and the wire pair shape.
//!
//! Split out of items.zig (same code, moved verbatim); re-exported
//! through the items facade so existing `assets_items.GsStat` call
//! sites keep working.

const std = @import("std");
const passive_effects = @import("passive_effects.zig");
const game_random = @import("../util/game_random.zig");

pub const max_gs_stats_per_item: usize = 64;
pub const max_gs_stats_total: usize = 4096;

/// Stock `ItemClass/GSStat` (`min`/`max` are the XML values divided by
/// `gs_stat_scale` and stored as i16, so the XML precision is 1/200).
pub const gs_stat_scale: f32 = 0.005;
/// Stock rejects a row whose |min| or |max| reaches this (GSStatsParseXml
/// IL_0134-0147) instead of letting the i16 cast overflow.
pub const gs_stat_limit: f32 = 163.835;

/// One `<stat name="..." value="quality,gameStage,chance,min,max"/>` row of an
/// item's `<stats>` block (stock `ItemClass::GSStatsParseXml` IL=181). The
/// effect stays a name: zdtd keys passive effects by name, and the wire's
/// numeric id is resolved where the stat is written.
pub const GsStat = struct {
    effect: []const u8 = "",
    quality: i16 = 0,
    game_stage: i16 = 0,
    chance: f32 = 0,
    min: i16 = 0,
    max: i16 = 0,
};

/// One rolled stat entry in the wire pair shape (`slot_a`/`slot_b`; stock's
/// `Stat` ctor makes `isBoosted = slot_b > 0`, and the writer emits
/// `slotA = isBoosted ? 0 : value`, `slotB = isBoosted ? value : 0`).
pub const RolledGsStat = struct {
    /// `PassiveEffects` ordinal (`assets/passive_effects.zig`).
    effect: u8 = 0,
    slot_a: i16 = 0,
    slot_b: i16 = 0,
};

/// One `FindGSStat` (stock `ItemClass::FindGSStat` IL=90) over the rows of one
/// effect: the highest-stage row at or below `stage` whose `chance` gate
/// passes. Null is stock's "not found" sentinel (the returned `quality == -1`),
/// which the caller distinguishes from a real row by the quality it asks for.
/// The RNG draw happens only when the matched row's `chance < 1`.
fn findGsStat(
    stats: []const GsStat,
    effect: []const u8,
    quality: i32,
    stage_in: i32,
    r: *game_random.GameRandom,
) ?GsStat {
    var stage = stage_in;
    if (stage < 0) {
        // Trader path: the stage comes from the first row of that quality.
        for (stats) |s| {
            if (!std.mem.eql(u8, s.effect, effect)) continue;
            if (@as(i32, s.quality) == quality) {
                stage = s.game_stage;
                break;
            }
        }
    }
    var best: i32 = -1;
    var i: usize = stats.len;
    while (i > 0) {
        i -= 1;
        const s = stats[i];
        if (!std.mem.eql(u8, s.effect, effect)) continue;
        if (@as(i32, s.quality) != quality) continue;
        const cur: i32 = s.game_stage;
        if (cur > stage) continue;
        if (best < 0) {
            best = cur;
        } else if (cur < best) {
            return null; // stock breaks out of the loop to its sentinel
        }
        if (s.chance < 1) {
            const roll: f32 = @floatCast(r.nextDouble());
            if (!(s.chance > roll)) continue;
        }
        return s;
    }
    return null;
}

/// Stock `ItemClass::AddGSStats` (IL=100): one entry per distinct effect at
/// `quality`/`stage`, drawing from `r` in stock's exact order - the base roll
/// (`FindGSStat(list, 0, 0, r)` then `RandomRange(min, max+1)`), then the
/// quality roll (`FindGSStat(list, quality, stage, r)`). The result is the
/// summed value split by `isBoosted = added > 0`, and an entry whose sum is 0
/// is dropped (stock's `RemoveUnusedStats`). An effect name the enum does not
/// know is skipped (the wire has no id for it).
pub fn rollGsStats(
    stats: []const GsStat,
    quality: u8,
    stage: i32,
    r: *game_random.GameRandom,
    out: []RolledGsStat,
) usize {
    var n: usize = 0;
    for (stats, 0..) |s, idx| {
        // First-occurrence order, and one entry per effect (stock's dictionary).
        var seen = false;
        for (stats[0..idx]) |prev| {
            if (std.mem.eql(u8, prev.effect, s.effect)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        var base: i32 = 0;
        if (findGsStat(stats, s.effect, 0, 0, r)) |g0| {
            if (g0.max >= g0.min) base = r.nextRange(g0.min, @as(i32, g0.max) + 1);
        }
        var added: i32 = 0;
        if (findGsStat(stats, s.effect, quality, stage, r)) |g1| {
            if (g1.quality > 0 and g1.max >= g1.min) {
                added = r.nextRange(g1.min, @as(i32, g1.max) + 1);
            }
        }
        if (base + added == 0) continue;
        const ordinal = passive_effects.idOfName(s.effect) orelse continue;
        if (n >= out.len) break;
        // Stock casts the sum to i16 with a wrapping `conv.i2`.
        const value: i16 = @truncate(base + added);
        out[n] = .{
            .effect = ordinal,
            .slot_a = if (added > 0) 0 else value,
            .slot_b = if (added > 0) value else 0,
        };
        n += 1;
    }
    return n;
}
