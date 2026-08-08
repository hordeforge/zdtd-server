//! Join bundle helpers — extracted from game.zig; helpers take *Game
//!
//! Extracted from game.zig following the chunk_stream / replicate_te / persist /
//! game_net precedent: helpers take `*Game` as first param and are called as
//! `game_join.sendTraderSnapshot(g, peer, slot)`. game.zig keeps its own methods
//! as forwarding wrappers (this swarm does not edit game.zig).
//!
//! Bodies are verbatim copies from src/server/game.zig (stock asm.il comments
//! kept). Functions already extracted elsewhere are not duplicated:
//!   sendSpawnChunk / sendSpawnArea / sendContainersInChunk → chunk_stream.zig
//! Documented here so the swarm does not re-extract them.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const wire_binary = @import("../../wire/binary.zig");
const packages = @import("../../wire/packages.zig");
const world_store = @import("../../world/store.zig");
const subbiome_noise = @import("../../world/subbiome_noise.zig");
const deco_mirror = @import("../../world/deco_mirror.zig");
const ecs = @import("../../ecs/root.zig");
const interest = @import("../../ecs/interest.zig");
const assets_items = @import("../../assets/items.zig");

const stock_sign = packages.stock_sign;

const deco = packages.stock_deco;

// ---------------------------------------------------------------------------
// Deco helpers required by sendDecoAroundSpawn (local copies so the extracted
// function compiles without reaching into Game's private fns). Bodies verbatim.
// ---------------------------------------------------------------------------

/// `stock_deco` height callback over the live chunk store. Unreadable columns
/// return 0, which the sampler skips (fail closed, no fabricated deco).
fn decoHeightAt(ctx: ?*anyopaque, wx: i32, wz: i32) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return 0));
    return g.world.heightWorld(wx, wz) catch 0;
}

/// `stock_deco` species callback: the biome under (wx,wz), then that biome's
/// distant-decoration list from biomes.xml. Fail closed at every step, since
/// a block id the client cannot resolve does not degrade, it throws inside the
/// client world-load coroutine: `DecoManager.addLoadedDecoration` →
/// `TryAddToOccupiedMap` derefs `Block::isMultiBlock` with no null check
/// (asm.il 1262497), and `DecoChunk.UpdateModels` looks the model up by name,
/// which is null for a null Block. Both leave the player stuck loading, which
/// is worse than no trees.
fn decoSpeciesAt(ctx: ?*anyopaque, wx: i32, wz: i32) packages.stock_deco.SpeciesList {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return .{}));
    const bm = g.world.biomes orelse return .{};
    const biome_id = bm.atWorld(wx, wz) orelse return .{};
    // GAP 18: resolve the subbiome per cell (stock decorateChunkRandom ->
    // GetBiomeOrSubAt). A subbiome hit samples its own list, where the
    // tree probability mass lives; otherwise the biome's own list applies.
    const subs = g.world.biome_layers_table.subBiomes(biome_id);
    var set = g.world.biome_layers_table.decosFor(biome_id);
    if (subs.len > 0) {
        const si = subbiome_noise.subBiomeIdx(&g.sub_noise, subs, wx, wz);
        if (si >= 0) set = subs[@intCast(si)].decos;
    }
    var out: packages.stock_deco.SpeciesList = .{};
    for (set.slice()) |d| {
        if (out.n >= packages.stock_deco.max_species) break;
        out.items[out.n] = .{ .block_id = d.block_id, .prob = d.prob };
        out.n += 1;
    }
    return out;
}

/// Cell offsets per deco block id for one join burst. The AssignIds map is
/// name-keyed, so resolving a block id back to its `MultiBlockDim` costs a
/// scan of the whole dump; a burst places thousands of objects but draws them
/// from a handful of species, so one scan per distinct id is enough.
const DecoDimCache = struct {
    /// Distinct deco species a burst can encounter across the covered biomes.
    const cap: usize = 32;
    ids: [cap]u16 = @splat(0),
    offsets: [cap]deco_mirror.Offsets = undefined,
    n: usize = 0,

    fn offsetsFor(self: *DecoDimCache, g: *const Game, id: u16) deco_mirror.Offsets {
        for (self.ids[0..self.n], self.offsets[0..self.n]) |cached_id, offs| {
            if (cached_id == id) return offs;
        }
        const offs = g.decoOffsetsFor(id);
        if (self.n < cap) {
            self.ids[self.n] = id;
            self.offsets[self.n] = offs;
            self.n += 1;
        }
        return offs;
    }
};

