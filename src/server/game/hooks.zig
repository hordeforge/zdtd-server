//! ECS hooks: sim callbacks that read Game / World state.
//! Verbatim move from game.zig — thin wrappers remain there as `ctx: ?*anyopaque` adapters.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const assets_maxdamage = @import("../../assets/maxdamage.zig");
const invsys = @import("../../ecs/inventory.zig");
const rng_util = @import("../../util/rng.zig");
const prefabs_mod = @import("../../world/prefabs.zig");
const items = @import("../../assets/items.zig");

pub fn heightAtWorld(ctx: ?*anyopaque, wx: i32, wz: i32) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const t = world_store.World.worldToChunk(wx, wz);
    g.terrain_mu.lock();
    defer g.terrain_mu.unlock();
    const ch = g.world.getOrCreate(t.pos) catch |err| {
        std.debug.print(
            "zdtd: heightAtWorld chunk ({d},{d}) failed: {s}; fallback y=61\n",
            .{ t.pos.x, t.pos.z, @errorName(err) },
        );
        return 61;
    };
    return @as(f32, @floatFromInt(ch.heightAt(t.lx, t.lz))) + 1.0;
}

pub fn spawnPoiTraders(self: *Game) void {
    const pf = if (self.world.prefabs) |*p| p else return;
    for (pf.items) |d| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const qd = pf.questData(d.name) orelse continue;
        if (qd.trader_tag.len == 0) continue;
        var cname_buf: [64]u8 = undefined;
        const cname = std.fmt.bufPrint(&cname_buf, "npcTrader{s}", .{qd.trader_tag[6..]}) catch continue;
        const def = self.entities.byName(cname) orelse continue;
        const r = @import("../../world/tts.zig").rotateLocalXZ(qd.trader_x, qd.trader_z, d.size_x, d.size_z, d.rot);
        const wx: f32 = @floatFromInt(d.x + r.x);
        const wy: f32 = @floatFromInt(d.stampY() + qd.trader_y);
        const wz: f32 = @floatFromInt(d.z + r.z);
        const nid = self.sim.spawnTrader(cname, wx, wy, wz, self.npc.traderIdForClass(cname), self.trader_wallet_dukes) orelse continue;
        if (self.sim.slotOfNetId(nid)) |s| {
            self.sim.class_id[s].hash = def.hash;
            self.sim.class_id[s].loot_list = def.loot_list;
        }
        self.fillTraderFromXml(nid);
        std.debug.print("zdtd: POI trader {s} at ({d},{d},{d}) entity={d}\n", .{ d.name, wx, @as(i32, @trunc(wy)), wz, nid });
    }
}

/// DifficultyTier (1..6) of the POI at a world XZ, from the prefab's
/// quest metadata cache (0 = no POI or no tier). Feeds GetLootStage's
/// POITierMod/Bonus (loot_settings, indexed tier-1).
pub fn poiTierAtWorld(ctx: ?*anyopaque, x: f32, z: f32) u8 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const pf = if (g.world.prefabs) |*p| p else return 0;
    const wx: i32 = @floor(x);
    const wz: i32 = @floor(z);
    for (pf.items, 0..) |d, i| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const b = pf.boundsXZ(i);
        if (wx < b.x0 or wx >= b.x1 or wz < b.z0 or wz >= b.z1) continue;
        const qd = pf.questData(d.name) orelse return 0;
        return qd.tier;
    }
    return 0;
}

pub fn poiRectAtWorld(ctx: ?*anyopaque, x: f32, z: f32) ?ecs.components.PoiRect {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const pf = if (g.world.prefabs) |*p| p else return null;
    const wx: i32 = @floor(x);
    const wz: i32 = @floor(z);
    for (pf.items, 0..) |d, i| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const b = pf.boundsXZ(i);
        if (wx < b.x0 or wx >= b.x1 or wz < b.z0 or wz >= b.z1) continue;
        return .{
            .x = @floatFromInt(b.x0),
            .y = @floatFromInt(d.y),
            .z = @floatFromInt(b.z0),
            .size_x = @floatFromInt(b.x1 - b.x0),
            .size_y = @floatFromInt(d.size_y),
            .size_z = @floatFromInt(b.z1 - b.z0),
        };
    }
    return null;
}

pub fn partySame(ctx: ?*anyopaque, a: i32, b: i32) bool {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const pa = g.parties.partyByMember(a) orelse return false;
    return pa == g.parties.partyByMember(b);
}

