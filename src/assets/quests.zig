//! Load stock `Data/Config/quests.xml` into a playable Quest catalog.
//!
//! Stock uses string quest ids + multi-phase objectives (ClearSleepers, Goto, …).
//! We map the *primary playable* objective into `ecs/quest.QuestKind` so the ECS
//! journal can progress kills / goto / trader interact without a full POI graph.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const xml = @import("xml_util.zig");
const quest = @import("../ecs/quest.zig");

pub const max_list_entries: usize = 64;

pub fn fileExists(path: []const u8) bool {
    return io_fs.fileExistsSimple(path);
}

/// `…/Data/Worlds/<Name>` → `…/Data/Config/quests.xml`
pub fn configPathFromMapDir(map_dir: []const u8, buf: []u8) ?[]const u8 {
    const marker = "/Worlds/";
    if (std.mem.lastIndexOf(u8, map_dir, marker)) |wi| {
        return std.fmt.bufPrint(buf, "{s}/Config/quests.xml", .{map_dir[0..wi]}) catch null;
    }
    const m2 = "Worlds/";
    if (std.mem.lastIndexOf(u8, map_dir, m2)) |w2| {
        if (w2 == 0) return null;
        // strip trailing path segment parent: map_dir[0..w2] may end without slash
        const data = if (map_dir[w2 - 1] == '/') map_dir[0 .. w2 - 1] else map_dir[0..w2];
        return std.fmt.bufPrint(buf, "{s}/Config/quests.xml", .{data}) catch null;
    }
    return null;
}

pub fn questsXmlPath(config_dir: []const u8, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/quests.xml", .{config_dir});
}

fn dupe(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return try arena.dupe(u8, s);
}

fn classifyObjective(obj_type: []const u8, obj_id: ?[]const u8) ?quest.QuestKind {
    if (std.mem.eql(u8, obj_type, "ClearSleepers")) return .kill_zombies;
    if (std.mem.eql(u8, obj_type, "FetchKeep")) return .fetch_item;
    if (std.mem.eql(u8, obj_type, "FetchFromContainer")) return .fetch_item;
    if (std.mem.eql(u8, obj_type, "FetchFromTreasure")) return .fetch_item;
    if (std.mem.eql(u8, obj_type, "TreasureChest")) return .fetch_item;
    if (std.mem.eql(u8, obj_type, "InteractWithNPC")) return .fetch_trader;
    if (std.mem.eql(u8, obj_type, "ReturnToNPC")) return .fetch_trader;
    if (std.mem.eql(u8, obj_type, "Craft") or
        std.mem.eql(u8, obj_type, "CraftItem") or
        std.mem.eql(u8, obj_type, "Recipe")) return .craft;
    if (std.mem.eql(u8, obj_type, "StayWithin") or
        std.mem.eql(u8, obj_type, "StayWithinArea")) return .stay_within;
    if (std.mem.eql(u8, obj_type, "Goto") or
        std.mem.eql(u8, obj_type, "RandomPOIGoto") or
        std.mem.eql(u8, obj_type, "ClosestPOIGoto") or
        std.mem.eql(u8, obj_type, "RandomGotoNPC"))
    {
        if (obj_id) |id| {
            if (std.mem.eql(u8, id, "trader")) return .fetch_trader;
        }
        return .goto_point;
    }
    return null;
}

