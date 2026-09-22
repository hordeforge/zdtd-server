//! loot.xml loader: groups + containers, simple deterministic rolls.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const requirements = @import("requirements.zig");
const sandbox = @import("sandbox.zig");
const io_fs = @import("../util/io_fs.zig");
const stock_paths = @import("../util/stock_paths.zig");

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
    /// `mods="a,b"` + `mod_chance="p"` (5 stock gun entries): install item mods
    /// on the spawned item. Each name is a mod tag (a slot tag like
    /// `barrelAttachments`, or a contributed tag like `scope`); stock rolls
    /// `p` per install and halves it after each (`ItemValue.createDefaultModItems`
    /// IL_759). Arena-owned.
    mods: []const u8 = "",
    mod_chance: f32 = 0,
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
    /// `tags="a,b"` (431 stock entries): the query tag set for the player's
    /// `LootProb` passives (stock `getProbability` folds them onto the entry's
    /// probability), so a perk like perkDeadEye's `tags="rifleSkill,ammo762mm"`
    /// rows raise the odds of the entries carrying those tags. Arena-owned.
    tags: []const u8 = "",
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
/// biome); `progression` / `cvar` / `random_roll` / `sandbox` = the classes the
/// roll path answers from the opener's requirement context; `other` = a class
/// with no live rows (`QuestTags` is commented out in stock), so the entry is
/// omitted.
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
                    .boolean => @floatFromInt(@intFromBool(o.default_i != 0)),
                    .int => @floatFromInt(o.default_i),
                    .float => o.default_f,
                };
                for (player.sandbox_groups) |g| {
                    if (g.option_id != o.id) continue;
                    v = switch (o.kind) {
                        .boolean => @floatFromInt(@intFromBool(sandbox.valueB(o, g.index))),
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

/// `getProbability`'s LootProb fold: the Game resolves the opening player's
/// `LootProb` rows for the entry's own tag list.
pub const ProbScale = struct {
    ctx: ?*anyopaque = null,
    scale: *const fn (?*anyopaque, tags: []const u8, base: f32) f32,
};

/// `SpawnItem`'s LootQuantity fold: the Game resolves the opening player's
/// `LootQuantity` rows (passive 81) for the spawned item, returning the
/// scaled count. Stock queries `GetValue(81, ..., itemTags|containerTags)`
/// and truncates to int, clamped by the item MaxCount. The entry name rides
/// along so the Game can union the spawned item def's own tags (e.g.
/// casinoCoin's "dukes") with the entry's list; container tags are not
/// carried (no stock LootQuantity row keys off them).
pub const QtyScale = struct {
    ctx: ?*anyopaque = null,
    scale: *const fn (?*anyopaque, item_name: []const u8, entry_tags: []const u8, base: u16) u16,
};

pub const LootGateCtx = struct {
    biome_name: ?[]const u8 = null,
    player: ?requirements.Ctx = null,
    /// Reports the `buffs=` of every entry that actually spawned.
    buffs: ?LootBuffSink = null,
    /// Scales an entry's probability by its `tags=` list (stock
    /// `getProbability` -> `EffectManager.GetValue(79, ..., entry.tags)`, the
    /// player's LootProb passives; 128 stock rows). Null = no scaling.
    prob_scale: ?ProbScale = null,
    /// Scales a spawned stack's count by the `LootQuantity` fold (stock
    /// `SpawnItem` -> `GetValue(81, ...)` truncated to int). Null = no
    /// scaling.
    qty_scale: ?QtyScale = null,
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
pub fn abundanceOptionName(type_name: []const u8) ?[]const u8 {
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
        .boolean => @floatFromInt(@intFromBool(o.default_i != 0)),
        .int => @floatFromInt(o.default_i),
        .float => o.default_f,
    };
    for (player.sandbox_groups) |grp| {
        if (grp.option_id != o.id) continue;
        v = switch (o.kind) {
            .boolean => @floatFromInt(@intFromBool(sandbox.valueB(o, grp.index))),
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
    /// `count` picks: the number of entries the roll spawns, rolled once per
    /// fill from the min/max pair (stock `LootContainer` minCount/maxCount,
    /// LootFromXml IL_0060-0095 `ParseMinMaxCount`; absent = 1,1). 302 stock
    /// containers carry it (268 one, 33 zero, one "1,2").
    pick_min: u16 = 1,
    pick_max: u16 = 1,
    entries: [max_entries]LootEntry = [_]LootEntry{.{}} ** max_entries,
    entry_n: u8 = 0,
};

pub const Stack = struct {
    item_name: []const u8 = "",
    count: u16 = 0,
    /// Rolled ItemValue quality (loot_quality_template by loot stage); 1 for
    /// stackables without a quality tier.
    quality: u8 = 1,
    /// `mods=` / `mod_chance=` from the entry: the fill path resolves them
    /// against the spawned item's tags and mod slots.
    mods: []const u8 = "",
    mod_chance: f32 = 0,
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
    return @floatFromInt(@as(u32, @trunc(@as(f32, @floatFromInt(max_use)) * f)));
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

/// Remove `<conditional evaluator="client">` blocks from a loot body.
///
/// Stock applies those in the client build only: `XmlPatcher` runs
/// `ApplyConditionalXmlBlocks` with an evaluator, and the config a dedicated
/// server parses must not carry the client-only children. The only stock rows
/// are seven `event('christmas')` holiday-gear entries, all inside `count="all"`
/// groups (groupZpackBoss, the reinforced/hardened chest groups,
/// groupHiddenStash), so a server that flattened them put a christmas item in
/// every one of those containers all year. Bodies with no client conditional
/// are returned unchanged (no copy).
pub fn hasClientEvaluator(head: []const u8) bool {
    // XML attribute quoting is either style; stock writes double quotes.
    return std.mem.find(u8, head, "evaluator=\"client\"") != null or
        std.mem.find(u8, head, "evaluator='client'") != null;
}

pub fn stripClientConditionals(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const close_tag = "</conditional>";
    var any = false;
    var scan: usize = 0;
    while (std.mem.findPos(u8, body, scan, "<conditional")) |cs| {
        const gt = std.mem.findPos(u8, body, cs, ">") orelse break;
        const close = std.mem.findPos(u8, body, gt, close_tag) orelse break;
        if (hasClientEvaluator(body[cs..gt])) any = true;
        scan = close + close_tag.len;
    }
    if (!any) return body;
    var out: std.ArrayList(u8) = .empty;
    var from: usize = 0;
    scan = 0;
    while (std.mem.findPos(u8, body, scan, "<conditional")) |cs| {
        const gt = std.mem.findPos(u8, body, cs, ">") orelse break;
        const close = std.mem.findPos(u8, body, gt, close_tag) orelse break;
        const end = close + close_tag.len;
        if (hasClientEvaluator(body[cs..gt])) {
            try out.appendSlice(allocator, body[from..cs]);
            from = end;
        }
        scan = end;
    }
    try out.appendSlice(allocator, body[from..]);
    // toOwnedSlice: the caller frees the returned slice, so it must be the
    // exact allocation (ArrayList capacity may exceed len).
    return out.toOwnedSlice(allocator);
}

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
        const total = @as(u32, cnt) + @as(u32, @trunc(extra));
        return @intCast(@min(total, std.math.maxInt(u16)));
    }

    /// Scale a finalized stack count by the `LootQuantity` fold (stock
    /// `SpawnItem`: `(int)GetValue(81, holdingItem, count, ...)`). The sink
    /// resolves the player's rows; a 0 result drops the stack like stock's
    /// `countToSpawn < 1` early-out (IL_0058).
    fn qtyCount(self: *const LootTable, e: LootEntry, cnt: u16, ctx: LootGateCtx) u16 {
        _ = self;
        if (ctx.qty_scale) |qs| return qs.scale(qs.ctx, e.name, e.tags, cnt);
        return cnt;
    }

    fn probGate(self: *const LootTable, e: LootEntry, loot_stage: i32, s: u32, ctx: LootGateCtx) bool {
        var p = self.entryProb(e, loot_stage);
        // The entry's own `tags=` are the query set for the player's LootProb
        // passives (stock's tagged branch); an untagged entry is unscaled.
        if (ctx.prob_scale) |ps| {
            if (e.tags.len > 0) p = ps.scale(ps.ctx, e.tags, p);
        }
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
    pub fn scaleCount(self: *const LootTable, cnt: u16, apply_abundance: bool, mult: f32) u16 {
        if (mult <= 0) return 0;
        if (!apply_abundance or (self.abundance_pct == 100 and mult == 1.0)) return @max(cnt, 1);
        const pct: f32 = @as(f32, @floatFromInt(self.abundance_pct)) * mult;
        const pct_i: u32 = @trunc(@max(0, @min(pct, 65535.0)));
        const scaled = (@as(u32, cnt) * pct_i) / 100;
        // Clamp before the cast: a modded loot.xml count with a high
        // LootAbundance (stock range 1..1000) can exceed u16; saturate at
        // the stack cap rather than trapping the roll.
        return @intCast(@max(1, @min(scaled, std.math.maxInt(u16))));
    }

    pub fn deinit(self: *LootTable) void {
        arena_util.destroyHolder(&self.arena_ptr);
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
                    const cnt = self.qtyCount(e, self.stageCount(self.scaleCount(if (e.count_min > 0) e.count_min else 1, true, mult), e, loot_stage), ctx);
                    if (cnt == 0) continue; // disabled category spawns none
                    out[n] = .{
                        .item_name = e.name,
                        .count = cnt,
                        .quality = if (e.quality > 0) e.quality else self.resolveQuality(qt, loot_stage, s ^ @as(u32, i)),
                        .random_durability = e.random_durability,
                        .mods = e.mods,
                        .mod_chance = e.mod_chance,
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
                if (!self.probGate(picked, loot_stage, s, ctx)) {
                    continue;
                }
            } else if (picked.prob_template != 0 and !self.probGate(picked, loot_stage, s, ctx)) continue;
            reportBuffs(gctx, picked);
            if (picked.is_group) {
                n += self.rollGroup(picked.name, loot_stage, s, out[n..], 1, qt, ctx);
            } else {
                const cmin = picked.count_min;
                const cmax = if (picked.count_max >= cmin) picked.count_max else cmin;
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt0: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                const cnt = self.qtyCount(picked, self.stageCount(self.scaleCount(cnt0, true, mult), picked, loot_stage), ctx);
                if (cnt == 0) continue; // disabled category spawns none
                out[n] = .{
                    .item_name = picked.name,
                    .count = cnt,
                    .quality = if (picked.quality > 0) picked.quality else self.resolveQuality(qt, loot_stage, s),
                    .random_durability = picked.random_durability,
                    .mods = picked.mods,
                    .mod_chance = picked.mod_chance,
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
        if (cont.entry_n == 0 or out.len == 0) return 0;
        // count= picks, rolled once (stock LootContainer.count -> minCount/
        // maxCount, ParseMinMaxCount; default 1,1) and clamped to the slot
        // budget (Spawn IL_002A-0045 FastMin(numToSpawn, _maxItems)). count=0
        // spawns nothing, which is what the 33 stock empty containers mean.
        var s = seed ^ 0x9e3779b9;
        const picks: u16 = blk: {
            if (cont.pick_max <= cont.pick_min) break :blk cont.pick_min;
            s = s *% 1103515245 +% 12345;
            const span: u32 = @as(u32, cont.pick_max) - @as(u32, cont.pick_min) + 1;
            break :blk cont.pick_min + @as(u16, @intCast(s % span));
        };
        const budget: usize = @min(@as(usize, picks), out.len);
        if (budget == 0) return 0;
        var n: usize = 0;
        var p: usize = 0;
        while (p < budget and n < out.len) : (p += 1) {
            s = s *% 1103515245 +% 12345;
            // Prob-weighted pick per slot (stock SpawnLootItemsFromList
            // IL_0079-025D: one normalized weight draw per pick, in entry
            // order). unique_item="true" skips an entry already spawned.
            var total: u32 = 0;
            var e: u8 = 0;
            while (e < cont.entry_n) : (e += 1) {
                if (cont.unique_item and LootTable.entryAlreadySpawned(out[0..n], cont.entries[e].name)) continue;
                total +|= self.groupEntryWeight(cont.entries[e], loot_stage, ctx);
            }
            if (total == 0) break;
            const roll = s % total;
            var chosen: u8 = 0;
            var acc: u32 = 0;
            while (chosen < cont.entry_n) : (chosen += 1) {
                const ce = cont.entries[chosen];
                if (cont.unique_item and LootTable.entryAlreadySpawned(out[0..n], ce.name)) continue;
                acc +|= self.groupEntryWeight(ce, loot_stage, ctx);
                if (roll < acc) break;
            }
            if (chosen >= cont.entry_n) break;
            const picked_e = cont.entries[chosen];
            var gctx = ctx;
            gctx.roll = unitRoll(s);
            if (!picked_e.gate.allowed(gctx)) continue;
            // force_prob is the one per-pick gate (stock forceProb branch);
            // the other entries' prob was already their weight.
            if (picked_e.force_prob) {
                if (!self.probGate(picked_e, loot_stage, s, ctx)) continue;
            }
            reportBuffs(gctx, picked_e);
            if (picked_e.is_group) {
                n += self.rollGroup(picked_e.name, loot_stage, s, out[n..], 0, cont.quality_template, ctx);
            } else {
                const cmin = picked_e.count_min;
                const cmax = if (picked_e.count_max >= cmin) picked_e.count_max else cmin;
                // Full-domain ranges (0..65535) make the u16 span arithmetic
                // overflow; widen so the modulo never sees a wrapped zero.
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt0: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                const cnt = self.qtyCount(picked_e, self.stageCount(self.scaleCount(cnt0, !cont.ignore_abundance, 1.0), picked_e, loot_stage), ctx);
                if (cnt == 0) continue; // disabled category spawns none
                out[n] = .{
                    .item_name = picked_e.name,
                    .count = cnt,
                    .quality = if (picked_e.quality > 0) picked_e.quality else self.resolveQuality(cont.quality_template, loot_stage, s),
                    .random_durability = picked_e.random_durability,
                    .mods = picked_e.mods,
                    .mod_chance = picked_e.mod_chance,
                };
                n += 1;
            }
        }
        return n;
    }

    /// True when an already-rolled stack carries `name` (the container
    /// `unique_item` guard: stock keeps a used-entry list so a pick cannot
    /// repeat an entry in one fill).
    fn entryAlreadySpawned(stacks: []const Stack, name: []const u8) bool {
        for (stacks) |st| {
            if (st.item_name.len > 0 and std.mem.eql(u8, st.item_name, name)) return true;
        }
        return false;
    }

    pub fn rollGroup(self: *const LootTable, name: []const u8, loot_stage: i32, seed: u32, out: []Stack, depth: u8, inherit_template: []const u8, ctx: LootGateCtx) usize {
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
                if (e.force_prob and !self.probGate(e, loot_stage, s, ctx)) continue;
                reportBuffs(gctx, e);
                if (e.is_group) {
                    an += self.rollGroup(e.name, loot_stage, s, out[an..], depth + 1, qt, ctx);
                } else {
                    const cmin = e.count_min;
                    const cmax = if (e.count_max >= cmin) e.count_max else cmin;
                    const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                    const cnt0: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                    const cnt = self.qtyCount(e, self.stageCount(self.scaleCount(cnt0, true, mult), e, loot_stage), ctx);
                    if (cnt == 0) continue; // disabled category spawns none
                    out[an] = .{ .item_name = e.name, .count = cnt, .quality = if (e.quality > 0) e.quality else self.resolveQuality(qt, loot_stage, s), .random_durability = e.random_durability, .mods = e.mods, .mod_chance = e.mod_chance };
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
                total +|= self.groupEntryWeight(g.entries[e], loot_stage, ctx);
            }
            if (total == 0) break;
            const roll = s % total;
            var chosen: u8 = 0;
            var acc: u32 = 0;
            while (chosen < g.entry_n) : (chosen += 1) {
                acc +|= self.groupEntryWeight(g.entries[chosen], loot_stage, ctx);
                if (roll < acc) break;
            }
            if (chosen >= g.entry_n) chosen = g.entry_n - 1;
            const picked_e = g.entries[chosen];
            var gctx = ctx;
            gctx.roll = unitRoll(s);
            if (!picked_e.gate.allowed(gctx)) continue;
            // A force_prob entry rolls its prob independently on top of the
            // pick (stock forceProb branch); every other entry's prob was its
            // weight, so re-gating it here double-counted the loot stage band
            // and the LootProb fold (2026-09-13).
            reportBuffs(gctx, picked_e);
            if (picked_e.is_group) {
                n += self.rollGroup(picked_e.name, loot_stage, s, out[n..], depth + 1, qt, ctx);
            } else {
                const cmin = picked_e.count_min;
                const cmax = if (picked_e.count_max >= cmin) picked_e.count_max else cmin;
                // Same span widening as rollContainer (count="0,65535").
                const span: u32 = @as(u32, cmax) - @as(u32, cmin) + 1;
                const cnt0: u16 = if (cmax == cmin) cmin else cmin + @as(u16, @intCast(s % span));
                const cnt = self.qtyCount(picked_e, self.stageCount(self.scaleCount(cnt0, true, mult), picked_e, loot_stage), ctx);
                if (cnt == 0) continue; // disabled category spawns none
                out[n] = .{ .item_name = picked_e.name, .count = cnt, .quality = if (picked_e.quality > 0) picked_e.quality else self.resolveQuality(qt, loot_stage, s), .random_durability = picked_e.random_durability, .mods = picked_e.mods, .mod_chance = picked_e.mod_chance };
                n += 1;
            }
        }
        return n;
    }

    /// Prob weight of one entry for a weighted pick: force_prob entries weigh
    /// 1 (their prob is a per-pick gate), every other entry weighs its
    /// stage-resolved `getProbability`, which folds the player's LootProb
    /// passives for a tagged entry (stock `LootContainer.getProbability` is
    /// what `SpawnLootItemsFromList` normalizes into a weight). prob <= 0 =
    /// weight 0, unpickable.
    fn groupEntryWeight(self: *const LootTable, e: LootEntry, loot_stage: i32, ctx: LootGateCtx) u32 {
        if (e.force_prob) return 1;
        var ep = self.entryProb(e, loot_stage);
        if (ctx.prob_scale) |ps| {
            if (e.tags.len > 0) ep = ps.scale(ps.ctx, e.tags, ep);
        }
        if (!(ep > 0)) return 0;
        return @trunc(@min(ep, 10.0) * 1000.0);
    }

    /// Milliprobs for the ischosen reward weighted pick. Non-finite or
    /// non-positive probs fail closed at the weight-1 floor; finite probs
    /// cap so *1000 stays under maxInt(u32). Either way a malformed
    /// loot.xml prob can no longer trap the float->u32 cast mid-roll.
    pub fn pickWeight(prob: f32) u32 {
        if (!std.math.isFinite(prob) or prob <= 0) return 1;
        const milli: f32 = @min(prob, 4_000_000.0) * 1000.0;
        return @max(@as(u32, @trunc(milli)), 1);
    }
};

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

const loot_load = @import("loot_load.zig");
pub const loadFromPath = loot_load.loadFromPath;
pub const loadFromSlice = loot_load.loadFromSlice;
pub const tryLoad = loot_load.tryLoad;
