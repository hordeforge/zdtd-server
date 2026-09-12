//! loot.xml loader: groups + containers, simple deterministic rolls.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const requirements = @import("requirements.zig");
const sandbox = @import("sandbox.zig");
const io_fs = @import("../util/io_fs.zig");

// zdtd storage bounds, not stock rules; stock caps neither. Measured against
// V3.2.0 `Data/Config` (2026-09-04): loot.xml defines 1015 lootgroups (50% of
// the cap) and 339 lootcontainers (66%). Both parse loops stop at the cap.
pub const max_groups: usize = 2048;
pub const max_containers: usize = 512;
/// Widest stock group (perkBooks has 133 entries); the cap must not truncate.
pub const max_entries: usize = 192;
pub const max_roll_stacks: usize = 8;

pub const LootEntry = struct {
    /// Item name or nested group name.
    name: []const u8 = "",
    is_group: bool = false,
    count_min: u16 = 1,
    count_max: u16 = 1,
    /// Probability weight (1.0 = always considered in equal pick).
    prob: f32 = 1,
    /// loot_prob_template index + 1 into LootTable.prob_templates; 0 = none.
    /// Resolved at load so the roll path never compares template names.
    prob_template: u16 = 0,
    /// force_prob="true": the entry rolls its prob independently instead of
    /// joining the group's pick pool (stock SpawnAllItemsFromList /
    /// SpawnLootItemsFromList forceProb branch, asm.il 698816).
    force_prob: bool = false,
    /// `random_durability="true"` (123 stock entries, all explicitly false, so
    /// this is engine/modlet support): the spawned item starts 20-80% worn.
    random_durability: bool = false,
    /// `buffs=` (63 stock entries, `buffPerkBookwormSuccess`): buffs added to
    /// the opener when this entry spawns (`LootContainer` collects the list and
    /// `ExecuteBuffActions` applies them). Arena-owned comma list.
    buffs: []const u8 = "",
    /// `loot_stage_count_mod` (84 stock entries, all `0.01` on ammo rows): the
    /// count grows with the loot stage. `LootContainer` IL_017F adds
    /// `RoundToInt(count * mod * lootStage)` to the sandbox-scaled count, so a
    /// stage-50 ammo roll of 6..8 spawns roughly 9..12. 0 = no stage growth.
    loot_stage_count_mod: f32 = 0,
    /// `quality="N"`: the fixed quality this entry spawns at, overriding the
    /// loot quality template. Engine support from `ParseItemList` (which seeds
    /// minQuality/maxQuality from the caller and lets a `quality` attribute
    /// override them); stock's own loot.xml writes `quality` only on the
    /// `<loot>` rows inside `<lootqualitytemplate>`, so every stock item entry
    /// keeps 0 and uses the template roll. A modlet entry can pin one value.
    quality: u8 = 0,
    /// The entry's `<requirement>` child (loot.xml's `LootEntryRequirement*`
    /// leaves). A class the roll path can answer resolves; everything else
    /// keeps the entry **omitted** rather than rolled unconditionally -
    /// "missing beats fake" applies to loot too, and stock's own gate refuses
    /// for a player without the perk/cvar (round 16: an ignored
    /// `RandomRoll @$perkBookwormChance` put a book in every Working Stiffs
    /// crate). The requirements stay on the row for the evaluator this needs.
    gate: EntryGate = .{},
};

/// One entry's roll-time gate. `none` = ungated; `biome` = the
/// `LootEntryRequirementBiome` name list (the roll path carries the container's
/// biome); `progression` / `cvar` / `random_roll` = the classes the roll path
/// can answer from the opener's requirement context; `other` = a class whose
/// state the roll path does not carry (`SandboxOption`, `QuestTags`), so the
/// entry is omitted.
pub const GateKind = enum { none, biome, progression, cvar, random_roll, sandbox, other };

pub const EntryGate = struct {
    kind: GateKind = .none,
    /// `Biome` requirement `biomes="a,b"` (arena-owned).
    biomes: []const u8 = "",
    /// `Progression name=` / `CVar cvar=` operand (arena-owned).
    arg: []const u8 = "",
    /// `operation=` on every class (stock `RequirementBase::compareValues`).
    op: requirements.Compare = .eq,
    /// Literal right-hand `value=`.
    value: f32 = 0,
    /// `value="@$name"`: the right-hand side is the entity's custom variable at
    /// roll time (a missing name reads 0, like `EntityBuffs::GetCustomVar`).
    value_cvar: []const u8 = "",
    /// `RandomRoll min_max="a,b"`: the roll's inclusive float range.
    min_max: [2]f32 = .{ 0, 100 },

    pub fn allowed(self: EntryGate, ctx: LootGateCtx) bool {
        switch (self.kind) {
            .none => return true,
            .biome => {
                const here = ctx.biome_name orelse return false;
                var it = std.mem.splitScalar(u8, self.biomes, ',');
                while (it.next()) |raw| {
                    const nm = std.mem.trim(u8, raw, " \t");
                    if (nm.len > 0 and std.mem.eql(u8, nm, here)) return true;
                }
                return false;
            },
            .progression => {
                // `LootEntryRequirementProgression` reads the opener's level of
                // `name`; stock's ProgressionLevel refuses when the target has
                // no such value, so an unknown name fails the gate.
                const player = ctx.player orelse return false;
                const r = requirements.Requirement{
                    .kind = .progression_level,
                    .arg = self.arg,
                    .op = self.op,
                    .value = self.value,
                };
                return requirements.all(&[_]requirements.Requirement{r}, player);
            },
            .cvar => {
                const player = ctx.player orelse return false;
                const r = requirements.Requirement{
                    .kind = .cvar_compare,
                    .arg = self.arg,
                    .op = self.op,
                    .value = self.value,
                };
                return requirements.all(&[_]requirements.Requirement{r}, player);
            },
            .random_roll => {
                // Stock `LootEntryRequirementRandomRoll`: LeftSide =
                // Lerp(minMax.x, minMax.y, RandomFloat), RightSide =
                // GetFloatValue(opener, value, 0). The roll comes from the
                // roll path's deterministic stream (ctx.roll), so a re-roll
                // with the same seed is reproducible (rule 22).
                const player = ctx.player orelse return false;
                const left = self.min_max[0] + (self.min_max[1] - self.min_max[0]) * ctx.roll;
                const right = if (self.value_cvar.len > 0)
                    requirements.cvarValue(player, self.value_cvar)
                else
                    self.value;
                return requirements.compare(left, self.op, right);
            },
            .sandbox => {
                // `LootEntryRequirementSandboxOption`: the option's value under
                // the server's decoded sandbox code, compared numerically. The
                // requirement's `operation`/`value` are the compare (stock's
                // `HarvestingOutput EQ 0` means "output disabled"), which a
                // boolean-truthiness test would invert.
                const player = ctx.player orelse return false;
                const o = sandbox.optionByName(self.arg) orelse return false;
                const set = sandbox.findSet(o.set_name) orelse return false;
                var v: f32 = switch (o.kind) {
                    .boolean => if (o.default_i != 0) 1 else 0,
                    .int => @floatFromInt(o.default_i),
                    .float => o.default_f,
                };
                for (player.sandbox_groups) |g| {
                    if (g.option_id != o.id) continue;
                    v = switch (o.kind) {
                        .boolean => if (sandbox.valueB(o, g.index)) 1 else 0,
                        .int => @floatFromInt(sandbox.valueI(o, set, g.index)),
                        .float => sandbox.valueF(o, set, g.index),
                    };
                    break;
                }
                return requirements.compare(v, self.op, self.value);
            },
            .other => return false,
        }
    }
};

/// Roll-time state a loot entry gate can read. `biome_name` is the biome the
/// container/roll sits in, resolved from biomes.xml (`biome_layers.nameById`);
/// null means the caller has no biome, so a biome-gated entry is omitted.
/// `player` is the opener's requirement context (levels + cvars); null means
/// no opener state was available, so a Progression/CVar/RandomRoll gate refuses
/// and the entry stays omitted rather than rolling unconditionally.
/// Where a spawned entry's `buffs=` list goes. Stock collects the list during
/// the roll (`SpawnItemsFromList` AddRange) and applies it to the opener after
/// (`LootContainer.ExecuteBuffActions` -> `Buffs.AddBuff`). The sink keeps the
/// loot table Game-free: the fill path owns the entity and applies the buff.
pub const LootBuffSink = struct {
    ctx: ?*anyopaque = null,
    add: *const fn (?*anyopaque, name: []const u8) void,
};

pub const LootGateCtx = struct {
    biome_name: ?[]const u8 = null,
    player: ?requirements.Ctx = null,
    /// Reports the `buffs=` of every entry that actually spawned.
    buffs: ?LootBuffSink = null,
    /// [0,1) value for this entry's `RandomRoll`; the roll path advances a
    /// deterministic per-entry stream into it.
    roll: f32 = 0,
};

/// [0,1) from the roll stream's top 24 bits (the `RandomRoll` value).
fn unitRoll(s: u32) f32 {
    return @as(f32, @floatFromInt(s >> 8)) / 16777216.0;
}

/// `AbundanceLootModTypes` name (lootgroup `abundance_type=`) -> the sandbox
/// option that carries that category's count modifier (RE loot-economy.md 8.3,
/// `GetCountMultiplierFromSandbox`; the option names are the stock
/// `*LootCount` sandbox options).
fn abundanceOptionName(type_name: []const u8) ?[]const u8 {
    const pairs = .{
        .{ "Food", "FoodLootCount" },
        .{ "Drinks", "DrinkLootCount" },
        .{ "Ammo", "AmmoLootCount" },
        .{ "Meds", "MedicalLootCount" },
        .{ "Resources", "ResourceLootCount" },
        .{ "Armor", "ArmorLootCount" },
        .{ "Melee", "MeleeLootCount" },
        .{ "Ranged", "RangedLootCount" },
        .{ "Dukes", "DukesLootCount" },
        .{ "Magazines", "CraftingMagazinesLootCount" },
        .{ "Books", "BookLootCount" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, type_name, pair[0])) return pair[1];
    }
    return null;
}

/// Report one spawned entry's `buffs=` list to the sink (comma-separated, the
/// same shape `ModifyCVar`-style lists use). Unknown names are the caller's
/// problem: the Game's add fails closed, which is stock's behaviour for the
/// one typo'd stock row (`buffbuffPerkBookwormSuccess`).
fn reportBuffs(ctx: LootGateCtx, e: LootEntry) void {
    const sink = ctx.buffs orelse return;
    if (e.buffs.len == 0) return;
    var it = std.mem.splitScalar(u8, e.buffs, ',');
    while (it.next()) |raw| {
        const nm = std.mem.trim(u8, raw, " \t");
        if (nm.len > 0) sink.add(sink.ctx, nm);
    }
}

/// A group's `abundance_type` count multiplier. 1.0 when the group has no type,
/// the category is unknown, or the roll has no sandbox ctx (RE returns -1 for
/// an unknown type, which the caller reads as "do not scale").
fn groupAbundanceFactor(ctx: LootGateCtx, g: *const LootGroup) f32 {
    if (g.abundance_type.len == 0) return 1.0;
    const opt_name = abundanceOptionName(g.abundance_type) orelse return 1.0;
    const player = ctx.player orelse return 1.0;
    const o = sandbox.optionByName(opt_name) orelse return 1.0;
    const set = sandbox.findSet(o.set_name) orelse return 1.0;
    var v: f32 = switch (o.kind) {
        .boolean => if (o.default_i != 0) 1 else 0,
        .int => @floatFromInt(o.default_i),
        .float => o.default_f,
    };
    for (player.sandbox_groups) |grp| {
        if (grp.option_id != o.id) continue;
        v = switch (o.kind) {
            .boolean => if (sandbox.valueB(o, grp.index)) 1 else 0,
            .int => @floatFromInt(sandbox.valueI(o, set, grp.index)),
            .float => sandbox.valueF(o, set, grp.index),
        };
        break;
    }
    return if (v < 0) 1.0 else v;
}

/// One `<loot level="a,b" prob="p"/>` row of a `<lootprobtemplate>`.
pub const ProbBand = struct {
    min_level: i32 = 0,
    max_level: i32 = 0,
    prob: f32 = 0,
};