/// Map a stock objective type -> executable phase kind (see docs/GAP_ANALYSIS.md
/// for the objective types that still collapse to `.auto`).
fn classifyPhaseKind(obj_type: []const u8, obj_id: ?[]const u8) quest.PhaseKind {
    // ObjectiveRallyPoint (asm.il 1391077 resolves type="RallyPoint" by prefix).
    if (std.mem.eql(u8, obj_type, "RallyPoint")) return .rally;
    if (std.mem.eql(u8, obj_type, "ClearSleepers") or
        std.mem.eql(u8, obj_type, "EntityKill") or
        std.mem.eql(u8, obj_type, "AnimalKill")) return .kill_zombies;
    if (std.mem.eql(u8, obj_type, "FetchKeep") or
        std.mem.eql(u8, obj_type, "FetchFromContainer") or
        std.mem.eql(u8, obj_type, "FetchFromTreasure") or
        std.mem.eql(u8, obj_type, "TreasureChest")) return .fetch_item;
    if (std.mem.eql(u8, obj_type, "InteractWithNPC") or
        std.mem.eql(u8, obj_type, "ReturnToNPC") or
        std.mem.eql(u8, obj_type, "RandomGotoNPC")) return .trader_interact;
    if (std.mem.eql(u8, obj_type, "Craft") or
        std.mem.eql(u8, obj_type, "CraftItem") or
        std.mem.eql(u8, obj_type, "Recipe")) return .craft;
    if (std.mem.eql(u8, obj_type, "StayWithin") or
        std.mem.eql(u8, obj_type, "StayWithinArea")) return .stay_within;
    if (std.mem.eql(u8, obj_type, "Goto") or
        std.mem.eql(u8, obj_type, "RandomPOIGoto") or
        std.mem.eql(u8, obj_type, "ClosestPOIGoto") or
        std.mem.eql(u8, obj_type, "RandomGoto"))
    {
        if (obj_id) |id| {
            if (std.mem.eql(u8, id, "trader")) return .trader_interact;
        }
        return .goto_point;
    }
    return .auto;
}

/// Extent (exclusive end) of the `<objective …>` element starting at `oi`.
fn objectiveElementEnd(body: []const u8, oi: usize) usize {
    const tag_end = std.mem.indexOfPos(u8, body, oi, ">") orelse return body.len;
    if (tag_end > oi and body[tag_end - 1] == '/') return tag_end + 1;
    if (std.mem.indexOfPos(u8, body, tag_end, "</objective>")) |cl| return cl + "</objective>".len;
    return tag_end + 1;
}

/// Resolve an objective's 1-based phase: `phase="N"` attribute or nested
/// `<property name="phase" value="N"/>`. Missing phase defaults to 1
/// (BaseObjective keeps Phase 0 = always-active; we approximate as phase 1).
fn objectivePhase(body: []const u8, oi: usize, elem_end: usize) u8 {
    if (xml.attr(body, oi, "phase")) |a| {
        if (xml.parseU8(a)) |p| if (p != 0) return p;
    }
    if (xml.propertyValue(body[oi..elem_end], "phase")) |v| {
        if (xml.parseU8(v)) |p| if (p != 0) return p;
    }
    return 1;
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
fn pickPrimaryKind(body: []const u8) struct { kind: quest.QuestKind, target: u16 } {
    var best_kind: quest.QuestKind = .goto_point;
    var best_score: i32 = -1;
    var best_target: u16 = 1;

    var i: usize = 0;
    while (i < body.len) {
        const oi = std.mem.indexOfPos(u8, body, i, "<objective") orelse break;
        const typ = xml.attr(body, oi, "type") orelse {
            i = oi + 10;
            continue;
        };
        const oid = xml.attr(body, oi, "id");
        // Same value/count/item_count target rule as buildPhaseGraph.
        const local_target = objectiveTarget(body, oi, objectiveElementEnd(body, oi));

        const kind = classifyObjective(typ, oid) orelse {
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
};

/// Build the ordered phase graph from a quest body, mirroring stock
/// QuestClass.HighestPhase (max objective `phase`) and per-phase advancing
/// objective (Quest.refreshQuestCompletion). `tier` drives the kill-count boost
/// for kill objectives with no explicit count.
fn buildPhaseGraph(arena: std.mem.Allocator, body: []const u8, tier: u8) !PhaseGraph {
    const ObjInfo = struct {
        phase: u8,
        kind: quest.PhaseKind,
        score: i32,
        target: u16,
    };
    var objs: [quest.max_phases]ObjInfo = undefined;
    var obj_phase_bytes: [quest.max_phases]u8 = undefined;
    var obj_kind_bytes: [quest.max_phases]quest.ObjectiveWireKind = undefined;
    var n: usize = 0;
    var highest: u8 = 0;

    var i: usize = 0;
    while (i < body.len and n < objs.len) {
        const oi = std.mem.indexOfPos(u8, body, i, "<objective") orelse break;
        const elem_end = objectiveElementEnd(body, oi);
        i = oi + "<objective".len;
        const typ = xml.attr(body, oi, "type") orelse continue;
        const oid = xml.attr(body, oi, "id");
        const phase = objectivePhase(body, oi, elem_end);
        const kind = classifyPhaseKind(typ, oid);
        var target = objectiveTarget(body, oi, elem_end);
        if (kind == .kill_zombies and target <= 1) target = @as(u16, 3) + @as(u16, tier) * 2;
        objs[n] = .{ .phase = phase, .kind = kind, .score = objectiveScore(typ, oid), .target = target };
        obj_phase_bytes[n] = phase;
        // Objective Write subclass by type (stock CreateQuest). Everything not
        // listed writes the BaseObjective shape (FileVersion + CurrentValue).
        obj_kind_bytes[n] = if (std.mem.eql(u8, typ, "TreasureChest"))
            .treasure_chest
        else if (std.mem.eql(u8, typ, "POIStayWithin"))
            .empty
        else
            .base;
        if (phase > highest) highest = phase;
        n += 1;
    }
    if (n == 0 or highest == 0) return .{ .phases = &.{}, .highest_phase = 0, .objective_phases = &.{}, .objective_kinds = &.{} };
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
                spec = .{ .kind = o.kind, .required = if (o.target == 0) 1 else o.target };
            }
        }
        specs[p - 1] = spec;
    }

    const obj_phases = try arena.dupe(u8, obj_phase_bytes[0..n]);
    const obj_kinds = try arena.dupe(quest.ObjectiveWireKind, obj_kind_bytes[0..n]);
    return .{ .phases = specs, .highest_phase = highest, .objective_phases = obj_phases, .objective_kinds = obj_kinds };
}

