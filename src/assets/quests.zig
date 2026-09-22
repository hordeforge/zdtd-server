//! Load stock `Data/Config/quests.xml` into a playable Quest catalog.
//!
//! Stock uses string quest ids + multi-phase objectives (ClearSleepers, Goto, …).
//! We map the *primary playable* objective into `ecs/quest.QuestKind` so the ECS
//! journal can progress kills / goto / trader interact without a full POI graph.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const io_fs = @import("../util/io_fs.zig");
const xml = @import("xml_util.zig");
const quest = @import("../ecs/quest.zig");
const paths = @import("paths.zig");

pub const max_list_entries: usize = 64;

/// `…/Data/Worlds/<Name>` → `…/Data/Config/quests.xml`
pub fn configPathFromMapDir(map_dir: []const u8, buf: []u8) ?[]const u8 {
    const marker = "/Worlds/";
    if (std.mem.findLast(u8, map_dir, marker)) |wi| {
        return std.fmt.bufPrint(buf, "{s}/Config/quests.xml", .{map_dir[0..wi]}) catch null;
    }
    const m2 = "Worlds/";
    if (std.mem.findLast(u8, map_dir, m2)) |w2| {
        if (w2 == 0) return null;
        // strip trailing path segment parent: map_dir[0..w2] may end without slash
        const data = if (map_dir[w2 - 1] == '/') map_dir[0 .. w2 - 1] else map_dir[0..w2];
        return std.fmt.bufPrint(buf, "{s}/Config/quests.xml", .{data}) catch null;
    }
    return null;
}

pub fn questsXmlPath(config_dir: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/quests.xml", .{config_dir});
}

fn dupe(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return arena.dupe(u8, s);
}

/// Map the phase kind of the quest's PRIMARY (highest-scored) objective to the
/// legacy QuestKind used by phase-less defs and the wire. Unknown/rally primary
/// objectives have no legacy kind (the caller falls back to goto_point).
fn classifyObjective(table: []const quest.ObjectiveKindMap, obj_type: []const u8, obj_id: ?[]const u8) ?quest.QuestKind {
    return switch (quest.kindForObjective(table, obj_type, obj_id)) {
        .kill_zombies => .kill_zombies,
        .goto_point => .goto_point,
        .fetch_item => .fetch_item,
        .trader_interact => .fetch_trader,
        .craft => .craft,
        .stay_within => .stay_within,
        .block_activate => .block_activate,
        .auto, .rally => null,
    };
}

/// Map a stock objective type -> executable phase kind (see
/// docs/GAP_ANALYSIS.md for the objective types that still collapse to `.auto`).
/// Data-driven: the catalog's `objective_kinds` table (config overrides +
/// builtin stock defaults) decides, so a new stock `type=` needs a config row,
/// not a code change. The `Goto id="trader"` special case is a stock fact.
fn classifyPhaseKind(table: []const quest.ObjectiveKindMap, obj_type: []const u8, obj_id: ?[]const u8) quest.PhaseKind {
    return quest.kindForObjective(table, obj_type, obj_id);
}

/// Extent (exclusive end) of the `<objective …>` element starting at `oi`.
fn objectiveElementEnd(body: []const u8, oi: usize) usize {
    const tag_end = std.mem.findPos(u8, body, oi, ">") orelse return body.len;
    if (tag_end > oi and body[tag_end - 1] == '/') return tag_end + 1;
    if (std.mem.findPos(u8, body, tag_end, "</objective>")) |cl| return cl + "</objective>".len;
    return tag_end + 1;
}

/// Resolve an objective's 1-based phase: `phase="N"` attribute or nested
/// `<property name="phase" value="N"/>`. Missing phase defaults to 1
/// (BaseObjective keeps Phase 0 = always-active; we approximate as phase 1).
/// Parse `<event type="...">` blocks (stock QuestClass events). Only
/// TreasureRadiusReduction exists in the stock file: a `chance` (0..1) and a
/// nested SpawnGSEnemy action (gamestage list + count range). The client
/// triggers the event mid-quest (treasure dig steps); the server rolls chance
/// and fires the spawn.
pub fn parseQuestEvents(arena: std.mem.Allocator, body: []const u8, out: *[quest.max_quest_events]quest.QuestEventSpec) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < body.len and n < quest.max_quest_events) {
        const at = std.mem.findPos(u8, body, i, "<event") orelse break;
        const gt = std.mem.findPos(u8, body, at, ">") orelse break;
        const close = std.mem.findPos(u8, body, gt, "</event>") orelse break;
        const inner = body[gt + 1 .. close];
        const typ = xml.attr(body, at, "type") orelse "";
        if (std.mem.eql(u8, typ, "TreasureRadiusReduction")) {
            var spec: quest.QuestEventSpec = .{};
            if (xml.propertyValue(inner, "chance")) |ch| {
                spec.chance = std.fmt.parseFloat(f32, ch) catch 0;
            }
            // Nested SpawnGSEnemy action (the only action the stock event has).
            if (xml.propertyValue(inner, "gamestage_list")) |g| {
                spec.spawn_list = arena.dupe(u8, g) catch "";
            }
            if (xml.propertyValue(inner, "count")) |c| {
                if (std.mem.findScalar(u8, c, '-')) |dash| {
                    spec.spawn_min = xml.parseU8(c[0..dash]) orelse 1;
                    spec.spawn_max = xml.parseU8(c[dash + 1 ..]) orelse spec.spawn_min;
                } else {
                    spec.spawn_min = xml.parseU8(c) orelse 1;
                    spec.spawn_max = spec.spawn_min;
                }
                if (spec.spawn_max < spec.spawn_min) spec.spawn_max = spec.spawn_min;
            }
            out[n] = spec;
            n += 1;
        }
        i = close + "</event>".len;
    }
    return n;
}

fn objectivePhase(body: []const u8, oi: usize, elem_end: usize) u8 {
    if (xml.attr(body, oi, "phase")) |a| {
        if (xml.parseU8(a)) |p| if (p != 0) return p;
    }
    if (xml.propertyValue(body[oi..elem_end], "phase")) |v| {
        if (xml.parseU8(v)) |p| if (p != 0) return p;
    }
    return 1;
}