pub fn nearestPoiAtWorld(ctx: ?*anyopaque, x: f32, z: f32) ?ecs.components.PoiRect {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const pf = if (g.world.prefabs) |*p| p else return null;
    var best: ?ecs.components.PoiRect = null;
    var best_d: f32 = std.math.inf(f32);
    for (pf.items, 0..) |d, i| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const b = pf.boundsXZ(i);
        const cx = (@as(f32, @floatFromInt(b.x0)) + @as(f32, @floatFromInt(b.x1))) * 0.5;
        const cz = (@as(f32, @floatFromInt(b.z0)) + @as(f32, @floatFromInt(b.z1))) * 0.5;
        const dx = cx - x;
        const dz = cz - z;
        const dist = dx * dx + dz * dz;
        if (dist < best_d) {
            best_d = dist;
            best = .{
                .x = @floatFromInt(b.x0),
                .y = @floatFromInt(d.y),
                .z = @floatFromInt(b.z0),
                .size_x = @floatFromInt(b.x1 - b.x0),
                .size_y = @floatFromInt(d.size_y),
                .size_z = @floatFromInt(b.z1 - b.z0),
            };
        }
    }
    return best;
}

pub fn pathStepAt(ctx: ?*anyopaque, _: i32, _: i32, from_y: i32, tx: i32, tz: i32) ?i32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (g.terrain_snapshot_on) {
        if (g.terrain_snap.standable(tx, tz, from_y)) |y| return y;
    }
    g.terrain_mu.lock();
    defer g.terrain_mu.unlock();
    return g.world.standableWorld(tx, tz, from_y) catch null;
}

/// Stock DynamicPrefabDecorator quest-POI selection
/// (il/full-v3.1.0/_global/DynamicPrefabDecorator.il.txt; RE: 7dtd-research
/// docs/quests-challenges.md "Quest POI selection"). `.random` mirrors
/// GetRandomPOINearWorldPos / GetRandomPOINearTrader; `.closest` mirrors
/// GetClosestPOIToWorldPos. No heap: fixed stack pools + a per-call XorShift
/// seeded by world time (deterministic per tick; stock uses the shared
/// GameRandom). The per-trader used-POI history (QuestTraderData) is not
/// tracked yet, so the usedPOILocations filter is an empty set here.
pub fn questPoiSelectAt(ctx: ?*anyopaque, p: ecs.quest.QuestPoiParams) ?ecs.quest.PoiSelect {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const pf = if (g.world.prefabs) |*pf| pf else return null;

    // GetPrefabsByDifficultyTier: the pool is the prefabs of the quest's tier.
    var candidates: [max_poi_candidates]usize = undefined;
    var n: usize = 0;
    for (pf.items, 0..) |d, i| {
        if (n >= candidates.len) break;
        if (prefabs_mod.isPart(d.name)) continue;
        const qd = pf.questData(d.name) orelse continue;
        if (qd.tier != p.tier) continue;
        candidates[n] = i;
        n += 1;
    }
    if (n == 0) return null;

    if (p.kind == .random) {
        // GetRandomPOINearWorldPos / GetRandomPOINearTrader. World-pos: up to
        // 50 random attempts over the pool (IL_0202: `attempt < 50`). Trader:
        // three distance bands (GetRandomPOINearTrader IL_0078: `i < 3`),
        // starting at the preferred band and cycling; stock shuffles each
        // tier list with GameRandom per offer, which the random picks emulate.
        var rng = rng_util.XorShift32.initFromNetId(@bitCast(@as(u32, @truncate(g.sim.director.clock.worldTimeBits()))));
        const start_band: u8 = @intCast(@mod(g.sim.director.clock.worldTimeBits(), 3));
        var band_attempt: usize = 0;
        while (band_attempt < 3) : (band_attempt += 1) {
            const band: u8 = @intCast(@mod(@as(u32, start_band) + @as(u32, @intCast(band_attempt)), 3));
            var attempt: usize = 0;
            while (attempt < max_poi_attempts) : (attempt += 1) {
                const i = candidates[rng.nextBounded(@intCast(n))];
                if (selectQuestPoi(g, pf, p, i, false, band)) |sel| return sel;
            }
        }
        return null;
    }
    // GetClosestPOIToWorldPos: nearest passing candidate (unbounded max
    // search, as the caller passes -1); a no-hit retry forces SameBiome
    // (ObjectiveGoto::GetPosition second call).
    var best: ?ecs.quest.PoiSelect = null;
    var best_d: f32 = std.math.inf(f32);
    for (candidates[0..n]) |i| {
        const sel = selectQuestPoi(g, pf, p, i, true, 0) orelse continue;
        const dx = sel.center_x - p.anchor_x;
        const dz = sel.center_z - p.anchor_z;
        const d2 = dx * dx + dz * dz;
        if (d2 < best_d) {
            best_d = d2;
            best = sel;
        }
    }
    if (best != null) return best;
    if (p.biome_type != ecs.quest.biome_filter_same) {
        var retry = p;
        retry.biome_type = ecs.quest.biome_filter_same;
        retry.biome_filter = "";
        for (candidates[0..n]) |i| {
            const sel = selectQuestPoi(g, pf, retry, i, true, 0) orelse continue;
            const dx = sel.center_x - p.anchor_x;
            const dz = sel.center_z - p.anchor_z;
            const d2 = dx * dx + dz * dz;
            if (d2 < best_d) {
                best_d = d2;
                best = sel;
            }
        }
    }
    return best;
}