/// Dukes total from stock `<reward type="Item" id="casinoCoin" value="N">`
/// entries. Stock quests.xml has no Coin reward type: quest dukes are granted
/// as casinoCoin item rewards, so the server wallet credit must match the sum
/// of those values (the client Quest.Write already lists them as Item rewards).
fn sumCoinReward(body: []const u8) u32 {
    var total: u32 = 0;
    var i: usize = 0;
    while (i < body.len) {
        const ri = std.mem.indexOfPos(u8, body, i, "<reward") orelse break;
        const gt = std.mem.indexOfPos(u8, body, ri, ">") orelse break;
        const open = body[ri .. gt + 1];
        const typ = xml.attr(open, 0, "type") orelse {
            i = gt + 1;
            continue;
        };
        if (std.mem.eql(u8, typ, "Item")) {
            if (xml.attr(open, 0, "id")) |rid| {
                if (std.mem.eql(u8, rid, "casinoCoin")) {
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

fn isSelfClosingQuestTag(xml_src: []const u8, open_lt: usize) bool {
    const gt = std.mem.indexOfPos(u8, xml_src, open_lt, ">") orelse return true;
    return gt > open_lt and xml_src[gt - 1] == '/';
}

fn parseQuestDef(
    arena: std.mem.Allocator,
    open_lt: usize,
    xml_src: []const u8,
    numeric_id: u16,
) !?quest.QuestDef {
    if (isSelfClosingQuestTag(xml_src, open_lt)) return null;
    const qid = xml.attr(xml_src, open_lt, "id") orelse return null;
    const gt = std.mem.indexOfPos(u8, xml_src, open_lt, ">") orelse return null;
    const close = std.mem.indexOfPos(u8, xml_src, gt + 1, "</quest>") orelse return null;
    return parseQuestDefBody(
        arena,
        qid,
        xml.attr(xml_src, open_lt, "name_key"),
        xml.attr(xml_src, open_lt, "category_key"),
        xml_src[gt + 1 .. close],
        numeric_id,
    );
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
) !?quest.QuestDef {
    const name_key = xml.propertyValue(body, "name_key") orelse tag_name_key;
    const title_src = name_key orelse qid;
    const tier_s = xml.propertyValue(body, "difficulty_tier");
    const tier: u8 = if (tier_s) |t| xml.parseU8(t) orelse 0 else 0;
    const completion = xml.propertyValue(body, "completiontype") orelse "Auto";
    const turn_in = std.mem.eql(u8, completion, "TurnIn");
    const cat = xml.propertyValue(body, "category_key") orelse
        tag_category orelse "quest";

    const primary = pickPrimaryKind(body);
    var target = primary.target;
    if (primary.kind == .kill_zombies and target <= 1) {
        target = @as(u16, 3) + @as(u16, tier) * 2;
    }

    // Dukes: stock grants them as casinoCoin Item rewards (no Coin reward type
    // exists in quests.xml). Fail closed: no casinoCoin reward in the body
    // means the stock quest grants no dukes, so credit 0, not an invented floor.
    const reward_coin: u32 = sumCoinReward(body);

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

    const graph = try buildPhaseGraph(arena, body, tier);

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
        .turn_in = turn_in,
        .category = try dupe(arena, cat),
        .objective_count = if (obj_count > 0) @min(obj_count, quest.max_phases) else 1,
        .reward_count = if (rew_count > 0) rew_count else 1,
        .reward_has_item = reward_has_item,
        .rewards = reward_specs,
        .reward_n = rew_count,
        .actions = action_specs,
        .action_n = act_count,
        .phases = graph.phases,
        .highest_phase = graph.highest_phase,
        .objective_phases = graph.objective_phases,
        .objective_kinds = graph.objective_kinds,
    };
}

fn countTags(body: []const u8, tag: []const u8) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < body.len) {
        const at = std.mem.indexOfPos(u8, body, i, tag) orelse break;
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
        const at = std.mem.indexOfPos(u8, body, i, "<reward") orelse break;
        const gt = std.mem.indexOfPos(u8, body, at, ">") orelse break;
        const open = body[at .. gt + 1];
        const typ = xml.attr(open, 0, "type") orelse "";
        var spec: quest.RewardSpec = .{};
        if (std.mem.eql(u8, typ, "Item") or std.mem.eql(u8, typ, "LootItem")) {
            spec.kind = if (std.mem.eql(u8, typ, "Item")) .item else .loot_item;
            has_item[n] = true;
            // The stock `id` attribute is the item name (e.g. casinoCoin); the
            // wire and payout resolve it through the items table later. The
            // name is arena-duped: the quest body dies when parseCatalog ends.
            if (xml.attr(open, 0, "id")) |rid| spec.item_name = arena.dupe(u8, rid) catch "";
            if (xml.attr(open, 0, "value")) |v| spec.value = xml.parseU32(v) orelse 0;
        } else if (std.mem.eql(u8, typ, "Exp")) {
            spec.kind = .exp;
            if (xml.attr(open, 0, "value")) |v| spec.value = xml.parseU32(v) orelse 0;
        } else if (std.mem.eql(u8, typ, "Skill")) {
            spec.kind = .skill;
        } else if (std.mem.eql(u8, typ, "SkillPoints")) {
            spec.kind = .skill_points;
            if (xml.attr(open, 0, "value")) |v| spec.value = xml.parseU32(v) orelse 0;
        } else if (std.mem.eql(u8, typ, "Quest")) {
            spec.kind = .quest;
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
fn parseActions(arena: std.mem.Allocator, body: []const u8, out: *[quest.max_actions]quest.QuestActionSpec) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < body.len and n < quest.max_actions) {
        const at = std.mem.indexOfPos(u8, body, i, "<action") orelse break;
        const gt = std.mem.indexOfPos(u8, body, at, ">") orelse break;
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
        const close = std.mem.indexOfPos(u8, body, gt, "</action>") orelse (gt + 1);
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
        out[n] = spec;
        n += 1;
        i = close + "</action>".len;
    }
    return n;
}

/// Parse catalog from quests.xml bytes (comments optional; stripped first).
pub fn parseCatalog(allocator: std.mem.Allocator, xml_src: []const u8) !quest.Catalog {
    const clean = try xml.stripComments(allocator, xml_src);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var starter_name: []const u8 = try dupe(arena, "quest_whiteRiverCitizen1");
    var max_tier: u8 = 6;
    var qpt: u8 = 10;
    if (std.mem.indexOf(u8, clean, "<quests")) |qi| {
        if (xml.attr(clean, qi, "starter_quest")) |s| starter_name = try dupe(arena, s);
        if (xml.attr(clean, qi, "max_quest_tier")) |s| max_tier = xml.parseU8(s) orelse 6;
        if (xml.attr(clean, qi, "quests_per_tier")) |s| qpt = xml.parseU8(s) orelse 10;
    }

    var defs_tmp: std.ArrayList(quest.QuestDef) = .empty;
    defer defs_tmp.deinit(allocator);

    // Pre-scan quest tags: name → inner body and template, for the two-pass
    // template resolution below (a derived quest's content comes from the
    // template; 67 stock quests use it, and without it they parse empty).
    var quest_body: std.StringHashMapUnmanaged([]const u8) = .{};
    defer quest_body.deinit(allocator);
    var quest_tpl: std.StringHashMapUnmanaged([]const u8) = .{};
    defer quest_tpl.deinit(allocator);
    {
        var si: usize = 0;
        while (si < clean.len) {
            const qi2 = std.mem.indexOfPos(u8, clean, si, "<quest") orelse break;
            if (std.mem.startsWith(u8, clean[qi2..], "<quests") or std.mem.startsWith(u8, clean[qi2..], "<quest_list")) {
                si = qi2 + 7;
                continue;
            }
            const qid2 = xml.attr(clean, qi2, "id") orelse {
                si = qi2 + 6;
                continue;
            };
            const gt2 = std.mem.indexOfPos(u8, clean, qi2, ">") orelse break;
            var body_end = gt2 + 1;
            if (!(gt2 > qi2 and clean[gt2 - 1] == '/')) {
                const cl2 = std.mem.indexOfPos(u8, clean, gt2, "</quest>") orelse break;
                body_end = cl2;
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
        const qi = std.mem.indexOfPos(u8, clean, i, "<quest") orelse break;
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
        const gt = std.mem.indexOfPos(u8, clean, qi, ">") orelse break;
        const self_closing = gt > qi and clean[gt - 1] == '/';
        var body_end = gt + 1;
        if (!self_closing) {
            const cl = std.mem.indexOfPos(u8, clean, gt, "</quest>") orelse break;
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
        const li = std.mem.indexOfPos(u8, clean, i, "<quest_list") orelse break;
        const list_id = xml.attr(clean, li, "id") orelse {
            i = li + 11;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, li, ">") orelse break;
        const close = std.mem.indexOfPos(u8, clean, gt + 1, "</quest_list>") orelse {
            i = gt + 1;
            continue;
        };
        const lbody = clean[gt + 1 .. close];
        var entries_tmp: [max_list_entries]u16 = undefined;
        var en: usize = 0;
        var j: usize = 0;
        while (j < lbody.len and en < max_list_entries) {
            const qref = std.mem.indexOfPos(u8, lbody, j, "<quest") orelse break;
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

    return .{
        .defs = defs_slice,
        .lists = lists_slice,
        .starter_id = starter_id,
        .starter_name = starter_name,
        .max_tier = max_tier,
        .quests_per_tier = qpt,
        .source = .stock_xml,
        .arena_ptr = arena_holder,
        .source_path = "",
    };
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !quest.Catalog {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    var cat = try parseCatalog(allocator, raw);
    errdefer cat.deinit();
    if (cat.arena_ptr) |ap| {
        cat.source_path = try ap.allocator().dupe(u8, path);
    }
    return cat;
}

pub fn loadFromConfigDir(allocator: std.mem.Allocator, config_dir: []const u8) !quest.Catalog {
    var buf: [2048]u8 = undefined;
    const path = try questsXmlPath(config_dir, &buf);
    return loadFromPath(allocator, path);
}

/// Try explicit path, config dir, game dir, then map-derived Data/Config.
/// Applies --config-overrides patches when set (via paths.override_dirs).
pub fn tryLoad(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    map_dir: ?[]const u8,
    config_dir: ?[]const u8,
    quests_path: ?[]const u8,
) !?quest.Catalog {
    const paths = @import("paths.zig");
    var path_buf: [2048]u8 = undefined;
    // Parse/I/O failures must not look like "quests absent" (callers catch null).
    const loadLogged = struct {
        fn call(alloc: std.mem.Allocator, p: []const u8) !?quest.Catalog {
            return loadFromPath(alloc, p) catch |err| {
                std.debug.print(
                    "zdtd: load quests.xml failed: {s} ({s})\n",
                    .{ @errorName(err), p },
                );
                return null;
            };
        }
    }.call;
    if (quests_path) |p| {
        if (!fileExists(p)) return error.OpenFailed;
        if (paths.override_dirs.len == 0) return try loadLogged(allocator, p);
        const base = try io_fs.readFileAll(allocator, p);
        defer allocator.free(base);
        const merged = try @import("xml_patch.zig").applyOverrideDirs(allocator, base, "quests.xml", paths.override_dirs);
        defer allocator.free(merged);
        io_fs.mkdirPath(allocator, ".zdtd_cfg_cache");
        const cp = ".zdtd_cfg_cache/quests.xml";
        {
            try io_fs.writeFile(allocator, cp, merged);
        }
        return try loadLogged(allocator, cp);
    }
    if (paths.override_dirs.len > 0) {
        if (try paths.readConfigXml(allocator, "quests.xml", game_dir, config_dir)) |merged| {
            defer allocator.free(merged);
            io_fs.mkdirPath(allocator, ".zdtd_cfg_cache");
            const cp = ".zdtd_cfg_cache/quests.xml";
            {
                try io_fs.writeFile(allocator, cp, merged);
            }
            return try loadLogged(allocator, cp);
        }
    }
    if (config_dir) |cd| {
        const p = try questsXmlPath(cd, &path_buf);
        if (fileExists(p)) return try loadLogged(allocator, p);
    }
    if (game_dir) |gd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Config/quests.xml", .{gd});
        if (fileExists(p)) return try loadLogged(allocator, p);
    }
    if (map_dir) |md| {
        if (configPathFromMapDir(md, &path_buf)) |p| {
            if (fileExists(p)) return try loadLogged(allocator, p);
        }
    }
    return null;
}

test "parse fixture catalog" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<!-- comment with <quest id="nope"> -->
        \\<quests max_quest_tier="2" quests_per_tier="3" starter_quest="quest_starter">
        \\  <quest id="quest_starter">
        \\    <property name="name_key" value="Starter Visit"/>
        \\    <property name="completiontype" value="TurnIn"/>
        \\    <objective type="Goto" id="trader" value="5" phase="1"/>
        \\    <objective type="InteractWithNPC" phase="2"/>
        \\    <reward type="Exp" value="500"/>
        \\  </quest>
        \\  <quest id="tier1_clear">
        \\    <property name="name_key" value="Clear POI"/>
        \\    <property name="difficulty_tier" value="1"/>
        \\    <property name="completiontype" value="TurnIn"/>
        \\    <objective type="RandomPOIGoto" phase="1"/>
        \\    <objective type="ClearSleepers">
        \\      <property name="phase" value="3"/>
        \\    </objective>
        \\    <objective type="ReturnToNPC" phase="4"/>
        \\    <reward type="Exp" value="1000"/>
        \\  </quest>
        \\  <quest id="tier1_fetch">
        \\    <property name="name_key" value="Fetch bag"/>
        \\    <property name="difficulty_tier" value="1"/>
        \\    <objective type="FetchFromContainer">
        \\      <property name="item_count" value="1"/>
        \\    </objective>
        \\    <reward type="Exp" value="400"/>
        \\  </quest>
        \\  <quest_list id="trader_jen_quests">
        \\    <quest id="tier1_clear"/>
        \\    <quest id="tier1_fetch"/>
        \\  </quest_list>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture);
    defer cat.deinit();
    try std.testing.expectEqual(@as(usize, 3), cat.defs.len);
    try std.testing.expectEqualStrings("quest_starter", cat.starter_name);
    const st = cat.byId(cat.starter_id).?;
    try std.testing.expectEqual(quest.QuestKind.fetch_trader, st.kind);
    try std.testing.expect(st.turn_in);
    // Phase graph: Goto trader (phase1) → InteractWithNPC (phase2), TurnIn.
    try std.testing.expectEqual(@as(u8, 2), st.highest_phase);
    try std.testing.expectEqual(@as(usize, 2), st.phases.len);
    try std.testing.expectEqual(quest.PhaseKind.trader_interact, st.phases[0].kind);
    try std.testing.expectEqual(quest.PhaseKind.trader_interact, st.phases[1].kind);
    const clear = cat.byName("tier1_clear").?;
    try std.testing.expectEqual(quest.QuestKind.kill_zombies, clear.kind);
    try std.testing.expect(clear.target_count >= 3);
    // Nested `<property name="phase">` honored: ClearSleepers sits at phase 3.
    try std.testing.expect(clear.highest_phase >= 4);
    try std.testing.expectEqual(quest.PhaseKind.goto_point, clear.phases[0].kind);
    try std.testing.expectEqual(quest.PhaseKind.kill_zombies, clear.phases[2].kind);
    try std.testing.expectEqual(quest.PhaseKind.trader_interact, clear.phases[3].kind);
    // Phase 2 has no objective → auto scaffolding phase.
    try std.testing.expectEqual(quest.PhaseKind.auto, clear.phases[1].kind);
    try std.testing.expectEqual(@as(usize, 3), clear.objective_phases.len);
    try std.testing.expectEqual(@as(u8, 3), clear.objective_phases[1]);
    const fetch = cat.byName("tier1_fetch").?;
    try std.testing.expectEqual(quest.QuestKind.fetch_item, fetch.kind);
    try std.testing.expectEqual(@as(usize, 1), cat.lists.len);
    try std.testing.expectEqualStrings("trader_jen_quests", cat.lists[0].id);
    try std.testing.expectEqual(@as(usize, 2), cat.lists[0].entries.len);
}

test "rally point objective becomes a rally phase without stealing one" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<quests starter_quest="tier1_rally">
        \\  <quest id="tier1_rally">
        \\    <property name="name_key" value="Rally"/>
        \\    <objective type="RandomPOIGoto" phase="1"/>
        \\    <objective type="RallyPoint" phase="2"/>
        \\    <objective type="RallyPoint" phase="3"/>
        \\    <objective type="ClearSleepers" phase="3"/>
        \\    <reward type="Exp" value="100"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture);
    defer cat.deinit();
    const d = cat.byName("tier1_rally").?;
    try std.testing.expectEqual(@as(u8, 3), d.highest_phase);
    try std.testing.expectEqual(quest.PhaseKind.goto_point, d.phases[0].kind);
    // Alone in its phase, RallyPoint drives it.
    try std.testing.expectEqual(quest.PhaseKind.rally, d.phases[1].kind);
    // Sharing a phase with real work, RallyPoint must lose.
    try std.testing.expectEqual(quest.PhaseKind.kill_zombies, d.phases[2].kind);
}

test "load stock quests.xml when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days To Die/Data/Config/quests.xml";
    if (!fileExists(path)) return;
    var cat = try loadFromPath(std.testing.allocator, path);
    defer cat.deinit();
    try std.testing.expect(cat.defs.len > 50);
    try std.testing.expectEqualStrings("quest_whiteRiverCitizen1", cat.starter_name);
    try std.testing.expect(cat.byName("quest_whiteRiverCitizen1") != null);
    try std.testing.expect(cat.byName("tier1_clear") != null);
    try std.testing.expect(cat.lists.len >= 1);
}

test "quest template inheritance fills derived quests" {
    const fixture =
        \\<quests>
        \\  <quest id="tpl_base">
        \\    <property name="name_key" value="Base"/>
        \\    <objective type="Goto" id="trader" value="5" phase="1"/>
        \\    <reward type="Exp" value="500"/>
        \\  </quest>
        \\  <quest id="derived" template="tpl_base">
        \\    <reward type="Exp" value="1000"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture);
    defer cat.deinit();
    const b = cat.byName("tpl_base").?;
    try std.testing.expect(b.objective_count >= 1);
    const d = cat.byName("derived").?;
    // The derived quest inherits the template's objective and adds its own
    // reward, so it is no longer an empty def.
    try std.testing.expect(d.objective_count >= 1);
    try std.testing.expect(d.reward_count >= 2);
}

test "objective write kinds follow objective type" {
    const fixture =
        \\<quests>
        \\  <quest id="mixed">
        \\    <objective type="Goto" phase="1"/>
        \\    <objective type="TreasureChest" phase="2"/>
        \\    <objective type="POIStayWithin" phase="3"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture);
    defer cat.deinit();
    const d = cat.byName("mixed").?;
    try std.testing.expectEqual(@as(usize, 3), d.objective_kinds.len);
    try std.testing.expectEqual(quest.ObjectiveWireKind.base, d.objective_kinds[0]);
    try std.testing.expectEqual(quest.ObjectiveWireKind.treasure_chest, d.objective_kinds[1]);
    try std.testing.expectEqual(quest.ObjectiveWireKind.empty, d.objective_kinds[2]);
}

test "reward_coin sums casinoCoin Item rewards and fails closed" {
    const fixture =
        \\<quests>
        \\  <quest id="payday">
        \\    <reward type="Exp" value="1000"/>
        \\    <reward type="Item" id="casinoCoin" value="500"/>
        \\    <reward type="Item" id="casinoCoin" value="250"/>
        \\  </quest>
        \\  <quest id="freebie">
        \\    <reward type="Exp" value="1000"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture);
    defer cat.deinit();
    const pay = cat.byName("payday").?;
    try std.testing.expectEqual(@as(u32, 750), pay.reward_coin);
    const free = cat.byName("freebie").?;
    try std.testing.expectEqual(@as(u32, 0), free.reward_coin);
}