/// Stock BaseObjective.Optional / ForcePhaseFinish (BaseObjective.HandleVariables
/// parses both via DynamicProperties.ParseBool, asm il): the objective attr
/// (`optional="true"`) or a nested `<property name="optional" value="true">`.
/// `el` is the whole objective element (open tag + body); xml.attr's first-`>`
/// window keeps it to the open tag.
fn objectiveFlag(el: []const u8, name: []const u8) bool {
    if (xml.attr(el, 0, name)) |a| return std.mem.eql(u8, a, "true");
    return std.mem.eql(u8, xml.propertyValue(el, name) orelse "", "true");
}

/// Count-target for one objective (value / count attr or nested item_count).
fn objectiveTarget(body: []const u8, oi: usize, elem_end: usize) u16 {
    var t: u16 = 1;
    if (xml.attr(body, oi, "value")) |v| t = xml.parseU16(v) orelse 1;
    if (xml.attr(body, oi, "count")) |cnt| t = xml.parseU16(cnt) orelse t;
    if (xml.propertyValue(body[oi..elem_end], "item_count")) |ic| t = xml.parseU16(ic) orelse t;
    return t;
}

fn objectiveScore(typ: []const u8, oid: ?[]const u8) i32 {
    if (std.mem.eql(u8, typ, "ClearSleepers")) return 100;
    if (std.mem.eql(u8, typ, "Craft") or
        std.mem.eql(u8, typ, "CraftItem") or
        std.mem.eql(u8, typ, "Recipe")) return 90;
    if (std.mem.eql(u8, typ, "StayWithin") or
        std.mem.eql(u8, typ, "StayWithinArea")) return 85;
    if (std.mem.eql(u8, typ, "FetchFromContainer") or
        std.mem.eql(u8, typ, "FetchKeep") or
        std.mem.eql(u8, typ, "FetchFromTreasure") or
        std.mem.eql(u8, typ, "TreasureChest")) return 90;
    if (std.mem.eql(u8, typ, "Goto") and oid != null and std.mem.eql(u8, oid.?, "trader")) return 85;
    if (std.mem.eql(u8, typ, "InteractWithNPC")) return 70;
    if (std.mem.eql(u8, typ, "Goto") or
        std.mem.eql(u8, typ, "RandomPOIGoto") or
        std.mem.eql(u8, typ, "ClosestPOIGoto") or
        std.mem.eql(u8, typ, "RandomGotoNPC")) return 60;
    if (std.mem.eql(u8, typ, "ReturnToNPC")) return 40;
    // Rally is the gate into a POI, never the phase's meat: it must lose to
    // every real objective sharing the phase but still beat unmodelled types.
    if (std.mem.eql(u8, typ, "RallyPoint")) return 30;
    return 10;
}

/// Prefer the "meat" objective over rally/stay/return scaffolding.
fn pickPrimaryKind(body: []const u8, kinds: []const quest.ObjectiveKindMap) struct { kind: quest.QuestKind, target: u16 } {
    var best_kind: quest.QuestKind = .goto_point;
    var best_score: i32 = -1;
    var best_target: u16 = 1;

    var i: usize = 0;
    while (i < body.len) {
        const oi = std.mem.findPos(u8, body, i, "<objective") orelse break;
        const typ = xml.attr(body, oi, "type") orelse {
            i = oi + 10;
            continue;
        };
        const oid = xml.attr(body, oi, "id");
        // Same value/count/item_count target rule as buildPhaseGraph.
        const local_target = objectiveTarget(body, oi, objectiveElementEnd(body, oi));

        const kind = classifyObjective(kinds, typ, oid) orelse {
            i = oi + 10;
            continue;
        };
        const score = objectiveScore(typ, oid);
        if (score > best_score) {
            best_score = score;
            best_kind = kind;
            best_target = if (local_target == 0) 1 else local_target;
        }
        i = oi + 10;
    }
    if (best_score < 0) return .{ .kind = .goto_point, .target = 1 };
    return .{ .kind = best_kind, .target = best_target };
}

const PhaseGraph = struct {
    phases: []const quest.PhaseSpec,
    highest_phase: u8,
    objective_phases: []const u8,
    objective_kinds: []const quest.ObjectiveWireKind,
    /// Per-flat-objective sim data (stock BaseObjective list, same order).
    objectives: []const quest.FlatObjective,
};

/// Objective `type` attribute to its stock Write shape. The client builds the
/// objective by reflection on the attribute (`GetTypeWithPrefix("Objective",
/// type)`, QuestsFromXml.il.txt:634), so the type name selects the class whose
/// Write override the body must match. Only these four override Write; every
/// other type keeps the BaseObjective shape. A wrong shape here desyncs the
/// whole objective block, not just one entry.
fn objectiveWireKind(typ: []const u8) quest.ObjectiveWireKind {
    if (std.mem.eql(u8, typ, "TreasureChest")) return .treasure_chest;
    if (std.mem.eql(u8, typ, "POIStayWithin")) return .empty;
    if (std.mem.eql(u8, typ, "StayWithin")) return .empty;
    if (std.mem.eql(u8, typ, "Time")) return .time;
    return .base;
}