/// Stock selector constants (ObjectiveRandomPOIGoto.GetPosition IL_019C-01A1).
const poi_min_dist_sq: f32 = 1000.0;
const poi_max_dist_sq: f32 = 4000000.0;
/// GetRandomPOINearWorldPos loop bound (DynamicPrefabDecorator IL_0202).
const max_poi_attempts: usize = 50;
/// Tier pool cap for a single selection (stack, no heap; a world has at most
/// a few hundred POIs per tier, so truncation only affects huge maps).
const max_poi_candidates: usize = 4096;

/// Biome name at a world cell, or null (no biome map / unknown id).
fn biomeNameAt(g: *const Game, wx: i32, wz: i32) ?[]const u8 {
    const bm = g.world.biomes orelse return null;
    const id = bm.atWorld(wx, wz) orelse return null;
    return g.world.biome_layers_table.nameById(id);
}

/// One prefab candidate through the stock filter chain
/// (DynamicPrefabDecorator.GetRandomPOINearWorldPos IL_0071-01FB /
/// ValidPrefabForQuest IL=156 / GetClosestPOIToWorldPos). `biome_at_center`
/// picks the biome probe point: the bbox **origin** for the random/trader
/// paths (V_7 / V_0 in the IL), the **center** for the closest path (V_11).
fn selectQuestPoi(
    g: *Game,
    pf: *prefabs_mod.Index,
    p: ecs.quest.QuestPoiParams,
    i: usize,
    biome_at_center: bool,
    trader_band: u8,
) ?ecs.quest.PoiSelect {
    const d = pf.items[i];
    const qd = pf.questData(d.name) orelse return null;
    // 1. SleeperVolumeList.AnyUsedEntry: the prefab XML must define sleeper
    //    volumes (PrefabSleeperVolumeList.ReadFromProperties calls Volume.Use
    //    per parsed volume).
    if (!qd.has_sleepers) return null;
    // 2. Prefab.GetQuestTag = questTags.Test_AllSet: every quest tag must be
    //    on the prefab.
    if (!ecs.quest.prefabMatches(ecs.quest.tagsMask(qd.tags), p.tags_mask)) return null;
    const b = pf.boundsXZ(i);
    const bbox_x: f32 = @floatFromInt(b.x0);
    const bbox_z: f32 = @floatFromInt(b.z0);
    // 3. tier: the pool is already tier-filtered (GetPrefabsByDifficultyTier
    //    re-checks the same field per attempt; identical here).
    // 4. usedPOILocations: empty set (per-trader POI history not tracked).
    // 5. CheckForPOILockouts at the bbox origin (bedroll/claim/quest-lock/
    //    player-inside with the party exemption).
    if (ecs.systems.questCheckPoiLockout(&g.sim, p.entity_id, bbox_x, bbox_z).reason != .none) return null;
    const size_x: f32 = @floatFromInt(b.x1 - b.x0);
    const size_z: f32 = @floatFromInt(b.z1 - b.z0);
    const cx = bbox_x + size_x * 0.5;
    const cz = bbox_z + size_z * 0.5;
    // 6. biome filter (stock switch IL_013D-01D9): type 1 excludes a matching
    //    biome name, type 2 requires membership in the comma list, type 3
    //    requires the anchor's biome.
    if (p.biome_type != ecs.quest.biome_filter_none) {
        const probe_x: i32 = @intFromFloat(if (biome_at_center) @floor(cx) else @floor(bbox_x));
        const probe_z: i32 = @intFromFloat(if (biome_at_center) @floor(cz) else @floor(bbox_z));
        const name = biomeNameAt(g, probe_x, probe_z);
        if (p.biome_type == ecs.quest.biome_filter_exclude) {
            if (name != null and std.mem.eql(u8, name.?, p.biome_filter)) return null;
        } else if (p.biome_type == ecs.quest.biome_filter_only) {
            if (name == null or !biomeInList(name.?, p.biome_filter)) return null;
        } else if (p.biome_type == ecs.quest.biome_filter_same) {
            const a_name = biomeNameAt(g, @intFromFloat(@floor(p.anchor_x)), @intFromFloat(@floor(p.anchor_z)));
            if (!std.mem.eql(u8, name orelse "", a_name orelse "")) return null;
        }
    }
    // GetClosestPOIToWorldPos excludes the POI the player is inside unless
    // the objective allows the current POI (allow_current_poi).
    if (p.kind == .closest and !p.allow_current_poi) {
        const rect: ecs.components.PoiRect = .{
            .x = bbox_x,
            .y = @floatFromInt(d.y),
            .z = bbox_z,
            .size_x = size_x,
            .size_y = @floatFromInt(d.size_y),
            .size_z = size_z,
        };
        if (rect.containsXZ(p.anchor_x, p.anchor_z)) return null;
    }
    // 7. distance (GetRandomPOINearWorldPos only): the trader path skips it
    //    (band lists), the closest path is unbounded (maxSearchDistance -1).
    //    Squared center distance must be strictly inside (1000, 4000000).
    if (p.kind == .random and !p.is_trader) {
        const dx = p.anchor_x - cx;
        const dz = p.anchor_z - cz;
        const d2 = dx * dx + dz * dz;
        if (!(d2 > poi_min_dist_sq and d2 < poi_max_dist_sq)) return null;
    }
    // Trader path band order: GetRandomPOINearTrader (random kind only) tries
    // the trader's preferred distance band first (0 = ≤500 m, 1 = ≤1500 m,
    // 2 = beyond). The closest path (ObjectiveGoto) never uses bands.
    if (p.is_trader and p.kind == .random) {
        const dx = p.anchor_x - bbox_x;
        const dz = p.anchor_z - bbox_z;
        const dist = @sqrt(dx * dx + dz * dz);
        const band: u8 = if (dist <= 500) 0 else if (dist <= 1500) 1 else 2;
        if (band != trader_band) return null;
    }
    const cy = g.sim.groundY(cx, cz) orelse @as(f32, @floatFromInt(d.y));
    return .{
        .rect = .{
            .x = bbox_x,
            .y = @floatFromInt(d.y),
            .z = bbox_z,
            .size_x = size_x,
            .size_y = @floatFromInt(d.size_y),
            .size_z = size_z,
        },
        .center_x = cx,
        .center_y = cy,
        .center_z = cz,
        .name = d.name,
    };
}