test "rewards parse kinds, item names and values in document order" {
    const fixture =
        \\<quests>
        \\  <quest id="rich">
        \\    <reward type="Exp" value="1000"/>
        \\    <reward type="Item" id="casinoCoin" value="500"/>
        \\    <reward type="LootItem" id="gunPistolT2" value="2"/>
        \\    <reward type="SkillPoints" value="3"/>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture);
    defer cat.deinit();
    const d = cat.byName("rich").?;
    try std.testing.expectEqual(@as(u8, 4), d.reward_n);
    try std.testing.expectEqual(quest.RewardKind.exp, d.rewards[0].kind);
    try std.testing.expectEqual(@as(u32, 1000), d.rewards[0].value);
    try std.testing.expectEqual(quest.RewardKind.item, d.rewards[1].kind);
    try std.testing.expectEqualStrings("casinoCoin", d.rewards[1].item_name);
    try std.testing.expectEqual(@as(u32, 500), d.rewards[1].value);
    try std.testing.expectEqual(quest.RewardKind.loot_item, d.rewards[2].kind);
    try std.testing.expectEqualStrings("gunPistolT2", d.rewards[2].item_name);
    try std.testing.expectEqual(@as(u32, 2), d.rewards[2].value);
    try std.testing.expectEqual(quest.RewardKind.skill_points, d.rewards[3].kind);
    // The wire ItemStack flags match the Item/LootItem kinds.
    try std.testing.expect(d.reward_has_item[1]);
    try std.testing.expect(d.reward_has_item[2]);
    try std.testing.expect(!d.reward_has_item[0]);
}