/// Build the ordered phase graph from a quest body, mirroring stock
/// QuestClass.HighestPhase (max objective `phase`) and per-phase advancing
/// objective (Quest.refreshQuestCompletion). `tier` drives the kill-count boost
/// for kill objectives with no explicit count.
pub fn buildPhaseGraph(arena: std.mem.Allocator, body: []const u8, tier: u8, kinds: []const quest.ObjectiveKindMap, policy: quest.QuestPolicy) !PhaseGraph {
    const ObjInfo = struct {
        phase: u8,
        kind: quest.PhaseKind,
        score: i32,
        target: u16,
        /// ObjectiveGoto / StayWithin distance in metres (stock parses those
        /// `value`s as a float distance, GAP objective-value row); 0 = unset.
        radius: f32 = 0,
        /// nav_objects.xml class from the objective's nav_object property.
        nav_object: []const u8 = "",
        /// ClearSleepers objectives gate kills to the bound POI (stock
        /// QuestEvent_SleepersCleared).
        poi_gated: bool = false,
        /// Stock BaseObjective.Optional / ForcePhaseFinish (0 uses in the
        /// stock file; modded files). Optional objectives never block the
        /// phase; force fails the quest if left incomplete.
        optional: bool = false,
        force: bool = false,
    };
    var objs: [quest.max_phases]ObjInfo = undefined;
    var obj_phase_bytes: [quest.max_phases]u8 = undefined;
    var obj_kind_bytes: [quest.max_phases]quest.ObjectiveWireKind = undefined;
    var n: usize = 0;
    var highest: u8 = 0;

    var i: usize = 0;
    while (i < body.len and n < objs.len) {
        const oi = std.mem.findPos(u8, body, i, "<objective") orelse break;
        const elem_end = objectiveElementEnd(body, oi);
        i = oi + "<objective".len;
        const typ = xml.attr(body, oi, "type") orelse continue;
        const oid = xml.attr(body, oi, "id");
        const phase = objectivePhase(body, oi, elem_end);
        const kind = classifyPhaseKind(kinds, typ, oid);
        var target = objectiveTarget(body, oi, elem_end);
        // Kill objective with no explicit count: the `[quests]` policy drives
        // the default (ADR 0021; stock quests always ship a value, this is the
        // fallback for modded/absent ones).
        if (kind == .kill_zombies and target <= 1)
            target = @as(u16, policy.default_kill_count) + @as(u16, tier) * @as(u16, policy.kill_per_tier);
        // Goto / StayWithin: the objective value is a float distance in metres
        // (stock ObjectiveGoto::distance, asm.il 966955-966966), not a count.
        // A goto/stay phase completes on arrival inside that radius, so the
        // count requirement stays 1 and the radius is carried on the spec.
        var radius: f32 = 0;
        if (kind == .goto_point or kind == .stay_within) {
            // ObjectiveStayWithin carries its radius as a nested
            // `<property name="radius" value="25"/>` (15 stock rows); the
            // ObjectiveGoto distance rides the objective `value` attribute
            // (ObjectiveGoto::distance, asm.il 966955-966966). Read both so a
            // stay objective no longer falls back to the policy default.
            const el0 = body[oi..elem_end];
            const rad_src = if (kind == .stay_within)
                (xml.propertyValue(el0, "radius") orelse xml.attr(body, oi, "value"))
            else
                (xml.attr(body, oi, "value") orelse xml.propertyValue(el0, "radius"));
            if (rad_src) |rv| radius = std.fmt.parseFloat(f32, rv) catch 0;
            if (radius > 0) target = 1;
        }
        // The XML body text is transient; the marker class must live in the
        // catalog arena (a bare slice would dangle once the parse buffer frees).
        const nav_object_raw = xml.propertyValue(body[oi..elem_end], "nav_object") orelse "";
        const nav_object = if (nav_object_raw.len > 0) try arena.dupe(u8, nav_object_raw) else "";
        const el = body[oi..elem_end];
        objs[n] = .{
            .phase = phase,
            .kind = kind,
            .score = objectiveScore(typ, oid),
            .target = target,
            .radius = radius,
            .nav_object = nav_object,
            .poi_gated = std.mem.eql(u8, typ, "ClearSleepers"),
            .optional = objectiveFlag(el, "optional"),
            .force = objectiveFlag(el, "force_phase_finish"),
        };
        obj_phase_bytes[n] = phase;
        obj_kind_bytes[n] = objectiveWireKind(typ);
        if (phase > highest) highest = phase;
        n += 1;
    }
    if (n == 0 or highest == 0) return .{ .phases = &.{}, .highest_phase = 0, .objective_phases = &.{}, .objective_kinds = &.{}, .objectives = &.{} };
    if (highest > quest.max_phases) highest = quest.max_phases;

    const specs = try arena.alloc(quest.PhaseSpec, highest);
    var p: u8 = 1;
    while (p <= highest) : (p += 1) {
        // Pick the highest-scored non-auto objective in this phase; else auto scaffolding.
        var best_score: i32 = -1;
        var spec: quest.PhaseSpec = .{ .kind = .auto, .required = 1 };
        for (objs[0..n]) |o| {
            if (o.phase != p or o.kind == .auto) continue;
            if (o.score > best_score) {
                best_score = o.score;
                spec = .{ .kind = o.kind, .required = if (o.target == 0) 1 else o.target, .radius = o.radius, .nav_object = o.nav_object, .poi_gated = o.poi_gated };
            }
        }
        specs[p - 1] = spec;
    }

    const obj_phases = try arena.dupe(u8, obj_phase_bytes[0..n]);
    const obj_kinds = try arena.dupe(quest.ObjectiveWireKind, obj_kind_bytes[0..n]);
    // Flat objective list in document order (stock CreateQuest order). Phase 0
    // (always-active) objectives use phase 0 in the byte list too, so the
    // wire and the completion check agree.
    const flat = try arena.alloc(quest.FlatObjective, n);
    for (objs[0..n], 0..) |o, fi| {
        flat[fi] = .{
            .phase = o.phase,
            .kind = o.kind,
            // Arrival objectives (goto/stay/trader/rally) parse `value` as a
            // distance, never a count (stock ObjectiveGoto::distance), so
            // their required is 1 - the single arrival completes them. Only
            // count kinds (kill/fetch/craft/block) use the target.
            .required = if (objectiveIsArrival(o.kind)) 1 else if (o.target == 0) 1 else o.target,
            .optional = o.optional,
            .force = o.force,
            .poi_gated = o.poi_gated,
        };
    }
    return .{ .phases = specs, .highest_phase = highest, .objective_phases = obj_phases, .objective_kinds = obj_kinds, .objectives = flat };
}

/// Arrival-semantics phase kinds: the objective's `value` is a distance, not a
/// count, so the single arrival completes it.
fn objectiveIsArrival(kind: quest.PhaseKind) bool {
    return switch (kind) {
        .goto_point, .stay_within, .trader_interact, .rally => true,
        else => false,
    };
}

/// Dukes total from stock `<reward type="Item" id="{currency}" value="N">`
/// entries. Stock quests.xml has no Coin reward type: quest dukes are granted
/// as currency item rewards, so the server wallet credit must match the sum
/// of those values (the client Quest.Write already lists them as Item rewards).
/// `currency` is traders.xml root `currency_item` (stock "casinoCoin").
fn sumCoinReward(body: []const u8, currency: []const u8) u32 {
    const coin = if (currency.len > 0) currency else "casinoCoin";
    var total: u32 = 0;
    var i: usize = 0;
    while (i < body.len) {
        const ri = std.mem.findPos(u8, body, i, "<reward") orelse break;
        const gt = std.mem.findPos(u8, body, ri, ">") orelse break;
        const open = body[ri .. gt + 1];
        const typ = xml.attr(open, 0, "type") orelse {
            i = gt + 1;
            continue;
        };
        if (std.mem.eql(u8, typ, "Item")) {
            if (xml.attr(open, 0, "id")) |rid| {
                if (std.mem.eql(u8, rid, coin)) {
                    if (xml.attr(open, 0, "value")) |v| {
                        total +%= xml.parseU32(v) orelse 0;
                    }
                }
            }
        }
        i = gt + 1;
    }
    return total;
}