/// Whether a biome name is in the comma-separated filter list (stock
/// biomeFilterType=OnlyBiome `Split(',')`).
fn biomeInList(name: []const u8, list: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, std.mem.trim(u8, tok, " "), name)) return true;
    }
    return false;
}

/// Zombie AI bot snap (ADR 0026): `exact >= 0` resolves one live bot by net id
/// (any range — revenge); `exact < 0` returns the nearest live bot within
/// `range_sq` of (zx, zz) (proximity aggro). Returns net_id -1 when nothing
/// qualifies. Read-only over the BotManager, which is quiescent during the
/// parallel AI pass (bots integrate after it in the tick).
pub fn botSnapAt(ctx: ?*anyopaque, zx: f32, zz: f32, range_sq: f32, exact: i32) ecs.BotSnap {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return .{}));
    var best_id: i32 = -1;
    var best_x: f32 = 0;
    var best_z: f32 = 0;
    var best_d: f32 = if (range_sq >= 0) range_sq else std.math.inf(f32);
    for (&g.bots.bots) |*b| {
        if (!b.alive) continue;
        if (exact >= 0) {
            if (b.net_id == exact) return .{ .net_id = b.net_id, .x = b.x, .z = b.z };
            continue;
        }
        const dx = b.x - zx;
        const dz = b.z - zz;
        const d = dx * dx + dz * dz;
        if (d >= best_d) continue;
        best_id = b.net_id;
        best_x = b.x;
        best_z = b.z;
        best_d = d;
    }
    if (best_id < 0) return .{};
    return .{ .net_id = best_id, .x = best_x, .z = best_z, .d2 = best_d };
}