pub const ProbTemplate = struct {
    name: []const u8 = "",
    bands: []const ProbBand = &.{},
};

pub const LootGroup = struct {
    name: []const u8 = "",
    /// How many entries to pick (min,max).
    pick_min: u8 = 1,
    pick_max: u8 = 1,
    /// loot_quality_template name; empty = inherit the container's.
    quality_template: []const u8 = "",
    /// count="all": every entry spawns once (stock -1 sentinel →
    /// SpawnAllItemsFromList; regular prob is ignored, force_prob gates).
    pick_all: bool = false,
    /// `abundance_type` (67 stock groups: Armor/Books/Magazines/Melee/Ranged):
    /// `AbundanceLootModTypes` category whose sandbox count modifier scales this
    /// group's counts (RE loot-economy.md 8.3, `LoadLootGroup` parses it).
    abundance_type: []const u8 = "",
    entries: [max_entries]LootEntry = [_]LootEntry{.{}} ** max_entries,
    entry_n: u8 = 0,
};

pub const LootContainer = struct {
    name: []const u8 = "",
    size_x: u8 = 8,
    size_y: u8 = 6,
    /// loot_quality_template name (stock every container carries one).
    quality_template: []const u8 = "",
    /// destroy_on_close: 0 none, 1 "true" (destroy on unlock always), 2
    /// "empty" (destroy on unlock only when emptied). Stock
    /// TEFeatureStorage.ShouldDestroyOnClose (IL=19) + CheckDestroyTileEntity
    /// (IL=37, loot-economy.md 454-456).
    destroy_on_close: u8 = 0,
    /// ignore_loot_abundance="true" (65 stock containers, twitch-only in b14):
    /// counts roll unmodified by the global LootAbundance setting.
    ignore_abundance: bool = false,
    /// unique_item="true" (stock questRewardSkillMagazines): each entry rolls
    /// at most once per fill (no duplicate magazines).
    unique_item: bool = false,
    /// unmodified_lootstage="true": roll at the raw stage, skipping the
    /// container's stage-modifier chain. Parsed and deliberately not applied:
    /// all 65 stock containers carrying it are `twitch_*`, placed only by the
    /// Twitch integration this server does not implement, so no reachable
    /// container is affected. Wire it into `rollContainer` if a modlet ever
    /// sets the attribute on a normal container.
    raw_lootstage: bool = false,
    /// open_time seconds the container stays open (190 stock; client
    /// display). Parsed; not consumed server-side.
    open_time: f32 = 0,
    entries: [max_entries]LootEntry = [_]LootEntry{.{}} ** max_entries,
    entry_n: u8 = 0,
};

pub const Stack = struct {
    item_name: []const u8 = "",
    count: u16 = 0,
    /// Rolled ItemValue quality (loot_quality_template by loot stage); 1 for
    /// stackables without a quality tier.
    quality: u8 = 1,
    /// `random_durability="true"` on the entry: the spawned item starts worn
    /// (`LootContainer` sets `UseTimes = (int)(MaxUseTimes * RandomRange(0.2,
    /// 0.8))`). The fill path owns the item's MaxUseTimes, so it resolves the
    /// value from this flag plus the roll seed.
    random_durability: bool = false,
};

/// Stock random durability for one spawned item (`LootContainer` IL_032D):
/// `(int)(max_use * RandomRange(0.2, 0.8))`. 0 max (no durability) stays 0.
pub fn randomUseTimes(max_use: u32, s: u32) f32 {
    if (max_use == 0) return 0;
    const f = 0.2 + 0.6 * unitRoll(s);
    return @floatFromInt(@as(u32, @intFromFloat(@as(f32, @floatFromInt(max_use)) * f)));
}

/// One quality-template level band: the loot stage window, the fallback
/// quality when no pick passes, and the prob-weighted quality picks.
pub const QualityPick = struct { quality: u8, prob: f32 };
pub const QualityBand = struct {
    min_level: i32 = 0,
    max_level: i32 = 999999,
    default_quality: u8 = 1,
    picks: []const QualityPick = &.{},
};
pub const QualityTemplate = struct {
    name: []const u8 = "",
    bands: []const QualityBand = &.{},
};