/// Objective-derived POI-selection metadata (stock Quest.SetupTags + objective
/// family): the quest tag union, the selector kind (RandomPOIGoto = random,
/// Goto/ClosestPOIGoto = closest) and the first Goto-family biome filter
/// (ObjectiveGoto biomeFilterType / biomeFilter). Values stay in the catalog
/// arena (`biome_filter` is arena-duped when non-empty).
const ObjectiveMeta = struct {
    tags_mask: u32 = 0,
    poi_select: quest.PoiSelectKind = .none,
    biome_type: u8 = quest.biome_filter_none,
    biome_filter: []const u8 = "",
    allow_current_poi: bool = false,
};

/// Property value with stock's `param1` variable substitution: a property
/// carrying `param1="X"` takes the quest's `<variable name="X" value=...>`
/// override when one exists, else the property's own value. Stock ships 18
/// `biome_filter_type` variables (8 AnyBiome, 10 SameBiome) overriding the
/// objective template default.
fn propertyValueVars(el: []const u8, name: []const u8, vars: []const QuestVar) ?[]const u8 {
    const pi = xml.propertyTagOffset(el, name) orelse return null;
    if (xml.attr(el, pi, "param1")) |param| {
        for (vars) |v| {
            if (std.mem.eql(u8, v.name, param)) return v.value;
        }
    }
    return xml.attr(el, pi, "value");
}

pub fn scanObjectiveMeta(arena: std.mem.Allocator, body: []const u8, vars: []const QuestVar) !ObjectiveMeta {
    var m: ObjectiveMeta = .{};
    var i: usize = 0;
    while (i < body.len) {
        const oi = std.mem.findPos(u8, body, i, "<objective") orelse break;
        const elem_end = objectiveElementEnd(body, oi);
        i = oi + "<objective".len;
        const typ = xml.attr(body, oi, "type") orelse continue;
        m.tags_mask |= quest.objectiveTag(typ);
        // Stock: RandomPOIGoto picks a random POI (GetRandomPOI*);
        // Goto/ClosestPOIGoto pick the closest (GetClosestPOIToWorldPos).
        // First family objective wins; later ones can only tighten.
        if (m.poi_select == .none) {
            if (std.mem.eql(u8, typ, "RandomPOIGoto")) {
                m.poi_select = .random;
            } else if (std.mem.eql(u8, typ, "Goto") or std.mem.eql(u8, typ, "ClosestPOIGoto")) {
                m.poi_select = .closest;
            }
        }
        const el = body[oi..elem_end];
        if (m.biome_type == quest.biome_filter_none) {
            if (propertyValueVars(el, "biome_filter_type", vars)) |bt| {
                if (std.mem.eql(u8, bt, "ExcludeBiome")) {
                    m.biome_type = quest.biome_filter_exclude;
                } else if (std.mem.eql(u8, bt, "OnlyBiome")) {
                    m.biome_type = quest.biome_filter_only;
                } else if (std.mem.eql(u8, bt, "SameBiome")) {
                    m.biome_type = quest.biome_filter_same;
                }
                if (propertyValueVars(el, "biome_filter", vars)) |bf| {
                    if (bf.len > 0) m.biome_filter = try arena.dupe(u8, bf);
                }
            }
        }
        if (!m.allow_current_poi) {
            if (xml.propertyValue(el, "allow_current_poi")) |v| {
                m.allow_current_poi = std.mem.eql(u8, v, "true");
            }
        }
    }
    return m;
}

/// Parse one quest's effective body (template content already merged). `qid`
/// is the quest name; open-tag name_key/category_key attrs pass through for the
/// rare quests that use them instead of body properties.
fn parseQuestDefBody(
    arena: std.mem.Allocator,
    qid: []const u8,
    tag_name_key: ?[]const u8,
    tag_category: ?[]const u8,
    body: []const u8,
    numeric_id: u16,
    kinds: []const quest.ObjectiveKindMap,
    policy: quest.QuestPolicy,
) !?quest.QuestDef {
    const name_key = xml.propertyValue(body, "name_key") orelse tag_name_key;
    const title_src = name_key orelse qid;
    var vars: [max_quest_vars]QuestVar = undefined;
    const var_n = parseVariables(body, &vars);
    const tier: u8 = resolveDifficultyTier(body, vars[0..var_n]);
    const completion = xml.propertyValue(body, "completiontype") orelse "Auto";
    const turn_in = std.mem.eql(u8, completion, "TurnIn");
    const cat = xml.propertyValue(body, "category_key") orelse
        tag_category orelse "quest";

    const primary = pickPrimaryKind(body, kinds);
    var target = primary.target;
    // Kill objectives without an explicit count (stock ClearSleepers always
    // omits count: the target is the POI's sleeper volume, which stock counts
    // at runtime via QuestEvent_SleepersCleared, asm ObjectiveClearSleepers
    // IL). zdtd approximates with the `[quests]` policy floor (ADR 0021) until
    // the kill objective is driven by the bound POI's sleeper volume (audit
    // B25). Provenance: PROVENANCE.md §3.7.
    if (primary.kind == .kill_zombies and target <= 1) {
        target = @as(u16, policy.default_kill_count) + @as(u16, tier) * @as(u16, policy.kill_per_tier);
    }

    // Dukes: stock grants them as currency Item rewards (no Coin reward type
    // exists in quests.xml). Fail closed: no matching reward in the body
    // means the stock quest grants no dukes, so credit 0, not an invented floor.
    const reward_coin: u32 = sumCoinReward(body, policy.currency_item);

    // Fallback quest-marker position when the quest def binds no POI rect:
    // a 50/70 center (ground-ish height) jittered deterministically per quest
    // id (FNV of the quest name), so identical quests always place alike.
    var tx: f32 = 50;
    const ty: f32 = 70;
    var tz: f32 = 50;
    if (primary.kind == .goto_point) {
        var h: u32 = 2166136261;
        for (qid) |c| {
            h ^= c;
            h *%= 16777619;
        }
        tx = @floatFromInt(@as(i32, @intCast(h % 200)) - 100);
        tz = @floatFromInt(@as(i32, @intCast((h / 200) % 200)) - 100);
    }

    const obj_count = countTags(body, "<objective");
    var reward_has_item: [quest.max_reward_flags]bool = .{false} ** quest.max_reward_flags;
    var reward_specs: [quest.max_reward_flags]quest.RewardSpec = [_]quest.RewardSpec{.{}} ** quest.max_reward_flags;
    const rew_count = parseRewardKinds(arena, body, &reward_has_item, &reward_specs);
    var action_specs: [quest.max_actions]quest.QuestActionSpec = [_]quest.QuestActionSpec{.{}} ** quest.max_actions;
    const act_count = parseActions(arena, body, &action_specs);
    var event_specs: [quest.max_quest_events]quest.QuestEventSpec = [_]quest.QuestEventSpec{.{}} ** quest.max_quest_events;
    const ev_count = parseQuestEvents(arena, body, &event_specs);

    const graph = try buildPhaseGraph(arena, body, tier, kinds, policy);
    const meta = try scanObjectiveMeta(arena, body, vars[0..var_n]);

    return .{
        .id = numeric_id,
        .kind = primary.kind,
        .name = try dupe(arena, qid),
        .title = try dupe(arena, title_src),
        .target_count = target,
        .tx = tx,
        .ty = ty,
        .tz = tz,
        .reward_coin = reward_coin,
        .difficulty_tier = tier,
        .gamestage_mod = if (xml.propertyValue(body, "gamestage_mod")) |v| std.fmt.parseFloat(f32, v) catch 0 else 0,
        .gamestage_bonus = if (xml.propertyValue(body, "gamestage_bonus")) |v| std.fmt.parseFloat(f32, v) catch 0 else 0,
        .turn_in = turn_in,
        .category = try dupe(arena, cat),
        .quest_tags = meta.tags_mask,
        .poi_select = meta.poi_select,
        .biome_filter_type = meta.biome_type,
        .biome_filter = meta.biome_filter,
        .allow_current_poi = meta.allow_current_poi,
        .objective_count = if (obj_count > 0) @min(obj_count, quest.max_phases) else 1,
        .reward_count = if (rew_count > 0) rew_count else 1,
        .reward_has_item = reward_has_item,
        .rewards = reward_specs,
        .reward_n = rew_count,
        .actions = action_specs,
        .action_n = act_count,
        .events = event_specs,
        .event_n = ev_count,
        .phases = graph.phases,
        .highest_phase = graph.highest_phase,
        .objective_phases = graph.objective_phases,
        .objective_kinds = graph.objective_kinds,
        .objectives = graph.objectives,
    };
}