// ---------------------------------------------------------------------------
// Join bundle sends
// ---------------------------------------------------------------------------

pub fn sendSurvivalStats(
    self: *Game,
    peer: *ln_peer.Peer,
    entity_id: i32,
    hp: f32,
    max_hp: f32,
    food: f32,
    food_max: f32,
    water: f32,
    water_max: f32,
) !void {
    const stats = [_]struct { packages.EntityStatKind, f32, f32 }{
        .{ .health, hp, max_hp },
        .{ .food, food, food_max },
        .{ .water, water, water_max },
    };
    for (stats) |s| {
        if (packages.buildEntityStatChangedBody(
            self.body_buf[0..32],
            entity_id,
            -1,
            s[0],
            s[1],
            s[2],
            0,
        )) |body| {
            try self.sendGame(peer, "NetPackageEntityStatChanged", body);
        } else |_| {}
    }
}

/// PlayerEntityStats.Stamina sync (EntityStatChanged kind 1); the
/// survival/stamina loop calls it on a throttle like the vitals.
pub fn sendStaminaStats(self: *Game, peer: *ln_peer.Peer, entity_id: i32, stamina: f32, stamina_max: f32) !void {
    if (packages.buildEntityStatChangedBody(
        self.body_buf[0..32],
        entity_id,
        -1,
        .stamina,
        stamina,
        stamina_max,
        0,
    )) |body| {
        try self.sendGame(peer, "NetPackageEntityStatChanged", body);
    } else |_| {}
}

/// Join-time deco burst, mirroring stock `DecoManager.SendDecosToClient`
/// (asm.il 1263272), which is called from exactly one site in the assembly:
/// `GameManager.RequestToEnterGame` right after `NetPackageWorldInfo`.
///
/// This is the ONLY window. `DecoManager.Read` (asm.il 1260645) allocates
/// `loadedDecos` only when `_resetExisting` (= firstPackage) is true and then
/// unconditionally `loadedDecos.Add(...)`; the client drains that set and sets
/// it to null at the end of `OnWorldLoaded` (IL_04aa, asm.il 1259485) and never
/// refills it. So after world load a `firstPackage=false` package with objects
/// NREs, and a `firstPackage=true` package with objects is silently dropped.
/// There is no post-join deco path: whatever we do not cover here stays bald
/// for the session (the same package also marks every client DecoChunk
/// `isDecorated`, and a fixed-size client generates no deco locally).
///
/// Species and density are biome driven: `decoSpeciesAt` resolves the biome
/// map, and `generateForDecoChunk` runs stock's 128x128 sampler over it.
pub fn sendDecoAroundSpawn(self: *Game, c: *const Client, peer: *ln_peer.Peer, wx: i32, wz: i32) !void {
    const has_species = self.deco_trees and
        self.world.biomes != null and
        self.world.biome_layers_table.hasDecos();
    if (!has_species) {
        // Empty firstPackage is still required: the `isDecorated` marking loop
        // sits inside the `loadedDecos != null` branch, so without it the
        // client keeps retrying local generation it cannot do.
        const body = try deco.buildDecoUpdate(&self.body_buf, true, &.{});
        try self.sendGame(peer, "NetPackageDecoUpdate", body);
        std.debug.print(
            "zdtd: DecoUpdate first=true objs=0 (deco_trees={s} biomemap={s} biome_decos={s})\n",
            .{
                if (self.deco_trees) "on" else "off",
                if (self.world.biomes != null) "yes" else "no",
                if (self.world.biome_layers_table.hasDecos()) "yes" else "no",
            },
        );
        return;
    }

    const t = world_store.World.worldToChunk(wx, wz);
    const r = self.decoRadiusFor(c);
    // Same window `streamChunksForClient` covers: heightWorld getOrCreate must
    // not become an unbounded world-gen burst outside the streamed chunks.
    const window: deco.Window = .{
        .x0 = (t.pos.x - r) * deco.chunk_side,
        .z0 = (t.pos.z - r) * deco.chunk_side,
        .x1 = (t.pos.x + r + 1) * deco.chunk_side,
        .z1 = (t.pos.z + r + 1) * deco.chunk_side,
    };
    const sampler: deco.Sampler = .{
        .height_at = decoHeightAt,
        .species_at = decoSpeciesAt,
        .ctx = self,
    };

    const seed = self.worldSeed();
    var chunk_objs: [deco.attempts_per_deco_chunk]deco.DecoObj = undefined;
    var pw = try deco.PackageWriter.init(&self.body_buf, deco.zdtd_decos_per_package);
    var dim_cache: DecoDimCache = .{};
    var total: usize = 0;
    var mirrored: usize = 0;
    var capped = false;
    var dcz = deco.worldToDecoChunk(window.z0);
    const dcz_end = deco.worldToDecoChunk(window.z1 - 1);
    const dcx_end = deco.worldToDecoChunk(window.x1 - 1);
    while (dcz <= dcz_end and !capped) : (dcz += 1) {
        var dcx = deco.worldToDecoChunk(window.x0);
        while (dcx <= dcx_end and !capped) : (dcx += 1) {
            const n = deco.generateForDecoChunk(&chunk_objs, dcx, dcz, seed, window, sampler);
            for (chunk_objs[0..n]) |o| {
                if (total >= self.deco_objects_per_join) {
                    capped = true;
                    break;
                }
                // Mirror before streaming: the chunk payload the client gets
                // must already contain the blocks it is about to be told to
                // render, or the two disagree until the next edit.
                if (self.deco_mirror and self.mirrorDeco(&dim_cache, o)) mirrored += 1;
                if (pw.full()) {
                    try self.sendGame(peer, "NetPackageDecoUpdate", try pw.take());
                    self.pollNetOnce();
                }
                try pw.push(o);
                total += 1;
            }
        }
    }
    // Always send a final package, even with 0 objects: the client needs at
    // least one firstPackage=true to allocate + drain + mark decorated.
    try self.sendGame(peer, "NetPackageDecoUpdate", try pw.take());
    std.debug.print(
        "zdtd: DecoUpdate objs={d} pkgs={d} r={d} mirrored={d} capped={}\n",
        .{ total, pw.sent, r, mirrored, capped },
    );
}