pub const LootTable = struct {
    groups: []const LootGroup = &.{},
    containers: []const LootContainer = &.{},
    prob_templates: []const ProbTemplate = &.{},
    quality_templates: []const QualityTemplate = &.{},
    /// `<loot_settings poi_tier_mod= poi_tier_bonus=>`: LootManager::POITierMod /
    /// POITierBonus, indexed by Prefab.DifficultyTier-1 (asm.il GetLootStage
    /// ~504240). Empty until a caller knows the POI it is standing in.
    poi_tier_mod: []const f32 = &.{},
    poi_tier_bonus: []const f32 = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,
    /// LootAbundance percent (serverconfig); scales rolled stack counts. 100 = 1×.
    abundance_pct: u16 = 100,

    /// LootContainer::getProbability (asm.il ~699478): a loot_prob_template
    /// replaces the entry's own prob with the band covering `loot_stage`.
    /// A template with no covering band falls back to the entry prob, exactly
    /// as the IL falls through its band loop.
    pub fn entryProb(self: *const LootTable, e: LootEntry, loot_stage: i32) f32 {
        if (e.prob_template == 0) return e.prob;
        const idx = e.prob_template - 1;
        if (idx >= self.prob_templates.len) return e.prob;
        for (self.prob_templates[idx].bands) |b| {
            if (loot_stage >= b.min_level and loot_stage <= b.max_level) return b.prob;
        }
        return e.prob;
    }

    /// Fixed-point milli-prob gate so the roll stays integer-only (DST replay).
    /// `s` is the caller's already-advanced LCG state.
    /// Resolve the looted item quality from a loot_quality_template by loot
    /// stage (stock SpawnItem quality-template branch, asm.il 698080): the
    /// first band whose level window contains the stage, then the first pick
    /// whose prob the roll beats, else the band default.
    pub fn resolveQuality(self: *const LootTable, template_name: []const u8, loot_stage: i32, s: u32) u8 {
        if (template_name.len == 0) return 1;
        for (self.quality_templates) |qt| {
            if (!std.mem.eql(u8, qt.name, template_name)) continue;
            for (qt.bands) |band| {
                if (loot_stage < band.min_level or loot_stage > band.max_level) continue;
                const roll: u32 = (s >> 16) % 1000;
                for (band.picks) |p| {
                    if (p.prob <= 0) continue;
                    const thresh: u32 = @round(p.prob * 1000.0);
                    if (roll <= thresh) return p.quality;
                }
                return band.default_quality;
            }
            return 1;
        }
        return 1;
    }

    /// The loot-stage count growth of one entry (`LootContainer` IL_017F):
    /// `count + RoundToInt(count * lootstageCountMod * lootStage)`. Applied
    /// after the abundance/category scale, like stock.
    fn stageCount(self: *const LootTable, cnt: u16, e: LootEntry, loot_stage: i32) u16 {
        _ = self;
        if (e.loot_stage_count_mod == 0 or loot_stage <= 0 or cnt == 0) return cnt;
        const extra = @round(@as(f32, @floatFromInt(cnt)) * e.loot_stage_count_mod * @as(f32, @floatFromInt(loot_stage)));
        if (!(extra > 0)) return cnt;
        const total = @as(u32, cnt) + @as(u32, @intFromFloat(extra));
        return @intCast(@min(total, std.math.maxInt(u16)));
    }

    fn probGate(self: *const LootTable, e: LootEntry, loot_stage: i32, s: u32) bool {
        const p = self.entryProb(e, loot_stage);
        // A NaN prob (crafted/patched loot.xml) fails both comparisons below and
        // the NaN→int conversion in `@round` traps; fail closed to match the C#
        // unchecked cast (NaN rounds to 0, i.e. never picked).
        if (!std.math.isFinite(p)) return false;
        if (p >= 1.0) return true;
        if (p <= 0.0) return false;
        const thresh: u32 = @round(p * 1000.0);
        return (s % 1000) <= thresh;
    }

    /// Scale a rolled count by LootAbundance and the group's `abundance_type`
    /// category modifier, keeping at least 1. Containers with
    /// ignore_loot_abundance="true" pass apply=false (stock LootAbundance skips
    /// those; twitch-only carriers in b14). `mult` is the category multiplier
    /// from `groupAbundanceFactor`; 0 means the category is disabled, which
    /// spawns none of it (RE loot-economy.md 8.3: `abundance *= mult` before
    /// RandomSpawnCount), so the caller drops the stack.
    fn scaleCount(self: *const LootTable, cnt: u16, apply_abundance: bool, mult: f32) u16 {
        if (mult <= 0) return 0;
        if (!apply_abundance or (self.abundance_pct == 100 and mult == 1.0)) return @max(cnt, 1);
        const pct: f32 = @as(f32, @floatFromInt(self.abundance_pct)) * mult;
        const pct_i: u32 = @intFromFloat(@max(0, @min(pct, 65535.0)));
        const scaled = (@as(u32, cnt) * pct_i) / 100;
        // Clamp before the cast: a modded loot.xml count with a high
        // LootAbundance (stock range 1..1000) can exceed u16; saturate at
        // the stack cap rather than trapping the roll.
        return @intCast(@max(1, @min(scaled, std.math.maxInt(u16))));
    }

    pub fn deinit(self: *LootTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() LootTable {
        return .{
            .groups = &builtin_groups,
            .containers = &builtin_containers,
            .source = .builtin,
        };
    }

    pub fn groupByName(self: *const LootTable, name: []const u8) ?*const LootGroup {
        for (self.groups) |*g| {
            if (std.mem.eql(u8, g.name, name)) return g;
        }
        return null;
    }

    pub fn containerByName(self: *const LootTable, name: []const u8) ?*const LootContainer {
        for (self.containers) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    /// Roll a LootItem reward from a group (quests.xml `<reward type="LootItem"
    /// id="groupX" value="N" ischosen="true" isfixed="..."/>`): `picks` entries
    /// prob-weighted (uniform when all weights equal), or the first `picks`
    /// entries when `is_fixed` (deterministic). Stage bands still gate each
    /// entry. Returns the stack count.
    pub fn rollGroupPicks(self: *const LootTable, name: []const u8, loot_stage: i32, seed: u32, picks: u8, is_fixed: bool, out: []Stack, ctx: LootGateCtx) usize {
        const g = self.groupByName(name) orelse return 0;
        if (g.entry_n == 0 or picks == 0 or out.len == 0) return 0;
        const qt = g.quality_template;
        const mult = groupAbundanceFactor(ctx, g);
        var n: usize = 0;
        var s = seed;
        if (is_fixed) {
            var i: u8 = 0;
            while (i < g.entry_n and n < picks and n < out.len) : (i += 1) {
                const e = g.entries[i];
                var gctx = ctx;
                gctx.roll = unitRoll(s ^ @as(u32, i));
                if (!e.gate.allowed(gctx)) continue;
                if (e.is_group) {
                    reportBuffs(gctx, e);
                    n += self.rollGroup(e.name, loot_stage, s ^ @as(u32, i), out[n..], 1, qt, ctx);
                } else {
                    const cnt = self.stageCount(self.scaleCount(if (e.count_min > 0) e.count_min else 1, true, mult), e, loot_stage);
                    if (cnt == 0) continue; // disabled category spawns none
                    out[n] = .{
                        .item_name = e.name,
                        .count = cnt,
                        .quality = if (e.quality > 0) e.quality else self.resolveQuality(qt, loot_stage, s ^ @as(u32, i)),
                        .random_durability = e.random_durability,
                    };
                    n += 1;
                }
            }
            return n;
        }
        // Prob-weighted picks (stock ischosen reward selection): each pick
        // sums the entry weights, rolls a weighted index and gates the band.
        var p: u8 = 0;
        while (p < picks and n < out.len) : (p += 1) {
            s = s *% 1103515245 +% 12345;
            var total: u32 = 0;
            var e: u8 = 0;
            while (e < g.entry_n) : (e += 1) {
                total +|= pickWeight(g.entries[e].prob);
            }
            if (total == 0) break;
            const roll = s % total;
            var chosen: u8 = 0;
            var acc: u32 = 0;
            while (chosen < g.entry_n) : (chosen += 1) {
                acc +|= pickWeight(g.entries[chosen].prob);
                if (roll < acc) break;
            }
            if (chosen >= g.entry_n) chosen = g.entry_n - 1;
            const picked = g.entries[chosen];
            var gctx = ctx;
            gctx.roll = unitRoll(s);
            if (!picked.gate.allowed(gctx)) continue;
            if (picked.force_prob) {
                if (!self.probGate(picked, loot_stage, s)) {
                    continue;
                }
            } else if (picked.prob_template != 0 and !self.probGate(picked, loot_stage, s)) continue;
            reportBuffs(gctx, picked);
            if (picked.is_group) {
                n += self.rollGroup(picked.name, loot_stage, s, out[n..], 1, qt, ctx);
            } else {
                const cmin = picked.count_min;
                const cmax = if (picked.count_max >= cmin) picked.count_max else cmin;
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt0: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                const cnt = self.stageCount(self.scaleCount(cnt0, true, mult), picked, loot_stage);
                if (cnt == 0) continue; // disabled category spawns none
                out[n] = .{
                    .item_name = picked.name,
                    .count = cnt,
                    .quality = if (picked.quality > 0) picked.quality else self.resolveQuality(qt, loot_stage, s),
                    .random_durability = picked.random_durability,
                };
                n += 1;
            }
        }
        return n;
    }

    /// Deterministic roll into `out` at `loot_stage`. Returns stack count.
    /// Pass 1 for "no gamestage information"; the templates' first band starts
    /// at level 0 or 1, so stage 1 is the honest floor, not a magic value.
    pub fn rollContainer(self: *const LootTable, name: []const u8, loot_stage: i32, seed: u32, out: []Stack, ctx: LootGateCtx) usize {
        const cont = self.containerByName(name) orelse {
            // Unknown: try as group name.
            return self.rollGroup(name, loot_stage, seed, out, 0, "", ctx);
        };
        var n: usize = 0;
        var s = seed ^ 0x9e3779b9;
        var i: u8 = 0;
        while (i < cont.entry_n and n < out.len) : (i += 1) {
            const e = cont.entries[i];
            var gctx = ctx;
            gctx.roll = unitRoll(s ^ @as(u32, i));
            if (!e.gate.allowed(gctx)) continue;
            s = s *% 1103515245 +% 12345;
            // Every entry rolls its own prob (stock LootContainer.roll): a
            // force_prob entry gates independently (stock forceProb branch)
            // and a plain entry gates on its prob the same way. The old
            // index-0-always exception is gone - it was data-benign (0 of the
            // 339 stock containers have a plain first entry with prob < 1)
            // but wrong for hypothetical data.
            const gate = !self.probGate(e, loot_stage, s);
            if (gate) continue;
            if (e.is_group) {
                n += self.rollGroup(e.name, loot_stage, s, out[n..], 0, cont.quality_template, ctx);
            } else {
                const cmin = e.count_min;
                const cmax = if (e.count_max >= cmin) e.count_max else cmin;
                // Full-domain ranges (0..65535) make the u16 span arithmetic
                // overflow; widen so the modulo never sees a wrapped zero.
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                // unique_item="true": each entry rolls at most once per fill
                // (stock questRewardSkillMagazines: no duplicate magazines).
                if (cont.unique_item) {
                    var dup = false;
                    for (out[0..n]) |st| {
                        if (st.item_name.len > 0 and std.mem.eql(u8, st.item_name, e.name)) {
                            dup = true;
                            break;
                        }
                    }
                    if (dup) continue;
                }
                reportBuffs(ctx, e);
                out[n] = .{
                    .item_name = e.name,
                    .count = self.stageCount(self.scaleCount(cnt, !cont.ignore_abundance, 1.0), e, loot_stage),
                    .quality = if (e.quality > 0) e.quality else self.resolveQuality(cont.quality_template, loot_stage, s),
                    .random_durability = e.random_durability,
                };
                n += 1;
            }
        }
        // Fail closed (AGENTS rule 10): stock LootContainer.roll yields an
        // empty container when every entry fails its prob gate; never invent
        // items loot.xml does not define.
        return n;
    }

    fn rollGroup(self: *const LootTable, name: []const u8, loot_stage: i32, seed: u32, out: []Stack, depth: u8, inherit_template: []const u8, ctx: LootGateCtx) usize {
        if (depth > 6 or out.len == 0) return 0;
        const g = self.groupByName(name) orelse return 0;
        if (g.entry_n == 0) return 0;
        const qt = if (g.quality_template.len > 0) g.quality_template else inherit_template;
        const mult = groupAbundanceFactor(ctx, g);
        var s = seed;
        // count="all" (stock -1): every entry spawns once; regular prob is
        // ignored, force_prob entries gate independently (SpawnAllItemsFromList,
        // asm.il 698452).
        if (g.pick_all) {
            var an: usize = 0;
            var ai: u8 = 0;
            while (ai < g.entry_n and an < out.len) : (ai += 1) {
                const e = g.entries[ai];
                var gctx = ctx;
                gctx.roll = unitRoll(s ^ @as(u32, ai));
                if (!e.gate.allowed(gctx)) continue;
                s = s *% 1103515245 +% 12345;
                if (e.force_prob and !self.probGate(e, loot_stage, s)) continue;
                reportBuffs(gctx, e);
                if (e.is_group) {
                    an += self.rollGroup(e.name, loot_stage, s, out[an..], depth + 1, qt, ctx);
                } else {
                    const cmin = e.count_min;
                    const cmax = if (e.count_max >= cmin) e.count_max else cmin;
                    const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                    const cnt0: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                    const cnt = self.stageCount(self.scaleCount(cnt0, true, mult), e, loot_stage);
                    if (cnt == 0) continue; // disabled category spawns none
                    out[an] = .{ .item_name = e.name, .count = cnt, .quality = if (e.quality > 0) e.quality else self.resolveQuality(qt, loot_stage, s), .random_durability = e.random_durability };
                    an += 1;
                }
            }
            return an;
        }
        const picks: u8 = blk: {
            if (g.pick_max <= g.pick_min) break :blk g.pick_min;
            s = s *% 1103515245 +% 12345;
            // Same widening as the count spans: count="0,255" on a group would
            // overflow the u8 span (255-0+1 = 256).
            const span: u32 = @as(u32, g.pick_max) - @as(u32, g.pick_min) + 1;
            break :blk g.pick_min + @as(u8, @intCast(s % span));
        };
        var n: usize = 0;
        var p: u8 = 0;
        while (p < picks and n < out.len) : (p += 1) {
            s = s *% 1103515245 +% 12345;
            // Prob-weighted pick (stock LootContainer probability): each
            // entry's stage-resolved prob is its weight relative to the group
            // sum, so a 0.9 item drops ~9x as often as a 0.1 one. A zero-prob
            // plain entry gets weight 0 (never picked); force_prob entries
            // keep weight 1 and gate independently (their prob is a per-pick
            // chance, not a relative weight, stock force_prob semantics).
            var total: u32 = 0;
            var e: u8 = 0;
            while (e < g.entry_n) : (e += 1) {
                total +|= self.groupEntryWeight(g.entries[e], loot_stage);
            }
            if (total == 0) break;
            const roll = s % total;
            var chosen: u8 = 0;
            var acc: u32 = 0;
            while (chosen < g.entry_n) : (chosen += 1) {
                acc +|= self.groupEntryWeight(g.entries[chosen], loot_stage);
                if (roll < acc) break;
            }
            if (chosen >= g.entry_n) chosen = g.entry_n - 1;
            const picked_e = g.entries[chosen];
            var gctx = ctx;
            gctx.roll = unitRoll(s);
            if (!picked_e.gate.allowed(gctx)) continue;
            // A picked entry still has to clear its loot stage band, so a
            // low-stage player cannot pull a top-tier item out of a group.
            // A force_prob entry rolls its prob independently.
            if (picked_e.force_prob) {
                if (!self.probGate(picked_e, loot_stage, s)) continue;
            } else if (picked_e.prob_template != 0 and !self.probGate(picked_e, loot_stage, s)) continue;
            reportBuffs(gctx, picked_e);
            if (picked_e.is_group) {
                n += self.rollGroup(picked_e.name, loot_stage, s, out[n..], depth + 1, qt, ctx);
            } else {
                const cmin = picked_e.count_min;
                const cmax = if (picked_e.count_max >= cmin) picked_e.count_max else cmin;
                // Same span widening as rollContainer (count="0,65535").
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt0: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                const cnt = self.stageCount(self.scaleCount(cnt0, true, mult), picked_e, loot_stage);
                if (cnt == 0) continue; // disabled category spawns none
                out[n] = .{ .item_name = picked_e.name, .count = cnt, .quality = if (picked_e.quality > 0) picked_e.quality else self.resolveQuality(qt, loot_stage, s), .random_durability = picked_e.random_durability };
                n += 1;
            }
        }
        return n;
    }

    /// Prob weight of one group entry for a weighted pick: force_prob entries
    /// weigh 1 (their prob is a per-pick gate), plain/template entries weigh
    /// their stage-resolved prob (prob <= 0 = weight 0, unpickable).
    fn groupEntryWeight(self: *const LootTable, e: LootEntry, loot_stage: i32) u32 {
        if (e.force_prob) return 1;
        const ep = self.entryProb(e, loot_stage);
        if (!(ep > 0)) return 0;
        return @trunc(@min(ep, 10.0) * 1000.0);
    }

    /// Milliprobs for the ischosen reward weighted pick. Non-finite or
    /// non-positive probs fail closed at the weight-1 floor; finite probs
    /// cap so *1000 stays under maxInt(u32). Either way a malformed
    /// loot.xml prob can no longer trap the float->u32 cast mid-roll.
    fn pickWeight(prob: f32) u32 {
        if (!std.math.isFinite(prob) or prob <= 0) return 1;
        const milli: f32 = @min(prob, 4_000_000.0) * 1000.0;
        return @max(@as(u32, @trunc(milli)), 1);
    }
};

test "pickWeight clamps malformed probs instead of trapping the cast" {
    // Normal probs are milliprobs.
    try std.testing.expectEqual(@as(u32, 500), LootTable.pickWeight(0.5));
    // Negative, NaN and zero fail closed at the weight-1 floor (a panic in
    // the float->u32 cast before the clamp).
    try std.testing.expectEqual(@as(u32, 1), LootTable.pickWeight(-2.0));
    try std.testing.expectEqual(@as(u32, 1), LootTable.pickWeight(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 1), LootTable.pickWeight(0));
    // Huge finite probs cap under maxInt(u32) instead of trapping; a
    // non-finite prob fails closed at the weight-1 floor.
    try std.testing.expectEqual(@as(u32, 4_000_000_000), LootTable.pickWeight(1.0e9));
    try std.testing.expectEqual(@as(u32, 1), LootTable.pickWeight(std.math.inf(f32)));
}

test "loot abundance scales counts, keeps at least one" {
    var lt = LootTable.builtin();
    var base: [max_roll_stacks]Stack = undefined;
    const nb = lt.rollContainer("woodenChest", 1, 12345, &base, .{});
    lt.abundance_pct = 200;
    var big: [max_roll_stacks]Stack = undefined;
    const ng = lt.rollContainer("woodenChest", 1, 12345, &big, .{});
    try std.testing.expectEqual(nb, ng);
    // Every non-fallback stack doubles (same seed → same base counts).
    var i: usize = 0;
    while (i < nb) : (i += 1) {
        try std.testing.expectEqualStrings(base[i].item_name, big[i].item_name);
        try std.testing.expectEqual(base[i].count * 2, big[i].count);
    }
    // A tiny abundance still yields at least 1 per stack.
    lt.abundance_pct = 1;
    var small: [max_roll_stacks]Stack = undefined;
    const ns = lt.rollContainer("woodenChest", 1, 12345, &small, .{});
    i = 0;
    while (i < ns) : (i += 1) try std.testing.expect(small[i].count >= 1);
}

test "scaleCount saturates at the u16 cap instead of trapping" {
    var lt = LootTable.builtin();
    // Max stock abundance (1000) times a modded count past 6553 would exceed
    // u16 in the scaled product; the roll saturates at the stack cap.
    lt.abundance_pct = 1000;
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), lt.scaleCount(10000, true, 1.0));
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), lt.scaleCount(65535, true, 1.0));
    // Mid-range values still scale normally.
    lt.abundance_pct = 200;
    try std.testing.expectEqual(@as(u16, 200), lt.scaleCount(100, true, 1.0));
    // The floor keeps at least one even for a tiny count and abundance.
    lt.abundance_pct = 1;
    try std.testing.expectEqual(@as(u16, 1), lt.scaleCount(1, true, 1.0));
    // ignore_loot_abundance passes the raw count through unmodified.
    lt.abundance_pct = 1000;
    try std.testing.expectEqual(@as(u16, 65535), lt.scaleCount(65535, false, 1.0));
    // The group's abundance_type factor multiplies the global abundance, and 0
    // means the category is disabled (stock `abundance *= mult`).
    lt.abundance_pct = 100;
    try std.testing.expectEqual(@as(u16, 50), lt.scaleCount(100, true, 0.5));
    try std.testing.expectEqual(@as(u16, 0), lt.scaleCount(100, true, 0.0));
}