fn countTags(body: []const u8, tag: []const u8) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < body.len) {
        const at = std.mem.findPos(u8, body, i, tag) orelse break;
        n +%= 1;
        i = at + tag.len;
        if (n == 255) break;
    }
    return n;
}

/// Parse `<reward type="…">` list. Item/LootItem need ItemStack after RewardIndex.
fn parseRewardKinds(arena: std.mem.Allocator, body: []const u8, has_item: *[quest.max_reward_flags]bool, rewards: *[quest.max_reward_flags]quest.RewardSpec) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < body.len and n < quest.max_reward_flags) {
        const at = std.mem.findPos(u8, body, i, "<reward") orelse break;
        const gt = std.mem.findPos(u8, body, at, ">") orelse break;
        const open = body[at .. gt + 1];
        const typ = xml.attr(open, 0, "type") orelse "";
        var spec: quest.RewardSpec = .{};
        // ischosen/isfixed gate the stock CloseQuest payout regardless of the
        // reward kind (BaseReward.isChosenReward; every stock caller passes a
        // null rewardChoice, so chosen rewards never pay server-side - the
        // player's pick rides the client inventory sync). Parsed generically
        // so a modded quests.xml marking any reward ischosen is skipped too.
        spec.is_chosen = xml.attr(open, 0, "ischosen") != null;
        spec.is_fixed = xml.attr(open, 0, "isfixed") != null;
        if (std.mem.eql(u8, typ, "Item") or std.mem.eql(u8, typ, "LootItem")) {
            spec.kind = if (std.mem.eql(u8, typ, "Item")) .item else .loot_item;
            has_item[n] = true;
            // The stock `id` attribute is the item name (e.g. casinoCoin); the
            // wire and payout resolve it through the items table later. The
            // name is arena-duped: the quest body dies when parseCatalog ends.
            if (xml.attr(open, 0, "id")) |rid| spec.item_name = arena.dupe(u8, rid) catch "";
            if (xml.attr(open, 0, "value")) |v| spec.value = xml.parseU32(v) orelse 0;
            // ischosen/isfixed parsed generically above (all reward kinds).
        } else if (std.mem.eql(u8, typ, "Exp")) {
            spec.kind = .exp;
            if (xml.attr(open, 0, "value")) |v| spec.value = xml.parseU32(v) orelse 0;
        } else if (std.mem.eql(u8, typ, "Skill")) {
            spec.kind = .skill;
        } else if (std.mem.eql(u8, typ, "SkillPoints")) {
            spec.kind = .skill_points;
            if (xml.attr(open, 0, "value")) |v| spec.value = xml.parseU32(v) orelse 0;
        } else if (std.mem.eql(u8, typ, "Quest")) {
            // RewardQuest chaining: the reward grants the named quest on
            // turn-in (stock RewardQuest / Quest.AddQuestReward).
            spec.kind = .quest;
            if (xml.attr(open, 0, "id")) |rid| spec.item_name = arena.dupe(u8, rid) catch "";
        } else if (std.mem.eql(u8, typ, "ShowMessageWindow")) {
            spec.kind = .show_message_window;
        } else {
            spec.kind = .other;
        }
        rewards[n] = spec;
        n += 1;
        i = gt + 1;
    }
    return n;
}