/// Zombie melee on a host-side bot (ADR 0026): accumulates as atomic
/// fixed-point from the parallel AI workers (damageFromWorker); the main
/// thread drains it into attributed damage after the pass joins, so the bot
/// records the zombie attacker and emits a damage event for the guest's
/// retaliation / dodge. False when the bot is gone (the melee whiffs).
pub fn botDamageAt(ctx: ?*anyopaque, bot_net: i32, attacker_net: i32, amount: f32) bool {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return false));
    return g.bots.damageFromWorker(bot_net, attacker_net, amount);
}

/// Quest-accept gate (AGENTS rule 29, Wasm-first): routes the sim's
/// acceptance decision to the plugin on_quest_accept verdicts (first non-zero
/// wins; <0 denies the accept). Resolves the peer slot to the player's net id
/// for the plugin. Unset hook = no plugins = today's behaviour.
pub fn questAcceptAt(ctx: ?*anyopaque, peer_slot: i32, def_id: u16) i32 {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return 0));
    var player: i32 = -1;
    if (peer_slot >= 0 and peer_slot < g.sim.player.len) {
        const ps: usize = @intCast(peer_slot);
        if (g.sim.mask[ps].network_id) player = g.sim.network_id[ps].id;
    }
    const sv = g.plugins.questAccept(player, def_id);
    return if (sv != 0) sv else g.wasm_plugins.questAccept(player, def_id);
}

pub fn placeBlockId(ctx: ?*anyopaque, item_id: u16) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const iname: ?[]const u8 = if (g.items.byId(item_id)) |d|
        d.name
    else if (g.items.source == .builtin and !g.stock_catalogs_requested)
        invsys.builtinStockNameFallback(item_id)
    else
        null;
    const IdCtx = struct {
        t: *const assets_maxdamage.Table,
        fn lookup(c: ?*anyopaque, n: []const u8) ?u16 {
            const s: *const @This() = @ptrCast(@alignCast(c.?));
            return s.t.idByName(n);
        }
    };
    var id_ctx: IdCtx = .{ .t = &g.maxdamage };
    const resolved = invsys.itemToBlockResolved(item_id, iname, IdCtx.lookup, &id_ctx);
    if (resolved != 0) return resolved;
    if (g.items.source == .builtin and !g.stock_catalogs_requested) return invsys.itemToBlock(item_id);
    return 0;
}

pub fn itemFuelValue(ctx: ?*anyopaque, item_id: u16) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    return g.items.fuelValueFor(item_id);
}

pub fn itemStackFor(ctx: ?*anyopaque, item_id: u16) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (g.items.byId(item_id)) |_| return g.items.stackFor(item_id);
    return invsys.maxStackBuiltin(item_id);
}

/// Block-solid probe for the AI sense LOS ray (stock CanSee's Voxel.Raycast).
/// A missing/erroring chunk counts as clear (nothing to hide behind yet).
pub fn blockSolidAt(ctx: ?*anyopaque, x: i32, y: i32, z: i32) bool {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    return g.world.isSolidWorld(x, y, z) catch false;
}

/// Water probe for the AI swim physics (stock inWaterPercent): true when the
/// cell holds water.
pub fn blockIsWaterAt(ctx: ?*anyopaque, x: i32, y: i32, z: i32) bool {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const id = g.world.blockWorld(x, y, z) catch return false;
    return g.world.isWaterId(id);
}

/// Door-id oracle: true when the block id resolves to a door (name-based, per
/// the stock door-naming set). Feeds `isSolidWorld` so open doors are
/// passable and closed doors block.
pub fn blockIsDoor(ctx: ?*anyopaque, id: u16) bool {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const def = g.blocks.byId(id) orelse return false;
    return def.is_door;
}