const builtin_groups = [_]LootGroup{
    blk: {
        var g: LootGroup = .{
            .name = "groupScrapCommon",
            .pick_min = 1,
            .pick_max = 1,
            .entry_n = 2,
        };
        g.entries[0] = .{ .name = "resourceScrapIron", .count_min = 3, .count_max = 8 };
        g.entries[1] = .{ .name = "resourceScrapLead", .count_min = 2, .count_max = 6 };
        break :blk g;
    },
};

const builtin_containers = [_]LootContainer{
    blk: {
        var c: LootContainer = .{
            .name = "EntityLootContainerRegular",
            .size_x = 6,
            .size_y = 2,
            .entry_n = 2,
        };
        c.entries[0] = .{ .name = "groupScrapCommon", .is_group = true };
        c.entries[1] = .{ .name = "foodCanBeef", .count_min = 1, .count_max = 2, .prob = 0.35 };
        break :blk c;
    },
    blk: {
        var c: LootContainer = .{
            .name = "woodenChest",
            .size_x = 6,
            .size_y = 2,
            .entry_n = 2,
        };
        c.entries[0] = .{ .name = "groupScrapCommon", .is_group = true };
        c.entries[1] = .{ .name = "resourceWood", .count_min = 5, .count_max = 15 };
        break :blk c;
    },
};

fn parseCountRange(s: []const u8) struct { min: u16, max: u16 } {
    if (std.mem.findScalar(u8, s, ',')) |c| {
        const a = xml.parseU16(std.mem.trim(u8, s[0..c], " \t")) orelse 1;
        const b = xml.parseU16(std.mem.trim(u8, s[c + 1 ..], " \t")) orelse a;
        return .{ .min = a, .max = b };
    }
    const v = xml.parseU16(std.mem.trim(u8, s, " \t")) orelse 1;
    return .{ .min = v, .max = v };
}

fn parseItemOrGroup(tag_src: []const u8, tag_at: usize, templates: []const ProbTemplate) ?LootEntry {
    const is_group = xml.attr(tag_src, tag_at, "group") != null;
    const name = if (is_group) xml.attr(tag_src, tag_at, "group") else xml.attr(tag_src, tag_at, "name");
    const n = name orelse return null;
    const cr = parseCountRange(xml.attr(tag_src, tag_at, "count") orelse "1");
    const prob = xml.parseF32(xml.attr(tag_src, tag_at, "prob") orelse "1") orelse 1;
    const fp = xml.attr(tag_src, tag_at, "force_prob") orelse "";
    const quality: u8 = if (xml.attr(tag_src, tag_at, "quality")) |q|
        @intCast(@min(xml.parseU16(q) orelse 0, 255))
    else
        0;
    const stage_mod = xml.parseF32(xml.attr(tag_src, tag_at, "loot_stage_count_mod") orelse "") orelse 0;
    const rnd_dura = blk: {
        const v = xml.attr(tag_src, tag_at, "random_durability") orelse break :blk false;
        break :blk std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "True") or std.mem.eql(u8, v, "1");
    };
    // The entry's own `<requirement>` child, if any (the element extent keeps a
    // nested group's gated entries their own). Only `Biome` is rolled today;
    // every other class marks the entry omitted (see `EntryGate`).
    const entry_end = requirements.elementEnd(tag_src, tag_at);
    const inner = tag_src[tag_at..entry_end];
    var gate: EntryGate = .{};
    if (std.mem.findPos(u8, inner, 0, "<requirement")) |req_at| {
        const abs = tag_at + req_at;
        const class = xml.attr(tag_src, abs, "class") orelse "";
        const op = requirements.parseCompare(xml.attr(tag_src, abs, "operation") orelse "");
        if (std.mem.eql(u8, class, "Biome")) {
            gate = .{ .kind = .biome, .biomes = xml.attr(tag_src, abs, "biomes") orelse "" };
        } else if (std.mem.eql(u8, class, "Progression")) {
            gate = .{
                .kind = .progression,
                .arg = xml.attr(tag_src, abs, "name") orelse "",
                .op = op,
                .value = xml.parseF32(xml.attr(tag_src, abs, "value") orelse "") orelse 0,
            };
        } else if (std.mem.eql(u8, class, "CVar")) {
            gate = .{
                .kind = .cvar,
                .arg = xml.attr(tag_src, abs, "cvar") orelse "",
                .op = op,
                .value = xml.parseF32(xml.attr(tag_src, abs, "value") orelse "") orelse 0,
            };
        } else if (std.mem.eql(u8, class, "SandboxOption")) {
            gate = .{
                .kind = .sandbox,
                .arg = xml.attr(tag_src, abs, "option") orelse "",
                .op = op,
                .value = xml.parseF32(xml.attr(tag_src, abs, "value") orelse "") orelse 0,
            };
        } else if (std.mem.eql(u8, class, "RandomRoll")) {
            const value = xml.attr(tag_src, abs, "value") orelse "";
            gate = .{
                .kind = .random_roll,
                .op = op,
                .value = xml.parseF32(value) orelse 0,
                .value_cvar = cvarOperand(value),
                .min_max = parseMinMax(xml.attr(tag_src, abs, "min_max") orelse "0,100"),
            };
        } else {
            gate = .{ .kind = .other };
        }
    }
    var tpl: u16 = 0;
    if (xml.attr(tag_src, tag_at, "loot_prob_template")) |tn| {
        for (templates, 0..) |t, ti| {
            if (std.mem.eql(u8, t.name, tn)) {
                tpl = @intCast(ti + 1);
                break;
            }
        }
    }
    return .{
        .name = n,
        .is_group = is_group,
        .count_min = cr.min,
        .count_max = cr.max,
        .prob = prob,
        .prob_template = tpl,
        .quality = quality,
        .loot_stage_count_mod = stage_mod,
        .random_durability = rnd_dura,
        .buffs = xml.attr(tag_src, tag_at, "buffs") orelse "",
        .force_prob = std.mem.eql(u8, fp, "true") or std.mem.eql(u8, fp, "True"),
        .gate = gate,
    };
}

/// `min_max="a,b"` on a RandomRoll requirement; a bare number is both ends.
fn parseMinMax(s: []const u8) [2]f32 {
    const comma = std.mem.findScalar(u8, s, ',') orelse {
        const v = xml.parseF32(s) orelse 0;
        return .{ v, v };
    };
    return .{
        xml.parseF32(std.mem.trim(u8, s[0..comma], " \t")) orelse 0,
        xml.parseF32(std.mem.trim(u8, s[comma + 1 ..], " \t")) orelse 100,
    };
}

/// `value="@$name"` / `value="@name"` names the entity's cvar; anything else is
/// a literal. `@:` is a localization key, never an operand.
fn cvarOperand(v: []const u8) []const u8 {
    if (std.mem.startsWith(u8, v, "@$")) return v[2..];
    if (std.mem.startsWith(u8, v, "@")) return v[1..];
    return "";
}

/// Deep-copy the arena-owned slices of one gate (the source buffer dies when
/// the parse returns).
fn dupeGate(arena: std.mem.Allocator, g: EntryGate) !EntryGate {
    var out = g;
    if (out.biomes.len > 0) out.biomes = try arena.dupe(u8, out.biomes);
    if (out.arg.len > 0) out.arg = try arena.dupe(u8, out.arg);
    if (out.value_cvar.len > 0) out.value_cvar = try arena.dupe(u8, out.value_cvar);
    return out;
}

/// `level="a,b"` on a `<loot>` band; a bare number covers exactly that level.
fn parseLevelRange(s: []const u8) struct { min: i32, max: i32 } {
    const comma = std.mem.findScalar(u8, s, ',') orelse {
        const v = std.fmt.parseInt(i32, std.mem.trim(u8, s, " \t"), 10) catch 0;
        return .{ .min = v, .max = v };
    };
    const a = std.fmt.parseInt(i32, std.mem.trim(u8, s[0..comma], " \t"), 10) catch 0;
    const b = std.fmt.parseInt(i32, std.mem.trim(u8, s[comma + 1 ..], " \t"), 10) catch a;
    return .{ .min = a, .max = @max(a, b) };
}