/// Parse `<action type="…">` elements with their inner `<property>` pairs
/// (phase, cvar, value, message, event, gamestage_list, ...). Unknown types are
/// recorded as `.other` so modded actions never crash the parse. String fields
/// are arena-duped: the quest body dies when parseCatalog ends.
pub fn parseActions(arena: std.mem.Allocator, body: []const u8, out: *[quest.max_actions]quest.QuestActionSpec) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < body.len and n < quest.max_actions) {
        const at = std.mem.findPos(u8, body, i, "<action") orelse break;
        const gt = std.mem.findPos(u8, body, at, ">") orelse break;
        const open = body[at .. gt + 1];
        const typ = xml.attr(open, 0, "type") orelse "";
        var spec: quest.QuestActionSpec = .{};
        if (std.mem.eql(u8, typ, "UnlockPOI")) {
            spec.kind = .unlock_poi;
        } else if (std.mem.eql(u8, typ, "SetCVar")) {
            spec.kind = .set_cvar;
        } else if (std.mem.eql(u8, typ, "ShowMessageWindow")) {
            spec.kind = .show_message_window;
        } else if (std.mem.eql(u8, typ, "SpawnGSEnemy")) {
            spec.kind = .spawn_gs_enemy;
        } else if (std.mem.eql(u8, typ, "GameEvent")) {
            spec.kind = .game_event;
        } else {
            spec.kind = .other;
        }
        // Inner <property name= value=> pairs until the matching </action>.
        const close = std.mem.findPos(u8, body, gt, "</action>") orelse (gt + 1);
        const inner = body[gt + 1 .. close];
        if (xml.propertyValue(inner, "phase")) |p| spec.phase = xml.parseU8(p) orelse 0;
        if (xml.propertyValue(inner, "cvar")) |c| spec.name = arena.dupe(u8, c) catch "";
        if (xml.propertyValue(inner, "value")) |v| spec.value = arena.dupe(u8, v) catch "";
        if (xml.propertyValue(inner, "message")) |m| {
            if (spec.name.len == 0) spec.name = arena.dupe(u8, m) catch "";
        }
        if (xml.propertyValue(inner, "event")) |e| {
            if (spec.name.len == 0) spec.name = arena.dupe(u8, e) catch "";
        }
        if (xml.propertyValue(inner, "gamestage_list")) |g| {
            if (spec.name.len == 0) spec.name = arena.dupe(u8, g) catch "";
        }
        // SpawnGSEnemy: `count="1-2"` (a single value means exactly that many).
        if (std.mem.eql(u8, typ, "SpawnGSEnemy")) {
            if (xml.propertyValue(inner, "count")) |c| {
                if (std.mem.findScalar(u8, c, '-')) |dash| {
                    spec.count_min = xml.parseU8(c[0..dash]) orelse 1;
                    spec.count_max = xml.parseU8(c[dash + 1 ..]) orelse spec.count_min;
                } else {
                    spec.count_min = xml.parseU8(c) orelse 1;
                    spec.count_max = spec.count_min;
                }
                if (spec.count_max < spec.count_min) spec.count_max = spec.count_min;
            }
        }
        out[n] = spec;
        n += 1;
        i = close + "</action>".len;
    }
    return n;
}

pub const max_quest_vars: usize = 8;
pub const QuestVar = struct { name: []const u8, value: []const u8 };

/// Parse `<variable name= value=>` overrides; the last occurrence wins because
/// the quest's own body is merged after the template's (T6 resolveBody), so
/// the derived quest's variables override the template's.
pub fn parseVariables(body: []const u8, out: *[max_quest_vars]QuestVar) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < body.len) {
        const vi = std.mem.findPos(u8, body, i, "<variable") orelse break;
        const name = xml.attr(body, vi, "name") orelse {
            i = vi + 9;
            continue;
        };
        const value = xml.attr(body, vi, "value") orelse {
            i = vi + 9;
            continue;
        };
        var replaced = false;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (std.mem.eql(u8, out[k].name, name)) {
                out[k].value = value;
                replaced = true;
                break;
            }
        }
        if (!replaced and n < max_quest_vars) {
            out[n] = .{ .name = name, .value = value };
            n += 1;
        }
        i = vi + 9;
    }
    return n;
}

/// Stock `difficulty_tier` is a template property carrying
/// `param1="difficulty"` (asm.il 1390474-1390510): the real tier comes from
/// the quest's `<variable name="difficulty" value="N">` override, falling back
/// to the property value when no variable names it.
pub fn resolveDifficultyTier(body: []const u8, vars: []const QuestVar) u8 {
    var i: usize = 0;
    while (i < body.len) {
        const pi = std.mem.findPos(u8, body, i, "<property") orelse break;
        const pn = xml.attr(body, pi, "name") orelse {
            i = pi + 9;
            continue;
        };
        if (std.mem.eql(u8, pn, "difficulty_tier")) {
            if (xml.attr(body, pi, "param1")) |param| {
                for (vars) |v| {
                    if (std.mem.eql(u8, v.name, param)) return xml.parseU8(v.value) orelse 0;
                }
            }
            if (xml.attr(body, pi, "value")) |v| return xml.parseU8(v) orelse 0;
            return 0;
        }
        i = pi + 9;
    }
    return 0;
}

/// Runtime PhaseKind lookup by tag name (case-sensitive; the binder's enum
/// path is comptime-only, so this is a small inline scan).
fn phaseKindFromName(name: []const u8) ?quest.PhaseKind {
    inline for (std.meta.fields(quest.PhaseKind)) |f| {
        if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// Parse the `[quests] objective_kinds` spec into an arena table with the
/// builtin stock defaults appended: `"Type=Kind, Type2=Kind2"` where Kind is a
/// PhaseKind tag name. Config rows are scanned first (they win on a matching
/// type - ADR 0021 precedence); a new stock objective type needs a config row,
/// not a code change. Malformed rows are logged and skipped.
fn parseObjectiveKinds(arena: std.mem.Allocator, spec: ?[]const u8) ![]const quest.ObjectiveKindMap {
    const s = spec orelse "";
    var tmp: std.ArrayList(quest.ObjectiveKindMap) = .empty;
    defer tmp.deinit(arena);
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == ',')) i += 1;
        if (i >= s.len) break;
        const eq = std.mem.findScalarPos(u8, s, i, '=') orelse break;
        const typ = std.mem.trim(u8, s[i..eq], " \t");
        const end = std.mem.findScalarPos(u8, s, eq + 1, ',') orelse s.len;
        const kind_str = std.mem.trim(u8, s[eq + 1 .. end], " \t");
        if (phaseKindFromName(kind_str)) |k| {
            if (typ.len > 0) try tmp.append(arena, .{ .obj_type = try dupe(arena, typ), .kind = k });
        } else {
            std.debug.print("zdtd: quests objective_kinds: unknown kind '{s}' for '{s}'; skipped\n", .{ kind_str, typ });
        }
        i = end;
    }
    const out = try arena.alloc(quest.ObjectiveKindMap, tmp.items.len + quest.builtin_objective_kinds.len);
    @memcpy(out[0..tmp.items.len], tmp.items);
    @memcpy(out[tmp.items.len..], &quest.builtin_objective_kinds);
    return out;
}

