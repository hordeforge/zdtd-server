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
        const val_s = xml.attr(body, oi, "value");
        const count_s = xml.attr(body, oi, "count");
        var local_target: u16 = 1;
        if (val_s) |v| local_target = xml.parseU16(v) orelse 1;
        if (count_s) |c| local_target = xml.parseU16(c) orelse local_target;
        const slice_end = objectiveElementEnd(body, oi);
        if (xml.propertyValue(body[oi..slice_end], "item_count")) |ic| {
            local_target = xml.parseU16(ic) orelse local_target;
        }

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
        if (phase > highest) highest = phase;
        n += 1;
    }
    if (n == 0 or highest == 0) return .{ .phases = &.{}, .highest_phase = 0, .objective_phases = &.{} };
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
    return .{ .phases = specs, .highest_phase = highest, .objective_phases = obj_phases };
}

fn sumExpReward(body: []const u8) u32 {
    var total: u32 = 0;
    var i: usize = 0;
    while (i < body.len) {
        const ri = std.mem.indexOfPos(u8, body, i, "<reward") orelse break;
        const typ = xml.attr(body, ri, "type") orelse {
            i = ri + 7;
            continue;
        };
        if (std.mem.eql(u8, typ, "Exp")) {
            if (xml.attr(body, ri, "value")) |v| {
                total +%= xml.parseU32(v) orelse 0;
            }
        }
        i = ri + 7;
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
    const body = xml_src[gt + 1 .. close];

    const name_key = xml.propertyValue(body, "name_key") orelse xml.attr(xml_src, open_lt, "name_key");
    const title_src = name_key orelse qid;
    const tier_s = xml.propertyValue(body, "difficulty_tier");
    const tier: u8 = if (tier_s) |t| xml.parseU8(t) orelse 0 else 0;
    const completion = xml.propertyValue(body, "completiontype") orelse "Auto";
    const turn_in = std.mem.eql(u8, completion, "TurnIn");
    const cat = xml.propertyValue(body, "category_key") orelse
        xml.attr(xml_src, open_lt, "category_key") orelse "quest";

    const primary = pickPrimaryKind(body);
    var target = primary.target;
    if (primary.kind == .kill_zombies and target <= 1) {
        target = @as(u16, 3) + @as(u16, tier) * 2;
    }

    const exp = sumExpReward(body);
    const reward_coin: u32 = if (exp > 0) @max(10, exp / 20) else 15;

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
    const rew_count = parseRewardKinds(body, &reward_has_item);

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
        .phases = graph.phases,
        .highest_phase = graph.highest_phase,
        .objective_phases = graph.objective_phases,
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
fn parseRewardKinds(body: []const u8, has_item: *[quest.max_reward_flags]bool) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < body.len and n < quest.max_reward_flags) {
        const at = std.mem.indexOfPos(u8, body, i, "<reward") orelse break;
        const gt = std.mem.indexOfPos(u8, body, at, ">") orelse break;
        const open = body[at .. gt + 1];
        const typ = xml.attr(open, 0, "type") orelse "";
        // Stock subclasses that Write ItemStack after BaseReward index:
        has_item[n] = std.mem.eql(u8, typ, "Item") or std.mem.eql(u8, typ, "LootItem");
        n += 1;
        i = gt + 1;
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
        if (try parseQuestDef(arena, qi, clean, next_id)) |def| {
            try defs_tmp.append(allocator, def);
            next_id +%= 1;
            if (std.mem.indexOfPos(u8, clean, qi + 6, "</quest>")) |cl| {
                i = cl + 8;
                continue;
            }
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