/// Comma list of floats into an arena slice (`poi_tier_mod="0.05,0.1,…"`).
fn parseF32List(arena: std.mem.Allocator, s: []const u8) ![]const f32 {
    var n: usize = 0;
    var count_it = std.mem.splitScalar(u8, s, ',');
    while (count_it.next()) |_| n += 1;
    const out = try arena.alloc(f32, n);
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| : (i += 1) {
        out[i] = xml.parseF32(std.mem.trim(u8, part, " \t")) orelse 0;
    }
    return out;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !LootTable {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    return loadFromSlice(allocator, raw);
}

pub fn loadFromSlice(allocator: std.mem.Allocator, raw: []const u8) !LootTable {
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var groups: std.ArrayList(LootGroup) = .empty;
    defer groups.deinit(allocator);
    var containers: std.ArrayList(LootContainer) = .empty;
    defer containers.deinit(allocator);

    // <loot_settings poi_tier_mod="…" poi_tier_bonus="…"/>
    var poi_mod: []const f32 = &.{};
    var poi_bonus: []const f32 = &.{};
    if (std.mem.find(u8, clean, "<loot_settings")) |ls| {
        if (xml.attr(clean, ls, "poi_tier_mod")) |v| poi_mod = try parseF32List(arena, v);
        if (xml.attr(clean, ls, "poi_tier_bonus")) |v| poi_bonus = try parseF32List(arena, v);
    }

    // lootprobtemplate: parsed first so item rows can resolve to an index.
    var templates: std.ArrayList(ProbTemplate) = .empty;
    defer templates.deinit(allocator);
    var bands: std.ArrayList(ProbBand) = .empty;
    defer bands.deinit(allocator);
    var ti: usize = 0;
    while (std.mem.findPos(u8, clean, ti, "<lootprobtemplate")) |tag| {
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            ti = gt + 1;
            continue;
        };
        var body: []const u8 = "";
        ti = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</lootprobtemplate>") orelse break;
            body = clean[gt + 1 .. close];
            ti = close + 19;
        }
        bands.clearRetainingCapacity();
        var bi: usize = 0;
        while (std.mem.findPos(u8, body, bi, "<loot")) |ltag| {
            bi = ltag + 5;
            const lvl = xml.attr(body, ltag, "level") orelse continue;
            const lr = parseLevelRange(lvl);
            try bands.append(allocator, .{
                .min_level = lr.min,
                .max_level = lr.max,
                .prob = xml.parseF32(std.mem.trim(u8, xml.attr(body, ltag, "prob") orelse "0", " \t")) orelse 0,
            });
        }
        if (bands.items.len == 0) continue;
        try templates.append(allocator, .{
            .name = try arena.dupe(u8, name),
            .bands = try arena.dupe(ProbBand, bands.items),
        });
    }
    const tpl = try arena.dupe(ProbTemplate, templates.items);

    // lootqualitytemplate: level bands with prob-weighted quality picks.
    var q_templates: std.ArrayList(QualityTemplate) = .empty;
    defer q_templates.deinit(allocator);
    var qti: usize = 0;
    while (std.mem.findPos(u8, clean, qti, "<lootqualitytemplate")) |qt_tag| {
        const qt_name = xml.attr(clean, qt_tag, "name") orelse {
            qti = qt_tag + 21;
            continue;
        };
        const qt_gt = std.mem.findPos(u8, clean, qt_tag, ">") orelse break;
        var qt_body: []const u8 = "";
        qti = qt_gt + 1;
        if (!(qt_gt > qt_tag and clean[qt_gt - 1] == '/')) {
            const qt_close = std.mem.findPos(u8, clean, qt_gt, "</lootqualitytemplate>") orelse break;
            qt_body = clean[qt_gt + 1 .. qt_close];
            qti = qt_close + 22;
        }
        var q_bands: std.ArrayList(QualityBand) = .empty;
        defer q_bands.deinit(allocator);
        var bi: usize = 0;
        while (std.mem.findPos(u8, qt_body, bi, "<qualitytemplate")) |b_tag| {
            bi = b_tag + 16;
            const lvl = xml.attr(qt_body, b_tag, "level") orelse continue;
            const lr = parseLevelRange(lvl);
            const dflt = xml.parseU16(std.mem.trim(u8, xml.attr(qt_body, b_tag, "default_quality") orelse "1", " \t")) orelse 1;
            const b_gt = std.mem.findPos(u8, qt_body, b_tag, ">") orelse break;
            var b_body: []const u8 = "";
            if (!(b_gt > b_tag and qt_body[b_gt - 1] == '/')) {
                const b_close = std.mem.findPos(u8, qt_body, b_gt, "</qualitytemplate>") orelse break;
                b_body = qt_body[b_gt + 1 .. b_close];
            }
            var picks: std.ArrayList(QualityPick) = .empty;
            defer picks.deinit(allocator);
            var pi: usize = 0;
            while (std.mem.findPos(u8, b_body, pi, "<loot ")) |p_tag| {
                pi = p_tag + 6;
                const q = xml.parseU16(std.mem.trim(u8, xml.attr(b_body, p_tag, "quality") orelse "1", " \t")) orelse 1;
                const p = xml.parseF32(std.mem.trim(u8, xml.attr(b_body, p_tag, "prob") orelse "0", " \t")) orelse 0;
                try picks.append(allocator, .{ .quality = @intCast(@min(q, 255)), .prob = p });
            }
            try q_bands.append(allocator, .{
                .min_level = lr.min,
                .max_level = lr.max,
                .default_quality = @intCast(@min(dflt, 255)),
                .picks = try arena.dupe(QualityPick, picks.items),
            });
        }
        if (q_bands.items.len == 0) continue;
        try q_templates.append(allocator, .{
            .name = try arena.dupe(u8, qt_name),
            .bands = try arena.dupe(QualityBand, q_bands.items),
        });
    }
    const q_tpl = try arena.dupe(QualityTemplate, q_templates.items);

    // lootgroup
    var i: usize = 0;
    while (i < clean.len and groups.items.len < max_groups) {
        const tag = std.mem.findPos(u8, clean, i, "<lootgroup") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 10;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</lootgroup>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 12;
        }
        var g: LootGroup = .{
            .name = try arena.dupe(u8, name),
        };
        if (xml.attr(clean, tag, "loot_quality_template")) |lqt| {
            g.quality_template = try arena.dupe(u8, lqt);
        }
        if (xml.attr(clean, tag, "count")) |cv| {
            if (std.mem.eql(u8, cv, "all")) {
                g.pick_all = true;
            } else {
                const cr = parseCountRange(cv);
                g.pick_min = @intCast(@min(cr.min, 255));
                g.pick_max = @intCast(@min(cr.max, 255));
            }
        }
        if (xml.attr(clean, tag, "abundance_type")) |at| {
            g.abundance_type = try arena.dupe(u8, at);
        }
        var bi: usize = 0;
        while (bi < body.len and g.entry_n < max_entries) {
            const itag = std.mem.findPos(u8, body, bi, "<item") orelse break;
            if (parseItemOrGroup(body, itag, tpl)) |ent| {
                var e = ent;
                e.name = try arena.dupe(u8, ent.name);
                if (ent.buffs.len > 0) e.buffs = try arena.dupe(u8, ent.buffs);
                // The gate's biome list points into the freed source text.
                e.gate = try dupeGate(arena, ent.gate);
                g.entries[g.entry_n] = e;
                g.entry_n += 1;
            }
            bi = itag + 5;
        }
        try groups.append(allocator, g);
        i = next_i;
    }

    // lootcontainer
    i = 0;
    while (i < clean.len and containers.items.len < max_containers) {
        const tag = std.mem.findPos(u8, clean, i, "<lootcontainer") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 14;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</lootcontainer>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 16;
        }
        var c: LootContainer = .{
            .name = try arena.dupe(u8, name),
        };
        if (xml.attr(clean, tag, "loot_quality_template")) |lqt| {
            c.quality_template = try arena.dupe(u8, lqt);
        }
        if (xml.attr(clean, tag, "size")) |sz| {
            if (std.mem.findScalar(u8, sz, ',')) |comma| {
                c.size_x = @intCast(xml.parseU16(std.mem.trim(u8, sz[0..comma], " \t")) orelse 8);
                c.size_y = @intCast(xml.parseU16(std.mem.trim(u8, sz[comma + 1 ..], " \t")) orelse 6);
            }
        }
        // destroy_on_close: "true" (1) / "empty" (2) / absent (0). Values
        // feed TEFeatureStorage.ShouldDestroyOnClose (loot-economy.md).
        if (xml.attr(clean, tag, "destroy_on_close")) |doc| {
            if (std.mem.eql(u8, doc, "true")) {
                c.destroy_on_close = 1;
            } else if (std.mem.eql(u8, doc, "empty")) {
                c.destroy_on_close = 2;
            }
        }
        // LootAbundance/type/lootstage/open flags (RE loot-economy.md):
        // ignore_loot_abundance skips the global abundance scale; the rest
        // are parsed for the audit (type multipliers and the stage chain are
        // not applied server-side yet).
        if (xml.attr(clean, tag, "ignore_loot_abundance")) |ila| {
            c.ignore_abundance = std.mem.eql(u8, ila, "true");
        }
        if (xml.attr(clean, tag, "unique_item")) |ui| {
            c.unique_item = std.mem.eql(u8, ui, "true");
        }
        if (xml.attr(clean, tag, "unmodified_lootstage")) |ul| {
            c.raw_lootstage = std.mem.eql(u8, ul, "true");
        }
        if (xml.attr(clean, tag, "open_time")) |ot| {
            c.open_time = xml.parseF32(ot) orelse 0;
        }
        var bi: usize = 0;
        while (bi < body.len and c.entry_n < max_entries) {
            const itag = std.mem.findPos(u8, body, bi, "<item") orelse break;
            if (parseItemOrGroup(body, itag, tpl)) |ent| {
                var e = ent;
                e.name = try arena.dupe(u8, ent.name);
                if (ent.buffs.len > 0) e.buffs = try arena.dupe(u8, ent.buffs);
                e.gate = try dupeGate(arena, ent.gate);
                c.entries[c.entry_n] = e;
                c.entry_n += 1;
            }
            bi = itag + 5;
        }
        try containers.append(allocator, c);
        i = next_i;
    }

    return .{
        .groups = try arena.dupe(LootGroup, groups.items),
        .containers = try arena.dupe(LootContainer, containers.items),
        .prob_templates = tpl,
        .quality_templates = q_tpl,
        .poi_tier_mod = poi_mod,
        .poi_tier_bonus = poi_bonus,
        .arena_ptr = arena_holder,
        .source = .xml,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?LootTable {
    const paths = @import("paths.zig");
    return paths.tryLoadConfig("loot.xml", LootTable, loadFromPath, allocator, game_dir, config_dir);
}

test "builtin loot roll" {
    const t = LootTable.builtin();
    var stacks: [max_roll_stacks]Stack = undefined;
    const n = t.rollContainer("EntityLootContainerRegular", 1, 42, &stacks, .{});
    try std.testing.expect(n >= 1);
    try std.testing.expect(stacks[0].count >= 1);
}

test "load stock loot when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.groups.len > 50);
    try std.testing.expect(t.containers.len > 20);
    try std.testing.expect(t.containerByName("woodenChest") != null);
    var stacks: [max_roll_stacks]Stack = undefined;
    // Fail-closed rolls mean a single seed can legitimately come up empty
    // (stock prob gates); some seed in a spread must still yield loot.
    var total: usize = 0;
    var seed: u32 = 0;
    while (seed < 32) : (seed += 1) {
        total += t.rollContainer("woodenChest", 7, seed, &stacks, .{});
    }
    try std.testing.expect(total >= 1);
}

test "loot prob templates gate entries by loot stage" {
    const src =
        \\<lootcontainers>
        \\<loot_settings poi_tier_mod="0.05,0.1,0.15" poi_tier_bonus="3,6,9"/>
        \\<lootprobtemplates>
        \\  <lootprobtemplate name="veryLowDelayed">
        \\    <loot level="0,14" prob="0"/>
        \\    <loot level="15,999999" prob=".05"/>
        \\  </lootprobtemplate>
        \\  <lootprobtemplate name="guaranteed">
        \\    <loot level="1,999999" prob="1"/>
        \\  </lootprobtemplate>
        \\</lootprobtemplates>
        \\<lootgroup name="g">
        \\  <item name="always" loot_prob_template="guaranteed"/>
        \\  <item name="plain"/>
        \\</lootgroup>
        \\<lootcontainer name="c" size="6,2">
        \\  <item name="gated" loot_prob_template="veryLowDelayed"/>
        \\  <item name="plain"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.prob_templates.len);
    try std.testing.expectEqual(@as(usize, 3), t.poi_tier_mod.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), t.poi_tier_mod[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), t.poi_tier_bonus[0], 0.0001);

    const cont = t.containerByName("c").?;
    const gated = cont.entries[0];
    const plain = cont.entries[1];
    // veryLowDelayed: zero below stage 15, .05 at and above it.
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.entryProb(gated, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.entryProb(gated, 14), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), t.entryProb(gated, 15), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), t.entryProb(gated, 999999), 0.0001);
    // Above the last band nothing matches, so the entry's own prob applies.
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.entryProb(gated, 1_000_000), 0.0001);
    // An entry with no template is stage-blind (unchanged behaviour).
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.entryProb(plain, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.entryProb(plain, 5000), 0.0001);

    // The zero band must suppress the item across every seed, and the .05 band
    // must let it through at least once.
    var stacks: [max_roll_stacks]Stack = undefined;
    var seen_low: usize = 0;
    var seen_high: usize = 0;
    var seed: u32 = 0;
    while (seed < 400) : (seed += 1) {
        var n = t.rollContainer("c", 0, seed, &stacks, .{});
        for (stacks[0..n]) |st| {
            if (std.mem.eql(u8, st.item_name, "gated")) seen_low += 1;
        }
        n = t.rollContainer("c", 40, seed, &stacks, .{});
        for (stacks[0..n]) |st| {
            if (std.mem.eql(u8, st.item_name, "gated")) seen_high += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), seen_low);
    try std.testing.expect(seen_high >= 1);
}

test "all-gated roll yields an empty container, not fabricated items" {
    const src =
        \\<lootcontainers>
        \\<lootprobtemplates>
        \\  <lootprobtemplate name="never">
        \\    <loot level="0,999999" prob="0"/>
        \\  </lootprobtemplate>
        \\</lootprobtemplates>
        \\<lootcontainer name="emptyOk" size="6,2">
        \\  <item name="gatedA" loot_prob_template="never"/>
        \\  <item name="gatedB" prob="0"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    var stacks: [max_roll_stacks]Stack = undefined;
    var seed: u32 = 0;
    while (seed < 50) : (seed += 1) {
        const n = t.rollContainer("emptyOk", 30, seed, &stacks, .{});
        try std.testing.expectEqual(@as(usize, 0), n);
    }
}

test "stock loot item entries leave quality to the template" {
    // Stock writes `quality` only on the <loot> rows inside a
    // <lootqualitytemplate>, never on an <item>. This pins that fact and the
    // template path it implies: the parsed entries carry no override, and the
    // template still resolves a quality for them.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();
    var entries: usize = 0;
    for (lt.groups) |g| {
        for (g.entries[0..g.entry_n]) |e| {
            try std.testing.expectEqual(@as(u8, 0), e.quality);
            entries += 1;
        }
    }
    for (lt.containers) |c| {
        for (c.entries[0..c.entry_n]) |e| {
            try std.testing.expectEqual(@as(u8, 0), e.quality);
            entries += 1;
        }
    }
    try std.testing.expect(entries > 100);
    // The template rows did parse (a rename would empty the picks).
    try std.testing.expect(lt.quality_templates.len > 0);
    var picks: usize = 0;
    for (lt.quality_templates) |qt| {
        for (qt.bands) |band| picks += band.picks.len;
    }
    try std.testing.expect(picks > 100);
}