/// Effective smell radius for a slot: stock `cSmellRadiusBleed` (25) while the
/// player carries buffInjuryBleeding, else `cSmellRadiusMin` (10). The bleed
/// radius is data-bound: resolved via the buff catalog name, never a hardcoded
/// def id (ecs/buff.zig:178 offline id 4 is the fixture table, not stock).
pub fn smellRadiusFor(ctx: ?*anyopaque, slot: ecs.Slot) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const base = g.sim.rules.ai.smell_radius;
    if (g.sim.mask[slot].buffs) {
        if (g.buffs.indexOfName("buffInjuryBleeding")) |bid| {
            if (g.sim.buffs[slot].find(bid) != null) return g.sim.rules.ai.smell_bleed_radius;
        }
    }
    return base;
}

/// ClearSleepers completion suppression (stock QuestEvent_SleepersCleared
/// removes the POI's sleeper data): mark the persistent store so a cleared
/// POI's volumes never re-arm, even across a restart (sleepers_cleared.zsc).
pub fn questClearSleepers(ctx: ?*anyopaque, rect: ecs.components.PoiRect) void {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    g.sleepers.markClearedRect(rect.x, rect.y, rect.z, rect.size_x, rect.size_y, rect.size_z);
}

/// ObjectiveClearSleepers target (audit B25): the bound POI's live sleeper
/// population. Stock counts the volume spawns at quest start; sum the
/// authored group population of every volume whose AABB intersects the quest
/// rect (falls back to the def required when the hook returns 0).
pub fn questSleeperCount(ctx: ?*anyopaque, rect: ecs.components.PoiRect) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const r0x = rect.x;
    const r0z = rect.z;
    const r1x = rect.x + rect.size_x;
    const r1z = rect.z + rect.size_z;
    var total: u16 = 0;
    for (g.sleepers.volumes) |vol| {
        if (vol.quest_cleared) continue;
        if (@as(f32, @floatFromInt(vol.x1)) <= r0x or @as(f32, @floatFromInt(vol.x0)) >= r1x) continue;
        if (@as(f32, @floatFromInt(vol.z1)) <= r0z or @as(f32, @floatFromInt(vol.z0)) >= r1z) continue;
        const pop: u16 = if (vol.group_n > 0 and vol.groups[0].max_count > 0)
            vol.groups[0].max_count
        else
            @intCast(@min(vol.spawns.len, 255));
        total = @min(@as(u16, @intCast(@as(u32, total) + @as(u32, pop))), 4096);
    }
    return total;
}

/// QuestActionSpawnGSEnemy (il/full-v3.1.0/_global/QuestActionSpawnGSEnemy):
/// spawn `count_min..count_max` gamestage-scaled enemies around the player —
/// stock SpawnQuestEntity places them at player.position + random unit
/// direction × (12 + RandomFloat*12) metres, resolving the entity via
/// GameStageDefinition.GetGameStage(list).GetStage(PartyGameStage)
/// .GetSpawnGroup(0).groupName → EntityGroups.GetRandomFromGroup. The count
/// is picked per phase-entry with a world-time-seeded stream (deterministic
/// per tick, like the POI selector).
pub fn questSpawnGsEnemy(
    ctx: ?*anyopaque,
    rect: ecs.components.PoiRect,
    gs_list: []const u8,
    count_min: u8,
    count_max: u8,
    px: f32,
    pz: f32,
) void {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (gs_list.len == 0) return;
    if (count_max < count_min) return;
    const stage: i32 = @max(0, g.partyStageAround(px, pz, g.sleeper_party_radius));
    const stage_spawn = g.gamestages.sleeperEntityGroup(gs_list, stage);
    var rng = rng_util.XorShift32.initFromNetId(@bitCast(@as(u32, @truncate(g.sim.director.clock.worldTimeBits()))));
    const count: u8 = count_min + @as(u8, @intCast(rng.nextBounded(@as(u32, count_max - count_min) + 1)));
    var n: u8 = 0;
    while (n < count) : (n += 1) {
        const def = g.resolveSleeperClass(gs_list, stage_spawn, rng.next());
        const ang = (@as(f32, @floatFromInt(rng.nextBounded(6283))) / 1000.0); // 0..2π
        const dist: f32 = 12.0 + @as(f32, @floatFromInt(rng.nextBounded(12))); // 12..23
        const ox = px + @cos(ang) * dist;
        const oz = pz + @sin(ang) * dist;
        const oy = g.sim.groundY(ox, oz) orelse rect.y;
        _ = g.sim.spawnSleeperDef(ox, oy, oz, g.entityClassOf(def));
    }
}