pub fn sendSignDataBatches(self: *Game, peer: *ln_peer.Peer) !void {
    if (self.signs.entries.len == 0) {
        const resp = try packages.buildSignDataResponseEmptyLast(self.body_buf[0..16]);
        try self.sendGameCritical(peer, "NetPackageSignDataResponse", resp);
        std.debug.print("zdtd: SignDataRequest -> empty last batch entity peer\n", .{});
        return;
    }
    var start: usize = 0;
    var batches: usize = 0;
    while (start < self.signs.entries.len) {
        const last_chance = start;
        // Probe how many fit, then send with correct is_last.
        const probe = try stock_sign.buildSignDataResponseBatch(
            &self.body_buf,
            self.signs.entries,
            start,
            false,
        );
        const is_last = probe.next >= self.signs.entries.len;
        const batch = try stock_sign.buildSignDataResponseBatch(
            &self.body_buf,
            self.signs.entries,
            start,
            is_last,
        );
        // SignDataResponse blocks worldInfoCo until isLastBatch=true; dropping
        // the final batch wedges the client on "Starting Game".
        if (is_last) try self.sendGameCritical(peer, "NetPackageSignDataResponse", batch.body) else try self.sendGame(peer, "NetPackageSignDataResponse", batch.body);
        batches += 1;
        start = batch.next;
        if (start == last_chance) {
            const resp = try packages.buildSignDataResponseEmptyLast(self.body_buf[0..16]);
            try self.sendGameCritical(peer, "NetPackageSignDataResponse", resp);
            break;
        }
        self.pollNetOnce();
    }
    std.debug.print("zdtd: SignDataRequest -> batches={d} signs={d}\n", .{ batches, self.signs.entries.len });
}

pub fn sendTraderSnapshot(self: *Game, peer: *ln_peer.Peer, prefer_slot: ?ecs.Slot) !void {
    var ti: ?ecs.Slot = prefer_slot;
    if (ti == null) {
        var i: ecs.Slot = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (self.sim.alive[i] and self.sim.mask[i].trader and self.sim.mask[i].trader_stock) {
                ti = i;
                break;
            }
        }
    }
    const s = ti orelse return;
    if (!self.sim.mask[s].trader_stock) return;
    const eid = self.sim.network_id[s].id;
    // Stock TraderData with primary inventory from SoA stock table.
    var entries: [16]packages.TraderStockEntry = undefined;
    const n = self.stockEntries(s, &entries);
    const body = try packages.buildTraderDataStock(
        self.body_buf[0..4096],
        eid,
        eid, // trader id (stock TraderID is a traders.xml index; entity id is a safe placeholder)
        self.traderMoney(s),
        entries[0..n],
    );
    try self.sendGame(peer, "NetPackageTraderData", body);
}