test "random_durability marks the stack and the wear formula matches stock" {
    // LootContainer IL_032D: `UseTimes = (int)(MaxUseTimes * RandomRange(0.2,
    // 0.8))`. The roll only marks the stack; the fill path owns MaxUseTimes.
    try std.testing.expectEqual(@as(f32, 0), randomUseTimes(0, 12345));
    var s: u32 = 1;
    while (s <= 200) : (s += 1) {
        const v = randomUseTimes(100, s);
        try std.testing.expect(v >= 20 and v <= 80);
        try std.testing.expectEqual(v, randomUseTimes(100, s)); // deterministic
    }
    // An absurd cap saturates the cast instead of trapping.
    try std.testing.expect(randomUseTimes(std.math.maxInt(u32), 7) > 0);

    const src =
        \\<lootgroups>
        \\<lootgroup name="duraGroup" count="all">
        \\  <item name="toolWorn" random_durability="true"/>
        \\  <item name="toolPristine" random_durability="false"/>
        \\  <item name="toolPlain"/>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    const g = lt.groupByName("duraGroup").?;
    try std.testing.expect(g.entries[0].random_durability);
    try std.testing.expect(!g.entries[1].random_durability);
    try std.testing.expect(!g.entries[2].random_durability);
    var stacks: [8]Stack = undefined;
    const n = lt.rollGroup("duraGroup", 1, 7, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(stacks[0].random_durability);
    try std.testing.expect(!stacks[1].random_durability);
    try std.testing.expect(!stacks[2].random_durability);
}

test "loot entry buffs are reported only for spawned entries" {
    // Stock collects a spawned entry's `buffsToAdd` during the roll and applies
    // the list to the opener after it (`ExecuteBuffActions`). The sink reports
    // exactly the entries that spawned: a gated entry that refuses reports
    // nothing, an ungated sibling still does.
    const src =
        \\<lootgroups>
        \\<lootgroup name="buffGroup" count="all">
        \\  <item name="bookA" buffs="buffPerkBookwormSuccess"/>
        \\  <item name="bookB" buffs="buffX,buffY">
        \\    <requirement class="Progression" name="perkTreasureHunter" operation="GTE" value="4"/>
        \\  </item>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    try std.testing.expectEqualStrings("buffPerkBookwormSuccess", lt.groupByName("buffGroup").?.entries[0].buffs);

    const Rec = struct {
        n: usize = 0,
        names: [8][]const u8 = .{""} ** 8,
        fn add(ctx: ?*anyopaque, name: []const u8) void {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            if (r.n < r.names.len) {
                r.names[r.n] = name;
                r.n += 1;
            }
        }
    };
    var stacks: [8]Stack = undefined;
    var rec: Rec = .{};
    const sink = LootBuffSink{ .ctx = &rec, .add = Rec.add };

    // No opener: the Progression gate refuses, so only bookA's buff is seen.
    _ = lt.rollGroup("buffGroup", 1, 7, &stacks, 0, "", .{ .buffs = sink });
    try std.testing.expectEqual(@as(usize, 1), rec.n);
    try std.testing.expectEqualStrings("buffPerkBookwormSuccess", rec.names[0]);

    // A level-4 opener: both entries spawn and all three names are reported.
    const levels = [_]requirements.NameLevel{.{ .name = "perkTreasureHunter", .level = 4 }};
    const player: requirements.Ctx = .{ .levels = &levels };
    rec = .{};
    _ = lt.rollGroup("buffGroup", 1, 7, &stacks, 0, "", .{ .player = player, .buffs = sink });
    try std.testing.expectEqual(@as(usize, 3), rec.n);
    try std.testing.expectEqualStrings("buffPerkBookwormSuccess", rec.names[0]);
    try std.testing.expectEqualStrings("buffX", rec.names[1]);
    try std.testing.expectEqualStrings("buffY", rec.names[2]);
}

test "loot_stage_count_mod grows the count with the loot stage" {
    // LootContainer IL_017F: count += RoundToInt(count * lootstageCountMod *
    // lootStage), applied to the sandbox-scaled count. Stock's 84 uses are all
    // 0.01 on ammo rows.
    const src =
        \\<lootgroups>
        \\<lootgroup name="ammoGroup" count="all">
        \\  <item name="ammoBox" count="10" loot_stage_count_mod="0.01"/>
        \\  <item name="ammoPlain" count="10"/>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    const g = lt.groupByName("ammoGroup").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), g.entries[0].loot_stage_count_mod, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), g.entries[1].loot_stage_count_mod);

    var stacks: [8]Stack = undefined;
    // Stage 0 (the no-gamestage floor): nothing added.
    var n = lt.rollGroup("ammoGroup", 0, 5, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 2), n);
    for (stacks[0..n]) |st| try std.testing.expectEqual(@as(u16, 10), st.count);
    // Stage 50: 10 + round(10 * 0.01 * 50) = 15 for the modded entry only.
    n = lt.rollGroup("ammoGroup", 50, 5, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 2), n);
    for (stacks[0..n]) |st| {
        if (std.mem.eql(u8, st.item_name, "ammoBox")) {
            try std.testing.expectEqual(@as(u16, 15), st.count);
        } else {
            try std.testing.expectEqual(@as(u16, 10), st.count);
        }
    }
}

test "stock loot entries carry loot_stage_count_mod on ammo groups" {
    // Guards the attribute name/parse against a stock update: group9mmSmall's
    // rounds carry the 0.01 stage growth.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();
    const g = lt.groupByName("group9mmSmall") orelse return error.TestUnexpectedResult;
    var seen: usize = 0;
    for (g.entries[0..g.entry_n]) |e| {
        if (e.loot_stage_count_mod > 0) {
            try std.testing.expectApproxEqAbs(@as(f32, 0.01), e.loot_stage_count_mod, 1e-6);
            seen += 1;
        }
    }
    try std.testing.expect(seen > 0);
}

test "loot entry quality overrides the quality template" {
    // 698 stock entries carry a single `quality="1..6"`. Stock seeds the
    // entry's minQuality/maxQuality from the caller and a `quality` attribute
    // overrides them, so the entry spawns at that fixed quality instead of the
    // template roll.
    const src =
        \\<lootcontainers>
        \\<lootqualitytemplate name="qualTest">
        \\  <qualitytemplate level="0,999999" default_quality="1">
        \\    <loot quality="1" prob="1"/>
        \\  </qualitytemplate>
        \\</lootqualitytemplate>
        \\<lootgroup name="fixedQ">
        \\  <item name="weaponFixed" quality="6"/>
        \\  <item name="weaponTemplate"/>
        \\</lootgroup>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    const g = t.groupByName("fixedQ").?;
    try std.testing.expectEqual(@as(u8, 6), g.entries[0].quality);
    try std.testing.expectEqual(@as(u8, 0), g.entries[1].quality);

    // The template alone always yields quality 1 here; the fixed entry must
    // still come out at 6 with the group's template inherited (count="all").
    const src2 =
        \\<lootgroups>
        \\<lootqualitytemplate name="qualTest">
        \\  <qualitytemplate level="0,999999" default_quality="1">
        \\    <loot quality="1" prob="1"/>
        \\  </qualitytemplate>
        \\</lootqualitytemplate>
        \\<lootgroup name="allFixed" count="all" loot_quality_template="qualTest">
        \\  <item name="weaponFixed" quality="6"/>
        \\  <item name="weaponTemplate"/>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var t2 = try loadFromSlice(std.testing.allocator, src2);
    defer t2.deinit();
    var stacks: [8]Stack = undefined;
    const n = t2.rollGroup("allFixed", 1, 42, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 2), n);
    for (stacks[0..n]) |st| {
        if (std.mem.eql(u8, st.item_name, "weaponFixed")) {
            try std.testing.expectEqual(@as(u8, 6), st.quality);
        } else {
            try std.testing.expectEqual(@as(u8, 1), st.quality);
        }
    }
}

test "loot quality template rolls quality by loot stage" {
    const src =
        \\<lootcontainers>
        \\<lootqualitytemplate name="qualTest">
        \\  <qualitytemplate level="0,9" default_quality="1">
        \\    <loot quality="1" prob="0.5"/>
        \\    <loot quality="2" prob="1"/>
        \\  </qualitytemplate>
        \\  <qualitytemplate level="10,999999" default_quality="6">
        \\    <loot quality="4" prob="0.1"/>
        \\    <loot quality="6" prob="1"/>
        \\  </qualitytemplate>
        \\</lootqualitytemplate>
        \\<lootgroup name="g">
        \\  <item name="weaponA"/>
        \\</lootgroup>
        \\<lootcontainer name="c" size="6,2" loot_quality_template="qualTest">
        \\  <item name="weaponA"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.quality_templates.len);
    try std.testing.expectEqualStrings("qualTest", t.containerByName("c").?.quality_template);
    // Stage 1: band 0-9, picks 1 (p.5) then 2 (p1) - quality in {1,2}.
    var stacks: [16]Stack = undefined;
    var saw_hi = false;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const n = t.rollContainer("c", 1, 9000 + i, &stacks, .{});
        for (stacks[0..n]) |s| {
            try std.testing.expect(s.quality == 1 or s.quality == 2);
            if (s.quality == 2) saw_hi = true;
        }
    }
    try std.testing.expect(saw_hi);
    // Stage 15: band 10+, picks 4 (p.1) then 6 (p1) - quality in {4,6}.
    var saw_6 = false;
    i = 0;
    while (i < 200) : (i += 1) {
        const n = t.rollContainer("c", 15, 7000 + i, &stacks, .{});
        for (stacks[0..n]) |s| {
            try std.testing.expect(s.quality == 4 or s.quality == 6);
            if (s.quality == 6) saw_6 = true;
        }
    }
    try std.testing.expect(saw_6);
    std.debug.print("PASS loot quality: template rolls quality by loot stage\n", .{});
}

test "count=all groups spawn every entry; force_prob gates independently" {
    const src =
        \\<lootcontainers>
        \\<lootgroup name="allGroup" count="all">
        \\  <item name="a" prob="0"/>
        \\  <item name="b" prob="0.0001"/>
        \\  <item name="c" prob="1"/>
        \\  <item name="gated" prob="1" force_prob="true"/>
        \\</lootgroup>
        \\<lootgroup name="pickGroup" count="1">
        \\  <item name="x" force_prob="true" prob="0"/>
        \\  <item name="y" force_prob="true" prob="1"/>
        \\  <item name="z"/>
        \\</lootgroup>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    const ag = t.groupByName("allGroup").?;
    try std.testing.expect(ag.pick_all);
    try std.testing.expectEqual(@as(u8, 4), ag.entry_n);
    // count="all": every entry spawns once regardless of prob; the force_prob
    // entry gates on its own prob (1 here so it stays).
    var stacks: [16]Stack = undefined;
    const n = t.rollGroup("allGroup", 1, 7, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 4), n);
    var saw_all = true;
    for ([_][]const u8{ "a", "b", "c", "gated" }) |want| {
        var seen = false;
        for (stacks[0..n]) |s| {
            if (std.mem.eql(u8, s.item_name, want)) seen = true;
        }
        if (!seen) saw_all = false;
    }
    try std.testing.expect(saw_all);
    // force_prob prob=0 is never picked from the pick pool.
    var s2: [16]Stack = undefined;
    var i: u32 = 0;
    var saw_x = false;
    while (i < 200) : (i += 1) {
        const n2 = t.rollGroup("pickGroup", 1, 1000 + i, &s2, 0, "", .{});
        for (s2[0..n2]) |s| {
            if (std.mem.eql(u8, s.item_name, "x")) saw_x = true;
        }
    }
    try std.testing.expect(!saw_x);
    std.debug.print("PASS loot: count=all spawns every entry, force_prob gates\n", .{});
}