/// Quest POI lockout home reasons (stock CheckForPOILockouts): bit 1 = the
/// entity's respawn bedroll is inside the POI, bit 2 = a land claim overlaps
/// the POI. The claim check uses the keystone-to-center distance (claim
/// protects a radius of land_claim_size/2, stock LandClaimBlock).
pub fn homeLockout(ctx: ?*anyopaque, entity_id: i32, px: f32, pz: f32) u8 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    var bits: u8 = 0;
    var i: usize = 0;
    while (i < g.clients.len) : (i += 1) {
        const cl = &g.clients[i];
        if (!cl.joined or cl.entity_id != entity_id) continue;
        if (cl.has_bed) {
            const dx = @as(f32, @floatFromInt(cl.bed_x)) - px;
            const dz = @as(f32, @floatFromInt(cl.bed_z)) - pz;
            // A bed within 32 m of the POI center counts as inside the POI
            // footprint (the quest cannot reset the POI you respawn in).
            if (dx * dx + dz * dz < 32.0 * 32.0) bits |= 1;
        }
        break;
    }
    const half: f32 = @floatFromInt(@divTrunc(@as(i32, g.land_claim_size), 2));
    var ci: usize = 0;
    while (ci < g.land_claims_n) : (ci += 1) {
        const c = &g.land_claims[ci];
        if (c.owner_entity != entity_id) continue;
        const dx = @as(f32, @floatFromInt(c.x)) - px;
        const dz = @as(f32, @floatFromInt(c.z)) - pz;
        if (dx * dx + dz * dz < half * half) bits |= 2;
    }
    return bits;
}

/// Unit sell price for an item the trader does not stock (stock lets you
/// sell anything: EconomicValue x EconomicSellScale x SellMarkdown, RE
/// GetSellPrice). Same formula as fillTraderFromXml's stocked-entry sell.
/// 0 = cannot sell (unknown item or trader).
pub fn traderSellPrice(ctx: ?*anyopaque, item_id: u16, trader_slot: u16) u32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const d = g.items.byId(item_id) orelse return 0;
    if (d.econ == 0) return 0;
    var sell_markup: f32 = 0.02;
    if (g.sim.mask[trader_slot].trader_stock) {
        const info_id = g.sim.trader_stock[trader_slot].trader_info_id;
        if (info_id != 0) {
            if (g.traders.traderInfo(info_id)) |ti| {
                if (ti.override_sell_markup > 0) sell_markup = ti.override_sell_markup;
            }
        }
        if (sell_markup == 0.02 and g.traders.sell_markdown > 0) sell_markup = g.traders.sell_markdown;
    }
    const scaled: f64 = @as(f64, d.econ) * @as(f64, d.econ_sell_scale) * @as(f64, sell_markup);
    return @max(1, @as(u32, @intCast(@min(@as(u64, @intFromFloat(@floor(scaled))), 65535))));
}

/// Stock ItemValue.PercentUsesLeft (ItemValue.get_PercentUsesLeft IL=17):
/// `max_use <= 0 ? 1 : 1 - FastClamp01(use_times / max_use)`. `max_use` is
/// the quality-lerped DegradationMax (passive 8, get_MaxUseTimesBase IL=25)
/// with the DurabilityModifier metadata at its 1.0 default (zdtd tracks no
/// per-item durability metadata). GetSellPrice multiplies the sell base by
/// this, so a worn tool sells for less (loot-economy.md §5).
pub fn percentUsesLeft(ctx: ?*anyopaque, item_id: u16, quality: u8, use_times: f32) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const d = g.items.byId(item_id) orelse return 1;
    const max_use = maxUseTimes(d, quality);
    if (max_use == 0) return 1;
    const frac = @min(@max(use_times / @as(f32, @floatFromInt(max_use)), 0.0), 1.0);
    return 1 - frac;
}

/// MaxUseTimes for a quality (tier 1..6): the DegradationMax pair lerped
/// over (quality-1)/5 like the stock passive tier range, truncated to int
/// per get_MaxUseTimesBase's `(int)GetValue(...)` cast. 0 = no durability.
fn maxUseTimes(d: items.ItemDef, quality: u8) u32 {
    if (d.degradation_max == 0) return 0;
    const q: f32 = @floatFromInt(@max(1, @min(quality, 6)));
    const t: f32 = (q - 1.0) / 5.0;
    const v: f64 = @as(f64, d.degradation_min) + (@as(f64, d.degradation_max) - @as(f64, d.degradation_min)) * @as(f64, t);
    return @intFromFloat(v);
}