/// Parse catalog from quests.xml bytes (comments optional; stripped first).
/// `policy` carries the `[quests]` tunables (objective-kind spec + the
/// kill-count / goto / stay defaults; `QuestPolicy{}` = builtin stock values).
pub fn parseCatalog(allocator: std.mem.Allocator, xml_src: []const u8, policy: quest.QuestPolicy) !quest.Catalog {
    const clean = try xml.stripComments(allocator, xml_src);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    // Objective type -> phase kind mapping (config rows first, builtin after).
    const kinds = try parseObjectiveKinds(arena, policy.objective_kinds);

    var starter_name: []const u8 = try dupe(arena, "quest_whiteRiverCitizen1");
    var max_tier: u8 = 6;
    var qpt: u8 = 10;
    if (std.mem.find(u8, clean, "<quests")) |qi| {
        if (xml.attr(clean, qi, "starter_quest")) |s| starter_name = try dupe(arena, s);
        if (xml.attr(clean, qi, "max_quest_tier")) |s| max_tier = xml.parseU8(s) orelse 6;
        if (xml.attr(clean, qi, "quests_per_tier")) |s| qpt = xml.parseU8(s) orelse 10;
    }

    var defs_tmp: std.ArrayList(quest.QuestDef) = .empty;
    defer defs_tmp.deinit(allocator);

    // Pre-scan quest tags: name → inner body and template, for the two-pass
    // template resolution below (a derived quest's content comes from the
    // template; 67 stock quests use it, and without it they parse empty).
    var quest_body: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer quest_body.deinit(allocator);
    var quest_tpl: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer quest_tpl.deinit(allocator);
    {
        var si: usize = 0;
        while (si < clean.len) {
            const qi2 = std.mem.findPos(u8, clean, si, "<quest") orelse break;
            if (std.mem.startsWith(u8, clean[qi2..], "<quests") or std.mem.startsWith(u8, clean[qi2..], "<quest_list")) {
                si = qi2 + 7;
                continue;
            }
            const qid2 = xml.attr(clean, qi2, "id") orelse {
                si = qi2 + 6;
                continue;
            };
            const gt2 = std.mem.findPos(u8, clean, qi2, ">") orelse break;
            var body_end = gt2 + 1;
            if (!(gt2 > qi2 and clean[gt2 - 1] == '/')) {
                const cl2 = std.mem.findPos(u8, clean, gt2, "</quest>") orelse break;
                body_end = cl2;
            } else {
                // Self-closing placeholder (a quest_list entry, e.g.
                // <quest id="tier1_fetch"/>). It defines nothing and must not
                // overwrite the real quest's body in the template maps with an
                // empty slice, or template resolution merges an empty template.
                si = body_end;
                continue;
            }
            try quest_body.put(allocator, try arena.dupe(u8, qid2), clean[gt2 + 1 .. body_end]);
            if (xml.attr(clean, qi2, "template")) |t| {
                try quest_tpl.put(allocator, try arena.dupe(u8, qid2), try arena.dupe(u8, t));
            }
            si = body_end;
        }
    }

    // Effective body for a quest: its template's resolved content first, then
    // its own, so objectives/rewards accumulate in stock order and a derived
    // quest is never empty. Chains resolve outermost-first, depth-capped.
    const resolveBody = struct {
        fn call(
            ar: std.mem.Allocator,
            own: []const u8,
            name: []const u8,
            depth: u8,
            bodies: *const std.StringHashMapUnmanaged([]const u8),
            tpls: *const std.StringHashMapUnmanaged([]const u8),
        ) ?[]const u8 {
            if (depth > 8) return null;
            const tpl = tpls.get(name) orelse return null;
            const tbody = bodies.get(tpl) orelse return null;
            const parent = call(ar, tbody, tpl, depth + 1, bodies, tpls) orelse tbody;
            const out = ar.alloc(u8, parent.len + own.len) catch return null;
            @memcpy(out[0..parent.len], parent);
            @memcpy(out[parent.len..], own);
            return out;
        }
    }.call;

    var next_id: u16 = 1;
    var i: usize = 0;
    while (i < clean.len) {
        const qi = std.mem.findPos(u8, clean, i, "<quest") orelse break;
        if (std.mem.startsWith(u8, clean[qi..], "<quests")) {
            i = qi + 7;
            continue;
        }
        if (std.mem.startsWith(u8, clean[qi..], "<quest_list")) {
            i = qi + 11;
            continue;
        }
        const qid = xml.attr(clean, qi, "id") orelse {
            i = qi + 6;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, qi, ">") orelse break;
        const self_closing = gt > qi and clean[gt - 1] == '/';
        var body_end = gt + 1;
        if (!self_closing) {
            const cl = std.mem.findPos(u8, clean, gt, "</quest>") orelse break;
            body_end = cl;
        }
        if (self_closing) {
            i = gt + 1;
            continue; // placeholder/self-closing quests define nothing
        }
        const own_body = clean[gt + 1 .. body_end];
        const eff_body = if (quest_tpl.contains(qid))
            (resolveBody(arena, own_body, qid, 0, &quest_body, &quest_tpl) orelse own_body)
        else
            own_body;
        if (try parseQuestDefBody(
            arena,
            qid,
            xml.attr(clean, qi, "name_key"),
            xml.attr(clean, qi, "category_key"),
            eff_body,
            next_id,
            kinds,
            policy,
        )) |def| {
            try defs_tmp.append(allocator, def);
            next_id +%= 1;
            i = body_end + "</quest>".len;
            continue;
        }
        i = qi + 6;
    }

    const defs_slice = try arena.alloc(quest.QuestDef, defs_tmp.items.len);
    @memcpy(defs_slice, defs_tmp.items);

    var starter_id: u16 = if (defs_slice.len > 0) defs_slice[0].id else 1;
    for (defs_slice) |d| {
        if (std.mem.eql(u8, d.name, starter_name)) {
            starter_id = d.id;
            break;
        }
    }

    var lists_tmp: std.ArrayList(quest.QuestList) = .empty;
    defer lists_tmp.deinit(allocator);
    i = 0;
    while (i < clean.len) {
        const li = std.mem.findPos(u8, clean, i, "<quest_list") orelse break;
        const list_id = xml.attr(clean, li, "id") orelse {
            i = li + 11;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, li, ">") orelse break;
        const close = std.mem.findPos(u8, clean, gt + 1, "</quest_list>") orelse {
            i = gt + 1;
            continue;
        };
        const lbody = clean[gt + 1 .. close];
        var entries_tmp: [max_list_entries]u16 = undefined;
        var en: usize = 0;
        var j: usize = 0;
        while (j < lbody.len and en < max_list_entries) {
            const qref = std.mem.findPos(u8, lbody, j, "<quest") orelse break;
            if (xml.attr(lbody, qref, "id")) |ref_name| {
                for (defs_slice) |d| {
                    if (std.mem.eql(u8, d.name, ref_name)) {
                        entries_tmp[en] = d.id;
                        en += 1;
                        break;
                    }
                }
            }
            j = qref + 6;
        }
        const entries = try arena.alloc(u16, en);
        @memcpy(entries, entries_tmp[0..en]);
        try lists_tmp.append(allocator, .{
            .id = try dupe(arena, list_id),
            .entries = entries,
        });
        i = close + 13;
    }

    const lists_slice = try arena.alloc(quest.QuestList, lists_tmp.items.len);
    @memcpy(lists_slice, lists_tmp.items);

    // `<quest_tier_reward tier="N"><reward type="Quest" id="..."/></...>`:
    // stock fires the row whose tier the completion newly reaches
    // (`QuestEventManager.HandleNewCompletedQuest` walks `questTierRewards`
    // and `QuestTierReward.GiveRewards` grants the quest). The row's quest id
    // resolves to a catalog def id in document order so the runtime walk is a
    // plain index lookup; an unresolvable id keeps 0 and never fires. The
    // rewarded quest is itself parsed like any other: stock has no separate
    // quest class, so no new loader shape is needed.
    var tier_rewards_tmp: std.ArrayList(u16) = .empty;
    defer tier_rewards_tmp.deinit(allocator);
    {
        var ti: usize = 0;
        while (ti < clean.len) {
            const ri = std.mem.findPos(u8, clean, ti, "<quest_tier_reward") orelse break;
            const rgt = std.mem.findPos(u8, clean, ri, ">") orelse break;
            const close = std.mem.findPos(u8, clean, rgt + 1, "</quest_tier_reward>") orelse {
                ti = rgt + 1;
                continue;
            };
            const rw = std.mem.findPos(u8, clean, rgt + 1, "<reward") orelse {
                ti = close + "</quest_tier_reward>".len;
                continue;
            };
            if (rw >= close) {
                ti = close + "</quest_tier_reward>".len;
                continue;
            }
            const rid = xml.attr(clean, rw, "id") orelse {
                ti = close + "</quest_tier_reward>".len;
                continue;
            };
            var def_id: u16 = 0;
            for (defs_slice) |d| {
                if (std.mem.eql(u8, d.name, rid)) {
                    def_id = d.id;
                    break;
                }
            }
            try tier_rewards_tmp.append(allocator, def_id);
            ti = close + "</quest_tier_reward>".len;
        }
    }
    const tier_rewards_slice = try arena.alloc(u16, tier_rewards_tmp.items.len);
    @memcpy(tier_rewards_slice, tier_rewards_tmp.items);

    return .{
        .defs = defs_slice,
        .lists = lists_slice,
        .tier_rewards = tier_rewards_slice,
        .starter_id = starter_id,
        .starter_name = starter_name,
        .max_tier = max_tier,
        .quests_per_tier = qpt,
        .objective_kinds = kinds,
        .policy = policy,
        .source = .stock_xml,
        .arena_ptr = arena_holder,
        .source_path = "",
    };
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8, policy: quest.QuestPolicy) !quest.Catalog {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    var cat = try parseCatalog(allocator, raw, policy);
    errdefer cat.deinit();
    if (cat.arena_ptr) |ap| {
        cat.source_path = try ap.allocator().dupe(u8, path);
    }
    return cat;
}