test "stock groups parse past the old 32-entry cap (perkBooks)" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // perkBooks has 133 entries; the cap must not truncate stock groups.
    if (t.groupByName("perkBooks")) |g| {
        try std.testing.expect(g.entry_n >= 100);
        try std.testing.expect(g.entry_n <= max_entries);
    }
}

test "loot rolls stay deterministic for a given stage and seed" {
    const t = LootTable.builtin();
    var a: [max_roll_stacks]Stack = undefined;
    var b: [max_roll_stacks]Stack = undefined;
    const na = t.rollContainer("woodenChest", 37, 99, &a, .{});
    const nb = t.rollContainer("woodenChest", 37, 99, &b, .{});
    try std.testing.expectEqual(na, nb);
    for (a[0..na], b[0..nb]) |x, y| {
        try std.testing.expectEqualStrings(x.item_name, y.item_name);
        try std.testing.expectEqual(x.count, y.count);
    }
    // Stage 0 and the i32 extremes must not trap.
    _ = t.rollContainer("woodenChest", 0, 1, &a, .{});
    _ = t.rollContainer("woodenChest", std.math.minInt(i32), 1, &a, .{});
    _ = t.rollContainer("woodenChest", std.math.maxInt(i32), 1, &a, .{});
}

test "stock loot prob templates load and band the real items" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.prob_templates.len > 10);
    // loot_settings ships five POI tiers.
    try std.testing.expectEqual(@as(usize, 5), t.poi_tier_mod.len);
    try std.testing.expectEqual(@as(usize, 5), t.poi_tier_bonus.len);
    // At least one item row must reference a template, else the resolve step
    // silently did nothing.
    var referenced: usize = 0;
    for (t.groups) |g| {
        var i: u8 = 0;
        while (i < g.entry_n) : (i += 1) {
            if (g.entries[i].prob_template != 0) referenced += 1;
        }
    }
    try std.testing.expect(referenced > 100);
    // ProbT0's documented mid band: level 20,21 → prob 1.
    for (t.prob_templates) |p| {
        if (!std.mem.eql(u8, p.name, "ProbT0")) continue;
        var hit = false;
        for (p.bands) |b| {
            if (b.min_level == 20 and b.max_level == 21) {
                try std.testing.expectApproxEqAbs(@as(f32, 1), b.prob, 0.0001);
                hit = true;
            }
        }
        try std.testing.expect(hit);
    }
}

test "reward group rolls fixed first picks or prob-weighted choices" {
    const xml_text =
        \\<loot>
        \\  <lootgroup name="groupQuestWeapons">
        \\    <item name="gunPistolT2" count="1" prob="1"/>
        \\    <item name="gunRifleT2" count="1" prob="1"/>
        \\    <item name="meleeClubT2" count="1" prob="1"/>
        \\  </lootgroup>
        \\</loot>
    ;
    var lt = try loadFromSlice(std.testing.allocator, xml_text);
    defer lt.deinit();
    var stacks: [8]Stack = undefined;
    // isfixed: the first two entries, deterministic.
    const nf = lt.rollGroupPicks("groupQuestWeapons", 1, 42, 2, true, &stacks, .{});
    try std.testing.expectEqual(@as(usize, 2), nf);
    try std.testing.expectEqualStrings("gunPistolT2", stacks[0].item_name);
    try std.testing.expectEqualStrings("gunRifleT2", stacks[1].item_name);
    // Weighted picks: each pick resolves to one of the three.
    const nw = lt.rollGroupPicks("groupQuestWeapons", 1, 42, 3, false, &stacks, .{});
    try std.testing.expectEqual(@as(usize, 3), nw);
    var i: usize = 0;
    while (i < nw) : (i += 1) {
        try std.testing.expect(std.mem.eql(u8, stacks[i].item_name, "gunPistolT2") or
            std.mem.eql(u8, stacks[i].item_name, "gunRifleT2") or
            std.mem.eql(u8, stacks[i].item_name, "meleeClubT2"));
    }
    // Unknown group returns nothing (fail closed).
    try std.testing.expectEqual(@as(usize, 0), lt.rollGroupPicks("noSuchGroup", 1, 1, 1, false, &stacks, .{}));
}

test "container group rolls are prob-weighted, not uniform" {
    // Stock LootContainer probability: an entry's prob weights it relative
    // to the group sum, so a 0.9 item drops ~9x as often as a 0.1 one and a
    // 0-prob item never drops. The old rollGroup picked a uniform index.
    const xml_text =
        \\<loot>
        \\  <lootgroup name="gWeighted">
        \\    <item name="commonItem" count="1" prob="0.9"/>
        \\    <item name="rareItem" count="1" prob="0.1"/>
        \\    <item name="neverItem" count="1" prob="0"/>
        \\  </lootgroup>
        \\  <lootcontainer name="cWeighted" count="1" loot_quality_template="qualityNoTier">
        \\    <item group="gWeighted"/>
        \\  </lootcontainer>
        \\</loot>
    ;
    var lt = try loadFromSlice(std.testing.allocator, xml_text);
    defer lt.deinit();
    var stacks: [8]Stack = undefined;
    var common: usize = 0;
    var rare: usize = 0;
    var never: usize = 0;
    var s: u32 = 1;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        s = s *% 1103515245 +% 12345;
        const n = lt.rollContainer("cWeighted", 1, s, &stacks, .{});
        try std.testing.expectEqual(@as(usize, 1), n);
        if (std.mem.eql(u8, stacks[0].item_name, "commonItem")) {
            common += 1;
        } else if (std.mem.eql(u8, stacks[0].item_name, "rareItem")) {
            rare += 1;
        } else {
            never += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), never);
    // ~90/10 split with a wide tolerance band (no flaky seed edge).
    try std.testing.expect(common > rare * 4);
    try std.testing.expect(common + rare == 4000);
}

test "stock loot.xml container flags parse" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();
    // unique_item + destroy_on_close="empty" on the reachable quest rewards.
    const mags = lt.containerByName("questRewardSkillMagazines").?;
    try std.testing.expect(mags.unique_item);
    try std.testing.expectEqual(@as(u8, 2), mags.destroy_on_close);
    // ignore_loot_abundance on a twitch carrier.
    const tw = lt.containerByName("twitch_tier0weapon").?;
    try std.testing.expect(tw.ignore_abundance);
}

test "stock loot: a requirement-gated entry is omitted, not rolled at 100%" {
    // `groupWorkingStiffsCrate` carries `<item group="groupWorkingStiffsBooks"
    // count="1">` with a `<requirement class="RandomRoll" value=
    // "@$perkBookwormChance">` child. Stock evaluates the roll against the cvar
    // (absent without perkBookworm = 0, so the gate refuses); the entry has no
    // `prob`, i.e. 1.0, so ignoring the requirement put a book in every crate.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();

    const crate = lt.groupByName("groupWorkingStiffsCrate") orelse return error.SkipZigTest;
    var gated = false;
    for (crate.entries[0..crate.entry_n]) |e| {
        if (std.mem.eql(u8, e.name, "groupWorkingStiffsBooks")) {
            try std.testing.expectEqual(GateKind.random_roll, e.gate.kind);
            try std.testing.expectEqualStrings("perkBookwormChance", e.gate.value_cvar);
            try std.testing.expectEqual(requirements.Compare.le, e.gate.op);
            gated = true;
        } else if (std.mem.eql(u8, e.name, "groupWorkingStiffs01")) {
            try std.testing.expectEqual(GateKind.none, e.gate.kind);
        }
    }
    try std.testing.expect(gated);

    // Collect the gated group's item names, then prove none of them can come
    // out of any crate roll while other entries still do.
    var book_names: [16][]const u8 = undefined;
    var book_n: usize = 0;
    if (lt.groupByName("groupWorkingStiffsBooks")) |books| {
        for (books.entries[0..books.entry_n]) |e| {
            if (book_n >= book_names.len) break;
            if (!e.is_group) {
                book_names[book_n] = e.name;
                book_n += 1;
            }
        }
    }
    var stacks: [max_roll_stacks]Stack = undefined;
    var produced: usize = 0;
    var seed: u32 = 1;
    while (seed <= 200) : (seed += 1) {
        const n = lt.rollGroup("groupWorkingStiffsCrate", 1, seed, &stacks, 0, "", .{});
        produced += n;
        for (stacks[0..n]) |st| {
            for (book_names[0..book_n]) |bn| {
                try std.testing.expect(!std.mem.eql(u8, st.item_name, bn));
            }
        }
    }
    // The group really rolls: a test that passed by producing nothing would
    // not prove the gated entry was omitted.
    try std.testing.expect(produced > 0);
}

test "stock loot: a Biome-gated entry rolls in its biome, omitted elsewhere" {
    // `groupShamwaySafe` (count="all") carries
    // `<item name="plantedGraceCorn1Schematic"><requirement class="Biome"
    // biomes="wasteland"/></item>` next to a RandomRoll-gated book group. The
    // biome gate is answerable at roll time (the container's own biome), so it
    // resolves; the RandomRoll stays omitted until its cvar exists.
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/loot.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();
    const g = lt.groupByName("groupShamwaySafe") orelse return error.SkipZigTest;
    var saw_biome = false;
    var saw_other = false;
    for (g.entries[0..g.entry_n]) |e| {
        if (std.mem.eql(u8, e.name, "plantedGraceCorn1Schematic")) {
            try std.testing.expectEqual(GateKind.biome, e.gate.kind);
            try std.testing.expectEqualStrings("wasteland", e.gate.biomes);
            saw_biome = true;
        }
        if (std.mem.eql(u8, e.name, "booksAllScaled")) {
            try std.testing.expectEqual(GateKind.random_roll, e.gate.kind);
            saw_other = true;
        }
    }
    try std.testing.expect(saw_biome and saw_other);

    var stacks: [32]Stack = undefined;
    const in_biome = lt.rollGroup("groupShamwaySafe", 1, 7, &stacks, 0, "", .{ .biome_name = "wasteland" });
    var got_corn = false;
    for (stacks[0..in_biome]) |st| {
        if (std.mem.eql(u8, st.item_name, "plantedGraceCorn1Schematic")) got_corn = true;
    }
    try std.testing.expect(got_corn);
    const off_biome = lt.rollGroup("groupShamwaySafe", 1, 7, &stacks, 0, "", .{ .biome_name = "forest" });
    for (stacks[0..off_biome]) |st| {
        try std.testing.expect(!std.mem.eql(u8, st.item_name, "plantedGraceCorn1Schematic"));
    }
    // No biome in the ctx: the gate cannot be answered, so it is omitted.
    const no_ctx = lt.rollGroup("groupShamwaySafe", 1, 7, &stacks, 0, "", .{});
    for (stacks[0..no_ctx]) |st| {
        try std.testing.expect(!std.mem.eql(u8, st.item_name, "plantedGraceCorn1Schematic"));
    }

    // The evaluator itself: ungated always, biome by name, other never.
    try std.testing.expect((EntryGate{}).allowed(.{}));
    try std.testing.expect(!(EntryGate{ .kind = .other }).allowed(.{ .biome_name = "wasteland" }));
    try std.testing.expect((EntryGate{ .kind = .biome, .biomes = "forest,wasteland" }).allowed(.{ .biome_name = "wasteland" }));
    try std.testing.expect(!(EntryGate{ .kind = .biome, .biomes = "forest" }).allowed(.{ .biome_name = "wasteland" }));
    try std.testing.expect(!(EntryGate{ .kind = .biome, .biomes = "forest" }).allowed(.{}));
}