test "stock quests.xml template quests parse non-empty" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/quests.xml";
    if (!fileExists(path)) return;
    var cat = try loadFromPath(std.testing.allocator, path);
    defer cat.deinit();
    // 67 stock quests use template=; the derived challenge rewards must carry
    // the template's objectives instead of parsing as empty defs.
    const adv = cat.byName("challengegroup_reward_advanced_survival") orelse return;
    try std.testing.expect(adv.objective_count >= 1);
    try std.testing.expect(adv.reward_count >= 1);
    const homestead = cat.byName("challengegroup_reward_homesteading") orelse return;
    try std.testing.expect(homestead.objective_count >= 1);
}

test "quest actions parse types, phases and properties" {
    const fixture =
        \\<quests>
        \\  <quest id="poi_quest">
        \\    <action type="UnlockPOI">
        \\      <property name="phase" value="4"/>
        \\    </action>
        \\    <action type="SetCVar">
        \\      <property name="cvar" value="StarterQuest"/>
        \\      <property name="value" value="1"/>
        \\    </action>
        \\    <action type="SpawnGSEnemy">
        \\      <property name="gamestage_list" value="SleeperGSList"/>
        \\      <property name="count" value="1-2"/>
        \\    </action>
        \\  </quest>
        \\</quests>
    ;
    var cat = try parseCatalog(std.testing.allocator, fixture);
    defer cat.deinit();
    const d = cat.byName("poi_quest").?;
    try std.testing.expectEqual(@as(u8, 3), d.action_n);
    try std.testing.expectEqual(quest.QuestActionKind.unlock_poi, d.actions[0].kind);
    try std.testing.expectEqual(@as(u8, 4), d.actions[0].phase);
    try std.testing.expectEqual(quest.QuestActionKind.set_cvar, d.actions[1].kind);
    try std.testing.expectEqualStrings("StarterQuest", d.actions[1].name);
    try std.testing.expectEqualStrings("1", d.actions[1].value);
    try std.testing.expectEqual(quest.QuestActionKind.spawn_gs_enemy, d.actions[2].kind);
    try std.testing.expectEqualStrings("SleeperGSList", d.actions[2].name);
}