pub fn sendWorldSpawnPoints(self: *Game, peer: *ln_peer.Peer) !void {
    var pts: [32]packages.SpawnPointXYZ = undefined;
    var n: usize = 0;
    if (self.world.spawn_count > 0) {
        while (n < self.world.spawn_count and n < pts.len) : (n += 1) {
            pts[n] = .{
                .x = self.world.spawns[n].x,
                .y = self.world.spawns[n].y,
                .z = self.world.spawns[n].z,
            };
        }
    } else {
        const sp = self.world.primarySpawn();
        pts[0] = .{ .x = sp.x, .y = sp.y, .z = sp.z };
        n = 1;
    }
    const body = try packages.buildWorldSpawnPoints(self.body_buf[0..512], pts[0..n]);
    try self.sendGameCritical(peer, "NetPackageWorldSpawnPoints", body);
}

/// Build and send NetPackageWorldAreas from the trader POIs on the loaded
/// map (stock: World.TraderAreas, one TraderArea per TraderArea=True
/// prefab). Position = the decoration origin, size = the prefab size,
/// protect padding = TraderAreaProtect - 2 (GetProtectPadding), and the
/// teleport volumes from TeleportVolumeStart/Size (local cells).
pub fn sendWorldAreas(self: *Game, peer: *ln_peer.Peer) !void {
    const pf = if (self.world.prefabs) |*p| p else return;
    var areas: [8]packages.TraderAreaEntry = undefined;
    var vols: [8][8]packages.TraderTeleport = undefined;
    var n: usize = 0;
    for (pf.items) |d| {
        if (n >= areas.len) break;
        if (world_store.prefabs.isPart(d.name)) continue;
        const qd = pf.questData(d.name) orelse continue;
        if (!qd.is_trader_area) continue;
        var vn: usize = 0;
        while (vn < qd.teleport_n and vn < vols[n].len) : (vn += 1) {
            vols[n][vn] = .{
                .start_x = qd.teleport_start[vn][0],
                .start_y = qd.teleport_start[vn][1],
                .start_z = qd.teleport_start[vn][2],
                .size_x = qd.teleport_size[vn][0],
                .size_y = qd.teleport_size[vn][1],
                .size_z = qd.teleport_size[vn][2],
            };
        }
        areas[n] = .{
            .pos_x = d.x,
            .pos_y = d.stampY(),
            .pos_z = d.z,
            .size_x = @intCast(d.size_x),
            .size_y = @intCast(d.size_y),
            .size_z = @intCast(d.size_z),
            .pad_x = @intCast(qd.protect_padding[0] - 2),
            .pad_y = qd.protect_padding[1],
            .pad_z = @intCast(qd.protect_padding[2] - 2),
            .teleports = vols[n][0..vn],
        };
        n += 1;
    }
    if (n == 0) return;
    const body = try packages.buildWorldAreasBody(self.body_buf[0..2048], areas[0..n]);
    try self.sendGameCritical(peer, "NetPackageWorldAreas", body);
}

/// Stock NetPackageGameStats: full bPersistent propertyList blob (RE).
/// HUD day still comes from WorldTime; BloodMoonDay is the scheduled BM day.
pub fn sendGameStats(self: *Game, peer: *ln_peer.Peer) !void {
    const vals = self.gameStatsValues();
    const gs = try packages.buildGameStatsBodyValues(self.body_buf[1040..2048], vals);
    try self.sendGameCritical(peer, "NetPackageGameStats", gs);
}

/// Re-send the GameStats blob to every entered peer when the scheduled
/// blood-moon day rolls (a client that joined mid-cycle and sat past its
/// first horde would otherwise keep the stale red-moon HUD day forever).
pub fn broadcastGameStats(self: *Game) !void {
    const gs = try packages.buildGameStatsBodyValues(self.body_buf[1040..2048], self.gameStatsValues());
    try self.broadcast("NetPackageGameStats", gs);
}