test "loot requirement gates: Progression, CVar, RandomRoll and SandboxOption" {
    // `LootEntryRequirementProgression` / `CVar` / `RandomRoll` read the
    // opening player's state. The evaluator takes the same requirements.Ctx the
    // buff/perk VM uses, so the progression and cvar semantics live in one
    // place. A missing opener ctx leaves every one of them refused (the entry
    // stays omitted), which is the pre-evaluator behaviour.
    const cvars = @import("cvars.zig");
    var store: cvars.Set = .{};
    _ = store.apply("perkBookwormChance", .set, 50);
    _ = store.apply("perkBookworm", .set, 1);
    const levels = [_]requirements.NameLevel{
        .{ .name = "perkTreasureHunter", .level = 5 },
    };
    const player: requirements.Ctx = .{ .levels = &levels, .cvars = &store };
    const no_player: LootGateCtx = .{};

    // Progression: GTE 4 passes at level 5, fails at a level below it, and an
    // unknown progression name fails closed (stock ProgressionLevel refuses).
    const prog = EntryGate{ .kind = .progression, .arg = "perkTreasureHunter", .op = .ge, .value = 4 };
    try std.testing.expect(prog.allowed(.{ .player = player }));
    try std.testing.expect(!prog.allowed(no_player));
    const prog_hi = EntryGate{ .kind = .progression, .arg = "perkTreasureHunter", .op = .ge, .value = 6 };
    try std.testing.expect(!prog_hi.allowed(.{ .player = player }));
    const prog_eq5 = EntryGate{ .kind = .progression, .arg = "perkTreasureHunter", .op = .eq, .value = 5 };
    try std.testing.expect(prog_eq5.allowed(.{ .player = player }));
    const prog_unknown = EntryGate{ .kind = .progression, .arg = "perkNope", .op = .ge, .value = 1 };
    try std.testing.expect(!prog_unknown.allowed(.{ .player = player }));

    // CVar: EQ 1 passes on the set cvar, fails on another value/name.
    const cvar = EntryGate{ .kind = .cvar, .arg = "perkBookworm", .op = .eq, .value = 1 };
    try std.testing.expect(cvar.allowed(.{ .player = player }));
    const cvar_zero = EntryGate{ .kind = .cvar, .arg = "perkBookworm", .op = .eq, .value = 0 };
    try std.testing.expect(!cvar_zero.allowed(.{ .player = player }));

    // RandomRoll (`min_max="0,100" operation="LTE" value="@$perkBookwormChance"`):
    // LeftSide = Lerp(min, max, roll), RightSide = the cvar. chance 50 passes at
    // roll 0.5 and fails at 0.6; chance 100 always passes; chance 0 passes only
    // at roll 0 (the stock `RandomFloat` boundary).
    const roll50 = EntryGate{
        .kind = .random_roll,
        .op = .le,
        .value_cvar = "perkBookwormChance",
        .min_max = .{ 0, 100 },
    };
    try std.testing.expect(roll50.allowed(.{ .player = player, .roll = 0.5 }));
    try std.testing.expect(!roll50.allowed(.{ .player = player, .roll = 0.6 }));
    try std.testing.expect(!roll50.allowed(no_player));
    var zero_store: cvars.Set = .{};
    _ = zero_store.apply("perkBookwormChance", .set, 0);
    const zero_player: requirements.Ctx = .{ .levels = &levels, .cvars = &zero_store };
    try std.testing.expect(roll50.allowed(.{ .player = zero_player, .roll = 0 }));
    try std.testing.expect(!roll50.allowed(.{ .player = zero_player, .roll = 0.01 }));
    // A literal value (a modded row) needs no cvar.
    const roll_lit = EntryGate{ .kind = .random_roll, .op = .le, .value = 25, .min_max = .{ 0, 100 } };
    try std.testing.expect(roll_lit.allowed(.{ .player = player, .roll = 0.2 }));
    try std.testing.expect(!roll_lit.allowed(.{ .player = player, .roll = 0.3 }));

    // SandboxOption compares the option's value under the decoded code. Stock
    // `HarvestingOutput EQ 0` means "output disabled": a boolean-truthiness
    // test would pass where it must fail, so pin both polarities.
    const sb = @import("sandbox.zig");
    const ho = sb.optionByName("HarvestingOutput").?;
    const gate_off = EntryGate{ .kind = .sandbox, .arg = "HarvestingOutput", .op = .eq, .value = 0 };
    const gate_on = EntryGate{ .kind = .sandbox, .arg = "HarvestingOutput", .op = .eq, .value = 1 };
    // Code index 0 = the option's first value set entry (0 = disabled).
    const groups_off = [_]sb.Group{.{ .option_id = ho.id, .index = 0 }};
    const off_ctx: requirements.Ctx = .{ .levels = &levels, .cvars = &store, .sandbox_groups = &groups_off };
    try std.testing.expect(gate_off.allowed(.{ .player = off_ctx }));
    try std.testing.expect(!gate_on.allowed(.{ .player = off_ctx }));
    // The index whose LootAbundanceValues entry is 1.0 (the stock "100%").
    const ho_set = sb.findSet(ho.set_name).?;
    var one_idx: u8 = 0;
    for (ho_set.floats, 0..) |f, i| {
        if (f == 1.0) {
            one_idx = @intCast(i);
            break;
        }
    }
    const groups_on = [_]sb.Group{.{ .option_id = ho.id, .index = one_idx }};
    const on_ctx: requirements.Ctx = .{ .levels = &levels, .cvars = &store, .sandbox_groups = &groups_on };
    try std.testing.expect(!gate_off.allowed(.{ .player = on_ctx }));
    try std.testing.expect(gate_on.allowed(.{ .player = on_ctx }));
    // Unknown option / no opener refuse.
    const gate_bad = EntryGate{ .kind = .sandbox, .arg = "NoSuchOption", .op = .eq, .value = 0 };
    try std.testing.expect(!gate_bad.allowed(.{ .player = off_ctx }));
    try std.testing.expect(!gate_off.allowed(no_player));
}

test "loot requirement gates: parse the stock shapes from XML" {
    const src =
        \\<lootcontainers>
        \\<lootcontainer name="gateTest" size="8,1" count="2">
        \\  <item name="casinoCoin" count="100,200">
        \\    <requirement class="Progression" name="perkTreasureHunter" operation="GTE" value="4"/>
        \\  </item>
        \\  <item name="resourceScrapIron">
        \\    <requirement class="RandomRoll" seed_type="Random" min_max="0,100" operation="LTE" value="@$perkBookwormChance"/>
        \\  </item>
        \\  <item name="resourceScrapBrass">
        \\    <requirement class="CVar" cvar="perkBookworm" operation="Equals" value="1"/>
        \\  </item>
        \\  <item name="resourceScrapLead">
        \\    <requirement class="SandboxOption" option="HarvestingOutput" operation="EQ" value="0"/>
        \\  </item>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    const c = lt.containerByName("gateTest") orelse return error.TestUnexpectedResult;
    // Entry order is document order; each gate keeps the class it parsed.
    try std.testing.expectEqual(GateKind.progression, c.entries[0].gate.kind);
    try std.testing.expectEqualStrings("perkTreasureHunter", c.entries[0].gate.arg);
    try std.testing.expectEqual(requirements.Compare.ge, c.entries[0].gate.op);
    try std.testing.expectEqual(@as(f32, 4), c.entries[0].gate.value);
    try std.testing.expectEqual(GateKind.random_roll, c.entries[1].gate.kind);
    try std.testing.expectEqual(@as(f32, 0), c.entries[1].gate.min_max[0]);
    try std.testing.expectEqual(@as(f32, 100), c.entries[1].gate.min_max[1]);
    try std.testing.expectEqualStrings("perkBookwormChance", c.entries[1].gate.value_cvar);
    try std.testing.expectEqual(GateKind.cvar, c.entries[2].gate.kind);
    try std.testing.expectEqualStrings("perkBookworm", c.entries[2].gate.arg);
    // "Equals" is a stock spelling of EQ (OperationTypes).
    try std.testing.expectEqual(requirements.Compare.eq, c.entries[2].gate.op);
    // SandboxOption parses its option name and compares numerically.
    try std.testing.expectEqual(GateKind.sandbox, c.entries[3].gate.kind);
    try std.testing.expectEqualStrings("HarvestingOutput", c.entries[3].gate.arg);
    try std.testing.expectEqual(requirements.Compare.eq, c.entries[3].gate.op);
    try std.testing.expectEqual(@as(f32, 0), c.entries[3].gate.value);
}

test "abundance_type maps to the stock sandbox count options" {
    // RE loot-economy.md 8.3: `GetCountMultiplierFromSandbox(AbundanceLootModTypes)`
    // -> the per-category count modifier; the option names are the stock
    // `*LootCount` sandbox options.
    try std.testing.expectEqualStrings("FoodLootCount", abundanceOptionName("Food").?);
    try std.testing.expectEqualStrings("DrinkLootCount", abundanceOptionName("Drinks").?);
    try std.testing.expectEqualStrings("AmmoLootCount", abundanceOptionName("Ammo").?);
    try std.testing.expectEqualStrings("MedicalLootCount", abundanceOptionName("Meds").?);
    try std.testing.expectEqualStrings("ResourceLootCount", abundanceOptionName("Resources").?);
    try std.testing.expectEqualStrings("ArmorLootCount", abundanceOptionName("Armor").?);
    try std.testing.expectEqualStrings("MeleeLootCount", abundanceOptionName("Melee").?);
    try std.testing.expectEqualStrings("RangedLootCount", abundanceOptionName("Ranged").?);
    try std.testing.expectEqualStrings("DukesLootCount", abundanceOptionName("Dukes").?);
    try std.testing.expectEqualStrings("CraftingMagazinesLootCount", abundanceOptionName("Magazines").?);
    try std.testing.expectEqualStrings("BookLootCount", abundanceOptionName("Books").?);
    try std.testing.expect(abundanceOptionName("None") == null);
    try std.testing.expect(abundanceOptionName("nonsense") == null);
    // Every mapped option exists in the stock sandbox table and is a float in
    // the LootAbundanceValues set (the modifier is a multiplier, not a percent).
    const names = [_][]const u8{
        "FoodLootCount",     "DrinkLootCount",             "AmmoLootCount",  "MedicalLootCount",
        "ResourceLootCount", "ArmorLootCount",             "MeleeLootCount", "RangedLootCount",
        "DukesLootCount",    "CraftingMagazinesLootCount", "BookLootCount",
    };
    for (names) |n| {
        const o = sandbox.optionByName(n) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("LootAbundanceValues", o.set_name);
        try std.testing.expectEqual(sandbox.Kind.float, o.kind);
    }
}

test "abundance_type scales the group's counts from the sandbox code" {
    const src =
        \\<lootgroups>
        \\<lootgroup name="bookGroup" count="all" abundance_type="Books">
        \\  <item name="resourceWood" count="100"/>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    const g = lt.groupByName("bookGroup").?;
    try std.testing.expectEqualStrings("Books", g.abundance_type);

    var stacks: [max_roll_stacks]Stack = undefined;
    // No sandbox ctx: the factor is 1.0 and the count is the raw 100.
    const plain = lt.rollGroup("bookGroup", 1, 7, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 1), plain);
    try std.testing.expectEqual(@as(u16, 100), stacks[0].count);

    // A code carrying BookLootCount at half abundance: index 3 of
    // LootAbundanceValues = 0.5. The option id encodes to two base-26 letters,
    // so decode a real code string rather than hand-building the group.
    const opt = sandbox.optionByName("BookLootCount").?;
    var code_buf: [8]u8 = undefined;
    const code = std.fmt.bufPrint(&code_buf, "A{c}{c}D", .{
        @as(u8, 'A') + @as(u8, @intCast(opt.id / 26)),
        @as(u8, 'A') + @as(u8, @intCast(opt.id % 26)),
    }) catch unreachable;
    var decoded: [4]sandbox.Group = undefined;
    const decoded_n = sandbox.decode(code, &decoded);
    try std.testing.expectEqual(@as(usize, 1), decoded_n);
    try std.testing.expectEqual(opt.id, decoded[0].option_id);
    try std.testing.expectEqual(@as(u8, 3), decoded[0].index);
    const half = decoded[0..1];
    const player: requirements.Ctx = .{ .sandbox_groups = half };
    const scaled = lt.rollGroup("bookGroup", 1, 7, &stacks, 0, "", .{ .player = player });
    try std.testing.expectEqual(@as(usize, 1), scaled);
    try std.testing.expect(stacks[0].count < 100 and stacks[0].count >= 1);

    // Index 0 = 0.0: the category is disabled and spawns none of it.
    const off = [_]sandbox.Group{.{ .option_id = opt.id, .index = 0 }};
    const off_ctx: requirements.Ctx = .{ .sandbox_groups = &off };
    const none = lt.rollGroup("bookGroup", 1, 7, &stacks, 0, "", .{ .player = off_ctx });
    try std.testing.expectEqual(@as(usize, 0), none);
}