/// Try explicit path, config dir, game dir, then map-derived Data/Config.
/// Applies modlet patches (fatal) then --config-overrides patches when set.
pub fn tryLoad(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    map_dir: ?[]const u8,
    config_dir: ?[]const u8,
    quests_path: ?[]const u8,
    policy: quest.QuestPolicy,
) !?quest.Catalog {
    var path_buf: [2048]u8 = undefined;
    // Parse/I/O failures must not look like "quests absent" (callers catch null).
    const loadLogged = struct {
        fn call(alloc: std.mem.Allocator, p: []const u8, pol: quest.QuestPolicy) !?quest.Catalog {
            return loadFromPath(alloc, p, pol) catch |err| {
                std.debug.print(
                    "zdtd: load quests.xml failed: {s} ({s})\n",
                    .{ @errorName(err), p },
                );
                return null;
            };
        }
    }.call;
    if (quests_path) |p| {
        if (!io_fs.fileExists(p)) return error.OpenFailed;
        if (!paths.hasPatches()) return loadLogged(allocator, p, policy);
        const base = try io_fs.readFileAll(allocator, p);
        defer allocator.free(base);
        var cur: []u8 = base;
        if (paths.mod_dirs.len > 0) {
            const m = try @import("xml_patch.zig").applyModDirs(allocator, cur, "quests.xml", paths.mod_dirs);
            allocator.free(cur);
            cur = m;
        }
        if (paths.override_dirs.len > 0) {
            const m2 = try @import("xml_patch.zig").applyOverrideDirs(allocator, cur, "quests.xml", paths.override_dirs);
            allocator.free(cur);
            cur = m2;
        }
        defer allocator.free(cur);
        io_fs.mkdirPath(".zdtd_cfg_cache");
        const cp = ".zdtd_cfg_cache/quests.xml";
        {
            try io_fs.writeFile(cp, cur);
        }
        return loadLogged(allocator, cp, policy);
    }
    if (paths.hasPatches()) {
        if (try paths.readConfigXml(allocator, "quests.xml", game_dir, config_dir)) |merged| {
            defer allocator.free(merged);
            io_fs.mkdirPath(".zdtd_cfg_cache");
            const cp = ".zdtd_cfg_cache/quests.xml";
            {
                try io_fs.writeFile(cp, merged);
            }
            return loadLogged(allocator, cp, policy);
        }
    }
    if (config_dir) |cd| {
        const p = try questsXmlPath(cd, &path_buf);
        if (io_fs.fileExists(p)) return loadLogged(allocator, p, policy);
    }
    if (game_dir) |gd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Config/quests.xml", .{gd});
        if (io_fs.fileExists(p)) return loadLogged(allocator, p, policy);
    }
    if (map_dir) |md| {
        if (configPathFromMapDir(md, &path_buf)) |p| {
            if (io_fs.fileExists(p)) return loadLogged(allocator, p, policy);
        }
    }
    return null;
}