/// Map markers for active journal quests (stock class names only).
pub fn sendQuestNavObjects(self: *Game, peer: *ln_peer.Peer, peer_slot: usize, player_eid: i32) !void {
    const ps = self.sim.playerByPeer(peer_slot) orelse return;
    if (!self.sim.mask[ps].journal) return;
    for (self.sim.journal[ps].slots) |s| {
        if (!s.active or s.completed) continue;
        const d = self.sim.catalog.byId(s.def_id) orelse continue;
        if (d.name.len == 0 or !self.isStockClientQuestName(d.name)) continue;
        // nav_objects.xml: quest | go_to_trader | return_to_trader
        const nav_class: []const u8 = switch (d.kind) {
            .fetch_trader => if (s.ready_turn_in) "return_to_trader" else "go_to_trader",
            .goto_point, .kill_zombies, .fetch_item, .craft, .stay_within, .block_activate => "quest",
        };
        const use_def_pos = d.kind == .goto_point or d.kind == .stay_within or d.kind == .craft;
        // A POI-bound quest (audit B26) marks the placed POI center; defs
        // without one keep the def marker position.
        const gx: f32 = if (s.poi.valid()) s.poi.x + s.poi.size_x * 0.5 else d.tx;
        const gz: f32 = if (s.poi.valid()) s.poi.z + s.poi.size_z * 0.5 else d.tz;
        const lx: f32 = if (use_def_pos) gx else @floatFromInt(self.world.primarySpawn().x);
        const ly: f32 = if (use_def_pos) d.ty else @floatFromInt(self.world.primarySpawn().y);
        const lz: f32 = if (use_def_pos) gz else @floatFromInt(self.world.primarySpawn().z);
        // entityId tags marker to player for client cleanup.
        const body = try packages.buildNavObjectAdd(
            self.body_buf[8192..8704],
            nav_class,
            d.name,
            lx,
            ly,
            lz,
            player_eid,
        );
        try self.sendGame(peer, "NetPackageNavObject", body);
    }
}

/// Nearby non-player entities using stock NetPackageEntitySpawn + ECD networkWrite.
/// Interest radius matches tick-path spawn-on-approach (`interest.inRange` + view_radius).
pub fn sendStockEntitySpawns(self: *Game, peer: *ln_peer.Peer, c: *Client, px: i32, pz: i32) !void {
    const radius: i32 = if (c.view_radius < 1) self.view_radius else c.view_radius;
    const pfx: f32 = @floatFromInt(px);
    const pfz: f32 = @floatFromInt(pz);
    var i: ecs.Slot = 0;
    var sent: u32 = 0;
    var alive_z: u32 = 0;
    while (i < ecs.max_entities) : (i += 1) {
        if (!self.sim.alive[i]) continue;
        if (!self.sim.mask[i].kind) continue;
        const k = self.sim.kind[i];
        if (k != .zombie and k != .animal and k != .trader) continue;
        if (k == .zombie) alive_z += 1;
        if (!self.sim.mask[i].transform or !self.sim.mask[i].network_id) continue;
        if (self.sim.mask[i].player) continue;
        const nid = self.sim.network_id[i].id;
        if (nid == c.entity_id or nid <= 0) continue;
        if (!interest.inRange(pfx, pfz, self.sim.transform[i].x, self.sim.transform[i].z, radius)) continue;
        const sleeper = self.sim.mask[i].sleeper and !self.sim.sleeper[i].awake;
        const eclass: i32 = if (self.sim.mask[i].class_id and self.sim.class_id[i].hash != 0)
            self.sim.class_id[i].hash
        else
            packages.stock_entity.class_zombie_default;
        const body = try packages.stock_entity.buildEntitySpawnStock(&self.body_buf, .{
            .entity_id = nid,
            .entity_class = eclass,
            .x = self.sim.transform[i].x,
            .y = self.sim.transform[i].y,
            .z = self.sim.transform[i].z,
            .yaw = self.sim.transform[i].yaw,
            .is_sleeper = sleeper,
            .trader_data = if (k == .trader and self.sim.mask[i].trader_stock) blk: {
                var ent_buf: [16]packages.TraderStockEntry = undefined;
                const n = self.stockEntries(i, &ent_buf);
                break :blk .{ .trader_id = nid, .available_money = self.traderMoney(i), .entries = ent_buf[0..n] };
            } else null,
        });
        try self.sendGame(peer, "NetPackageEntitySpawn", body);
        c.known_entities.set(i);
        sent += 1;
        self.pollNetOnce();
        if (sent >= 16) break;
    }
    std.debug.print("zdtd: stock EntitySpawn mobs sent={d} alive_z={d} around=({d},{d})\n", .{ sent, alive_z, px, pz });
}

/// Stock EntityStatChanged for core vitals (Health/Stamina/Food/Water).
pub fn sendPlayerVitals(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
    const eid = c.entity_id;
    if (eid <= 0) return;
    var hp: f32 = 100;
    var max_hp: f32 = 100;
    var food: f32 = 100;
    var food_max: f32 = 100;
    var water: f32 = 100;
    var water_max: f32 = 100;
    var stamina: f32 = 100;
    var stamina_max: f32 = 100;
    if (self.sim.slotOfNetId(eid)) |si| {
        if (self.sim.mask[si].health) {
            hp = self.sim.health[si].hp;
            max_hp = self.sim.health[si].max_hp;
            food = self.sim.health[si].food;
            food_max = self.sim.health[si].food_max;
            water = self.sim.health[si].water;
            water_max = self.sim.health[si].water_max;
            stamina = self.sim.health[si].stamina;
            stamina_max = self.sim.health[si].stamina_max;
        }
    }
    const stats = [_]struct { packages.EntityStatKind, f32, f32 }{
        .{ .health, hp, max_hp },
        .{ .stamina, stamina, stamina_max },
        .{ .food, food, food_max },
        .{ .water, water, water_max },
    };
    for (stats) |s| {
        const body = try packages.buildEntityStatChangedBody(
            self.body_buf[0..32],
            eid,
            -1,
            s[0],
            s[1],
            s[2],
            0,
        );
        try self.sendGame(peer, "NetPackageEntityStatChanged", body);
    }
}

pub fn sendItemIdMapping(self: *Game, peer: *ln_peer.Peer) !void {
    // Compact NameIdMapping: only ECS builtins that resolved to stock types (fits 8 KiB body).
    // Full items.xml map is ~30–50 KiB uncompressed; stock client already has matching AssignIds
    // from the same Config when game-dir is shared.
    var map_buf: [2048]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &map_buf };
    try w.writeI32(1);
    const count_pos = w.pos;
    try w.writeI32(0);
    var n: i32 = 0;
    var id: u16 = 1;
    while (id <= 12) : (id += 1) {
        const st = self.items.stockTypeFor(id);
        if (st == 0) continue;
        const name = assets_items.builtinStockName(id) orelse continue;
        try w.writeI32(st);
        try w.writeString(name);
        n += 1;
    }
    std.mem.writeInt(i32, map_buf[count_pos..][0..4], n, .little);
    if (n == 0) return;
    const body = packages.buildIdMappingBody(&self.body_buf, "items", w.written()) catch return;
    try self.sendGame(peer, "NetPackageIdMapping", body);
}

/// Holding-only S2C (valid direction for stock clients).
/// Join: send empty held stack (entityId + count=0 + index). Full ItemValue held
/// stacks have underrun'd stock HoldingItem.read mid-join when framing/window is tight;
/// PDF already carries toolbelt. Echo path after InvTx still sends resolved hold.
pub fn sendHoldingOnly(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
    try sendHoldingOnlyEx(self, peer, c, false);
}

pub fn sendHoldingOnlyEx(self: *Game, peer: *ln_peer.Peer, c: *Client, full_stack: bool) !void {
    const ps = self.sim.playerByPeer(c.slot) orelse return;
    if (!self.sim.mask[ps].inventory) return;
    // Dedicated slice after PlayerId region; keep short fixed body.
    var hb: []const u8 = undefined;
    if (full_stack) {
        hb = try packages.buildHoldingBodyResolved(
            self.body_buf[6144..6400],
            c.entity_id,
            &self.sim.inventory[ps],
            Game.resolveItemType,
            self,
        );
    } else {
        // Empty ItemStack: entityId + u16 count=0 + holding index.
        var w: wire_binary.Writer = .{ .buf = self.body_buf[6144..6160] };
        try w.writeI32(c.entity_id);
        try w.writeU16(0);
        const idx: u8 = if (self.sim.inventory[ps].holding < ecs.components.inv_toolbelt)
            @intCast(self.sim.inventory[ps].holding)
        else
            0;
        try w.writeByte(idx);
        hb = w.written();
    }
    try self.sendGame(peer, "NetPackageHoldingItem", hb);
}

/// Post-change inv echo. PlayerInventory/Bag are ToServer-only for stock
/// clients; only HoldingItem is a valid S2C echo.
pub fn sendHoldingEcho(self: *Game, peer: *ln_peer.Peer, c: *Client) !void {
    try sendHoldingOnlyEx(self, peer, c, true);
}
