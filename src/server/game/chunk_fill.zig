//! Chunk materialization and loot-fill senders, extracted verbatim from
//! game.zig: sendSpawnChunk (resident-miss load + stock Chunk.write encode),
//! the per-chunk storage/prefab TE scan with deterministic loot roll
//! (ensurePrefabStorageInChunk, fillContainerFromLoot, lootSeedAt,
//! maybeRespawnContainer), and the power-grid rebuild per chunk
//! (scanChunkPower).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const apm = @import("../../apm/root.zig");
const packages = @import("../../wire/packages.zig");
const assets_loot = @import("../../assets/loot.zig");
const assets_blocks = @import("../../assets/blocks.zig");
const assets_block_textures = @import("../../assets/block_textures.zig");
const containers_mod = @import("../../world/containers.zig");
const light_te_mod = @import("../../world/light_te.zig");
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const invsys = @import("../../ecs/inventory.zig");
const rng_util = @import("../../util/rng.zig");
const replicate_te = @import("../replicate_te.zig");

const te_types = packages.te_types;

/// All-broken topsoil bitfield (the pre-topsoil look; `topsoil_all_broken`
/// rule for worlds without splat maps).
const topsoil_broken = [_]u8{0xFF} ** 32;

pub fn sendSpawnChunk(self: *Game, peer: *ln_peer.Peer, cx: i32, cz: i32) !bool {
    // Resident miss = disk load or procedural gen (worldgen W2 runs here,
    // on the tick, bounded by chunk_adds_per_stream_tick). world/ may not
    // import apm, so the scope lives at this call site.
    const ch = blk: {
        const gs = apm.profiler.scope(&self.harness.prof, .chunk_gen);
        defer gs.end();
        break :blk try self.world.getOrCreate(.{ .x = cx, .z = cz });
    };
    // After TTS paint, create storage TEs for known chest block ids (loot fill once).
    self.ensurePrefabStorageInChunk(ch, cx, cz);
    // Rebuild power nodes from this chunk's blocks (grid is runtime state).
    self.scanChunkPower(ch, cx, cz);
    // Prefer biomes.png color→id mode; fallback height band. Cached on the
    // chunk so re-sends to other clients skip the 256-lookup dominant scan.
    // Procedural worlds use the same biome field that drove the surface
    // fill, so the client's displayed biome matches the blocks (W3).
    const biome_id: u8 = ch.biome_id orelse blk: {
        const b: u8 = if (self.world.terrain_source == .proc)
            self.world.procBiomeAt(cx, cz)
        else if (self.world.biomes) |*bm|
            bm.chunkDominant(cx, cz)
        else hb: {
            var hsum: u32 = 0;
            for (ch.heights) |h| hsum += h;
            const havg: u8 = @intCast(hsum / 256);
            break :hb if (havg < 40) @as(u8, 5) else if (havg > 90) @as(u8, 1) else 3;
        };
        ch.biome_id = b;
        break :blk b;
    };
    // Feed store columns (TTS-painted) into stock encoder.
    const BlockCtx = struct {
        fn at(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u32 {
            const c: *const world_store.Chunk = @ptrCast(@alignCast(ctx.?));
            return c.rawAt(lx, y, lz);
        }
        fn tex(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u64 {
            const c: *const world_store.Chunk = @ptrCast(@alignCast(ctx.?));
            return c.texAt(lx, y, lz);
        }
        fn dens(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) ?u8 {
            const c: *const world_store.Chunk = @ptrCast(@alignCast(ctx.?));
            return c.densAt(lx, y, lz);
        }
    };
    const TexCtx = struct {
        t: *const assets_block_textures.Table,
        fn def(ctx: ?*anyopaque, type_id: u16) u64 {
            const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
            return self_t.t.get(type_id);
        }
    };
    var tex_ctx: TexCtx = .{ .t = &self.block_textures };
    const DmgCtx = struct {
        g: *Game,
        ch: *const world_store.Chunk,
        fn at(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u16 {
            const d: *const @This() = @ptrCast(@alignCast(ctx.?));
            // Stage2Health (RE blocks.md §5): the wire damage caps at the
            // block's stage-2 threshold (doors); internal damage stays full.
            const stored = d.ch.dmgAt(lx, y, lz);
            return d.g.wireBlockDamage(d.ch.blockAt(lx, y, lz), stored);
        }
    };
    // Per-cell biome provider (GAP per-chunk-biome row): same sources as the
    // dominant (proc field / biomes.png / height fallback), but per column so
    // transitions follow the map instead of snapping to the chunk boundary.
    const BiomeCtx = struct {
        g: *Game,
        fallback: u8,
        fn at(ctx: ?*anyopaque, wx: i32, wz: i32) u8 {
            const b: *const @This() = @ptrCast(@alignCast(ctx.?));
            if (b.g.world.terrain_source == .proc) {
                if (b.g.world.worldgen) |*wg|
                    return b.g.world.biome_layers_table.biomeIdAt(wg.biomeAt(@floatFromInt(wx), @floatFromInt(wz)));
            } else if (b.g.world.biomes) |*bm| {
                if (bm.atWorld(wx, wz)) |id| return id;
            }
            return b.fallback;
        }
    };
    var biome_ctx: BiomeCtx = .{ .g = self, .fallback = biome_id };
    var dmg_ctx: DmgCtx = .{ .g = self, .ch = ch };
    // Stock Chunk.write payload inside NetPackageChunk (overwrite=false first delivery).
    const body = try packages.stock_chunk.buildNetPackageChunkNew(&self.body_buf, .{
        .cx = cx,
        .cz = cz,
        .heights = &ch.heights,
        .ticks = self.sim.director.clock.worldTimeBits(),
        .biome = biome_id,
        // Topsoil bitfield: the chunk's real disturbed state (fresh = clear,
        // dig/upgrade sets bits). The topsoil_all_broken rule forces the
        // legacy all-broken look for worlds without splat maps.
        .topsoil = if (self.sim.rules.world.topsoil_all_broken) &topsoil_broken else &ch.topsoil,
        .block_at = BlockCtx.at,
        .block_ctx = ch,
        .tex_at = BlockCtx.tex,
        .default_tex = TexCtx.def,
        .default_tex_ctx = &tex_ctx,
        // TTS density overrides exist only when the chunk has a densities plane;
        // without one, dens_at returns null for every cell and writeDensityChannel
        // falls back to 65536 scalar densityAt calls, bypassing its SIMD
        // packDensityFromRaws fast path (gated on dens_at == null). Both agree
        // bit-for-bit with no overrides: densityForBlock(type) per cell.
        .dens_at = if (ch.densities == null) null else BlockCtx.dens,
        .water_block_id = self.world.terrain_ids.water,
        .dmg_at = DmgCtx.at,
        .dmg_ctx = &dmg_ctx,
        .raws_scratch = &self.chunk_raws,
        // Per-cell biome (GAP per-chunk-biome row): the biome map under each
        // column, so transitions follow biomes.png / the proc field instead of
        // snapping to the chunk dominant. Falls back to the cached dominant.
        .biome_at = &BiomeCtx.at,
        .biome_ctx = &biome_ctx,
    });
    const before_out = self.harness.counters.get(.net_packets_out);
    try self.sendGame(peer, "NetPackageChunk", body);
    const after_out = self.harness.counters.get(.net_packets_out);
    const delivered = after_out != before_out;
    if (!delivered) {
        std.debug.print("zdtd: FAILED NetPackageChunk cx={d} cz={d} body={d}\n", .{ cx, cz, body.len });
        return false;
    }
    // Storage TEs in this column (placed chests, loot containers).
    try self.sendContainersInChunk(peer, cx, cz);
    return true;
}

/// Scan painted columns for known storage AssignIds; create + roll loot once.
/// Deterministic loot seed from world block position (stable across chunk scans).
fn lootSeedAt(wx: i32, wy: i32, wz: i32) u32 {
    return @as(u32, @bitCast(wx *% 73856093 ^ wz *% 19349663 ^ wy));
}

/// Also honor prefab TTS TE list (Loot/SecureLoot/Composite types).
/// Rebuild power nodes from a chunk's blocks (GAP power persistence): the
/// grid is runtime state (addNodeAt on place/remove), so after a restart
/// each chunk re-derives its generators/consumers/wires from the block
/// plane on first touch. `applyToNode` carries the per-block fuel/capacity
/// properties; wires are re-added from the block plane the same way.
pub fn scanChunkPower(self: *Game, ch: *world_store.Chunk, cx: i32, cz: i32) void {
    if (ch.power_scanned) return;
    const blocks = ch.blocks orelse return;
    ch.power_scanned = true;
    const base_x = cx * 16;
    const base_z = cz * 16;
    var last_id: u16 = 0;
    var last_power: ?ecs.powerblocks.Resolved = null;
    var y: i32 = 0;
    while (y < world_store.y_dim) : (y += 1) {
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                const id: u16 = @truncate(blocks[@intCast(lx + lz * 16 + y * 256)]);
                if (id != last_id) {
                    last_id = id;
                    last_power = self.power_registry.lookup(id);
                }
                const pn = last_power orelse continue;
                const wx = base_x + lx;
                const wz = base_z + lz;
                if (self.sim.power.addNodeAt(pn.kind, wx, y, wz, pn.watts)) |nid| {
                    if (self.sim.power.indexOfId(nid)) |ni| pn.applyToNode(&self.sim.power.nodes[ni]);
                }
            }
        }
    }
    self.sim.power.resolve();
    // Restored wire edges whose endpoints are now both scanned reconnect.
    self.sim.power.reconnectPending();
}

pub fn ensurePrefabStorageInChunk(self: *Game, ch: *world_store.Chunk, cx: i32, cz: i32) void {
    if (ch.te_scanned) return;
    const blocks = ch.blocks orelse return;
    // Always-on evidence for the "TE loot as a job batch" gap: the loot roll
    // is microseconds, this up-to-65536-cell walk is where the time goes.
    const ts = apm.profiler.scope(&self.harness.prof, .te_scan);
    var cells: u64 = 0;
    defer {
        ts.end();
        self.harness.counters.add(.te_scan_cells, cells);
    }
    const base_x = cx * 16;
    const base_z = cz * 16;
    var found: u32 = 0;
    // Block ids repeat in long runs (terrain), so memo the last id's verdict
    // to skip the hash probe in isStorageBlockId for nearly every cell.
    var last_id: u16 = 0;
    var last_is_storage = false;
    // y outermost so idx advances contiguously (y stride is 1 KiB; the old
    // y-inner order made all 65k reads cache misses across a 256 KiB array).
    var y: i32 = 0;
    while (y < world_store.y_dim) : (y += 1) {
        var lz: i32 = 0;
        while (lz < 16) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < 16) : (lx += 1) {
                cells += 1;
                const idx = @as(usize, @intCast(lx + lz * 16 + y * 256));
                const id: u16 = @truncate(blocks[idx]);
                if (id == 0) continue;
                if (id != last_id) {
                    last_id = id;
                    last_is_storage = self.isStorageBlockId(id);
                }
                if (!last_is_storage) continue;
                const wx = base_x + lx;
                const wz = base_z + lz;
                const pos = containers_mod.PosKey{ .x = wx, .y = y, .z = wz };
                if (self.containers.get(pos) != null) continue;
                const cont = self.containers.getOrCreate(pos, 8, id) orelse continue;
                // World container (not player-placed): eligible for loot respawn.
                cont.player_storage = false;
                if (cont.slots[0].count == 0 and cont.slots[1].count == 0) {
                    // Fail closed (audit A31): a storage block with no
                    // LootList stays empty instead of inventing woodenChest.
                    if (self.maxdamage.lootListFor(id)) |ll| {
                        self.fillContainerFromLoot(cont, ll, lootSeedAt(wx, y, wz));
                    }
                }
                found += 1;
                if (found >= self.te_scan_block_cap) return;
            }
        }
    }
    // Prefab TE list (TileEntityType Loot=5, SecureLoot=10, Composite=25).
    if (self.world.prefabs) |*pf| {
        const TeCtx = struct {
            g: *Game,
            found: *u32,
            fn onTe(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, te_type: u8, payload: []const u8) void {
                const tc: *@This() = @ptrCast(@alignCast(ctx.?));
                if (tc.found.* >= tc.g.te_scan_te_cap) return;
                // Authored Light TEs (type 18): store the parsed
                // intensity/range/colour so the chunk stream emits the light.
                if (te_type == te_types.light) {
                    const lpos = light_te_mod.PosKey{ .x = wx, .y = wy, .z = wz };
                    if (tc.g.light_te.get(lpos) == null) {
                        if (tc.g.light_te.getOrCreate(lpos)) |lt| {
                            _ = light_te_mod.parsePayload(payload, lt);
                        }
                    }
                    return;
                }
                // Loot-like types only.
                if (!(te_types.isStorageLike(te_type) or te_type == te_types.powered or te_types.isSignLike(te_type))) return;
                const pos = containers_mod.PosKey{ .x = wx, .y = wy, .z = wz };
                if (tc.g.containers.get(pos) != null) return;
                const block_id: u16 = tc.g.world.blockWorld(wx, wy, wz) catch 0;
                const id: u16 = if (block_id != 0) block_id else replicate_te.seedChestBlockId(tc.g);
                const cont = tc.g.containers.getOrCreate(pos, 8, id) orelse return;
                // World container (prefab TE, not player-placed).
                cont.player_storage = false;
                if (cont.slots[0].count == 0 and cont.slots[1].count == 0) {
                    // Fail closed (audit A31): no LootList, no invented loot.
                    if (tc.g.maxdamage.lootListFor(id)) |ll| {
                        tc.g.fillContainerFromLoot(cont, ll, lootSeedAt(wx, wy, wz));
                    }
                }
                tc.found.* += 1;
            }
        };
        var te_found: u32 = found;
        var tc: TeCtx = .{ .g = self, .found = &te_found };
        pf.foreachTeInChunk(cx, cz, TeCtx.onTe, &tc);
        // Scan complete unless the TE cap truncated it; then retry next send.
        if (te_found < self.te_scan_te_cap) ch.te_scanned = true;
    } else {
        ch.te_scanned = true;
    }
}

pub fn fillContainerFromLoot(self: *Game, cont: *containers_mod.Container, loot_name: []const u8, seed: u32) void {
    // Remember the table that filled this container: the destroy_on_close
    // check on unlock reads it (ShouldDestroyOnClose, loot-economy.md 454).
    cont.loot_list = loot_name;
    // Stock LootContainer.size (loot.xml <lootcontainer size="x,y">) sizes
    // the storage grid; the client reads the cell count from the TE body,
    // so a gun safe (4x3) shows 12 cells instead of the flat 8. The size
    // derives per fill and the save round-trips slot_count, so a restored
    // container keeps its capacity and a re-rolled one re-derives it.
    if (self.loot.containerByName(loot_name)) |lc| {
        const want = @min(@as(usize, lc.size_x) * @as(usize, lc.size_y), containers_mod.max_container_slots);
        if (want >= 1) cont.slot_count = @intCast(want);
    }
    // Roll up to the container's own capacity (the roll is capped by the
    // buffer, so a bigger container actually fills more stacks).
    var stacks: [containers_mod.max_container_slots]assets_loot.Stack = undefined;
    var n = self.loot.rollContainer(loot_name, self.partyLootStage(), seed, stacks[0..cont.slot_count]);
    // Wasm-first (AGENTS rule 29): the roll passes the on_loot_roll verdict
    // (<0 empty the result, 0 keep, >0 scale the rolled count by percent).
    const sv = self.plugins.lootRoll(loot_name, @intCast(n));
    const v = if (sv != 0) sv else self.wasm_plugins.lootRoll(loot_name, @intCast(n));
    if (v < 0) return;
    if (v > 0) {
        const scaled: usize = n * @as(usize, @intCast(v)) / 100;
        n = @min(scaled, cont.slot_count);
    }
    var si: usize = 0;
    var i: usize = 0;
    while (i < n and si < cont.slot_count) : (i += 1) {
        const eid = self.ecsIdFromItemName(stacks[i].item_name);
        if (eid == 0) continue;
        // The template rolls quality for every stack; only quality items
        // (stock ItemClass.HasQuality = tiered effect controller, which
        // zdtd approximates as stack==1; quality items never stack) carry
        // it, so stackables keep quality 1 and merge normally.
        const q = if (self.items.byId(eid)) |d|
            (if (d.stack == 1) stacks[i].quality else 1)
        else
            stacks[i].quality;
        cont.setSlot(si, .{ .item_id = eid, .count = stacks[i].count, .quality = q });
        si += 1;
    }
    // LootRespawnDays base: the day this loot was generated.
    cont.touched_day = self.sim.director.clock.day;
}

/// LootRespawnDays (stock TEFeatureStorage.UpdateTick): a looted world
/// container re-rolls its contents when the interval since the touch day
/// has elapsed. Player-placed storage never respawns. The next open
/// regenerates fresh loot; the cycle-varying seed makes each respawn
/// differ while staying deterministic per (pos, cycle). A block without a
/// LootList stays empty (fail closed, audit A31), never woodenChest.
pub fn maybeRespawnContainer(self: *Game, cont: *containers_mod.Container) void {
    if (self.loot_respawn_days == 0) return;
    if (cont.player_storage) return;
    if (!cont.touched) return;
    var empty = true;
    for (cont.slots[0..cont.slot_count]) |s| {
        if (s.count > 0 and s.item_id != 0) {
            empty = false;
            break;
        }
    }
    if (!empty) return;
    const day = self.sim.director.clock.day;
    if (day <= cont.touched_day) return;
    // Wrapping subtraction: a touched_day in the future (or pre-save 0 with
    // a day wrap) must not panic the tick; the <= guard above already
    // rejected the future case.
    const elapsed = day -% cont.touched_day;
    if (elapsed < self.loot_respawn_days) return;
    const id: u16 = @truncate(@as(u32, @bitCast(cont.block_id)));
    const cycle: u32 = day / self.loot_respawn_days;
    const pos = cont.pos;
    // Fail closed (audit A31): no LootList, the container stays empty.
    const ll = self.maxdamage.lootListFor(id) orelse return;
    self.fillContainerFromLoot(
        cont,
        ll,
        lootSeedAt(pos.x, pos.y, pos.z) +% cycle *% 2654435761,
    );
}

/// Stock TEFeatureStorage.OnUnlockedServer (IL=6) fires
/// GameManager.CheckDestroyTileEntity (IL=37, loot-economy.md 454-456) when
/// a storage container unlocks (the player closed it): a loot def with
/// `destroy_on_close` ("true" -> always, "empty" -> only when emptied,
/// TEFeatureStorage.ShouldDestroyOnClose IL=19) drops the remaining contents
/// as an EntityLootContainer bag at +0.5,0.75,+0.5 and destroys the block.
/// Fires from the C2S LockRequest unlock path; no-op for containers without
/// a known loot def or a non-destroying def.
/// A broken container spills its contents like the eviction path below
/// ("Drop the remaining contents"): the pre-filled contents ARE the block's
/// loot (all 449 LootList blocks are CompositeTileEntity containers; rolling
/// the list again would double-loot, and maxdamage.lootListFor already
/// resolves it for the pre-fill). No-op when the block has no live container.
pub fn tryContainerSpill(self: *Game, x: i32, y: i32, z: i32) void {
    const pos = containers_mod.PosKey{ .x = x, .y = y, .z = z };
    const cont = self.containers.get(pos) orelse return;
    var drop_inv: ecs.components.Inventory = .{};
    var n: usize = 0;
    for (cont.slots) |s| {
        if (s.count > 0 and s.item_id != 0 and n < ecs.components.max_inv_slots) {
            drop_inv.slots[n] = s;
            n += 1;
        }
    }
    self.containers.remove(pos);
    if (n == 0) return;
    const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
    const fy: f32 = @as(f32, @floatFromInt(y)) + 0.75;
    const fz: f32 = @as(f32, @floatFromInt(z)) + 0.5;
    if (self.sim.spawnLootBagFrom(fx, fy, fz, &drop_inv, 0, n)) |bag_nid| {
        self.broadcastLootSpawn(bag_nid) catch {};
    }
}

/// Roll the broken block's Harvest drop rows (RE Block.DropItemsOnEvent
/// IL=246 + GameUtils.HarvestOnAttack IL=623) into the breaker's inventory:
/// per row, count = RandomRange(min, max+1), skip 0, drop when
/// random < prob; each rolled stack is granted to the breaking player, and
/// a stack that does not fit becomes a loot bag at the block (stock
/// ItemDropServer lifetime 60 when full). The roll ignores tool_category /
/// tag exactly like stock (the IL never reads them; they feed the
/// item-side bonus legs, recorded). Deterministic: position + tick-seeded
/// stream (the one sim PRNG policy; stock seeds GameUtils.random from a
/// timestamp, which zdtd deliberately replaces per rule 22). Returns the
/// total rolled count — the `count` of stock
/// AddLevelExp(material.Experience * count).
/// Roll a block's drop rows for one event (RE Block.DropItemsOnEvent
/// IL=246): per row, count = RandomRange(min, max+1), skip 0, drop when
/// random < prob. Recipient per stock:
/// - Harvest: rolled stacks grant to the breaker's inventory
///   (GameUtils.HarvestOnAttack IL=623), overflow becomes a ground bag.
/// - Destroy/Fall: stacks become a ground bag at the block (stock
///   ItemDropServer); stick rows (stick_chance >= 0.001 and random <=
///   stick_chance) take the stick path instead - the drop is placed as an
///   item block at the cell when the name resolves to a block and the cell
///   is air (stock SetBlockRPC), else skipped exactly like stock.
/// `overall_prob` gates each rolled stack (stock `_overallProb`; 1.0 = no
/// gate, explosion debris passes 0.5). The roll ignores tool_category /
/// tag exactly like stock (the IL never reads them; they feed the
/// item-side bonus legs, recorded). Deterministic: position + tick-seeded
/// stream (the one sim PRNG policy; stock seeds GameUtils.random from a
/// timestamp, which zdtd deliberately replaces per rule 22). Returns the
/// total rolled count - the `count` of stock AddLevelExp(material.
/// Experience * count) for Harvest.
pub fn rollBlockDropEvent(
    self: *Game,
    peer_slot: usize,
    x: i32,
    y: i32,
    z: i32,
    block_id: u16,
    event: assets_blocks.DropEvent,
    overall_prob: f32,
) u32 {
    const drops = self.blocks.dropsFor(block_id, event);
    if (drops.len == 0) return 0;
    var prng = rng_util.XorShift32.initFromU64(
        @as(u64, @bitCast(@as(i64, x))) *% 0x9E37_79B1_7F4A_7C15 ^
            @as(u64, @bitCast(@as(i64, y))) *% 0xBF58_476D_1CE4_E5B9 ^
            @as(u64, @bitCast(@as(i64, z))) *% 0x94D0_49BB_1331_11EB ^
            self.tick_n,
    );
    var stacks: [assets_blocks.max_harvest_drops]struct { id: u16, count: u16 } = undefined;
    var sn: usize = 0;
    var total: u32 = 0;
    for (drops) |d| {
        // RandomRange(minCount, maxCount+1): uniform count in [min, max].
        var count: u32 = d.count_min;
        if (d.count_max > d.count_min) {
            const span: f64 = @as(f64, @floatFromInt(d.count_max)) + 1.0 -
                @as(f64, @floatFromInt(d.count_min));
            count = d.count_min + @as(u32, @intFromFloat(span * @as(f64, @floatCast(prng.nextFloat()))));
        }
        if (count == 0) continue; // IL: skip if 0 (the count="0" rows).
        // Stick path (IL_0078-0093): only rows with stick_chance >= 0.001
        // participate; the placement roll happens BEFORE the prob gate.
        if (d.stick_chance >= 0.001 and prng.nextFloat() <= d.stick_chance) {
            _ = tryPlaceStuckDrop(self, x, y, z, d.item_name, overall_prob, &prng);
            continue;
        }
        // Prob gate: drop when random < prob (IL `ble.un` on prob <= random).
        if (prng.nextFloat() >= d.prob) continue;
        // Overall gate (IL_01ED / IL_024F: when _overallProb < 0.999).
        if (overall_prob < 0.999 and prng.nextFloat() >= overall_prob) continue;
        // The IL "[recipe]" / "*" names appear on no V3.1.0 b14 drop row;
        // an unknown item fails closed to a skip (missing beats fake).
        const item = self.items.byName(d.item_name) orelse continue;
        if (item.id == 0) continue;
        total +|= count;
        if (sn < stacks.len) {
            stacks[sn] = .{ .id = item.id, .count = @intCast(@min(count, 65535)) };
            sn += 1;
        }
    }
    if (total == 0) return 0;
    // Recipient: Harvest grants to the breaker; a full inventory (stock:
    // ItemDropServer on the ground) and every Destroy/Fall stack become a
    // loot bag at the block.
    var drop_inv: ecs.components.Inventory = .{};
    var dn: usize = 0;
    for (stacks[0..sn]) |st| {
        if (event == .harvest and invsys.give(&self.sim, peer_slot, st.id, st.count)) continue;
        if (dn < ecs.components.max_inv_slots) {
            drop_inv.slots[dn] = .{ .item_id = st.id, .count = st.count, .quality = 1, .meta = 0 };
            dn += 1;
        }
    }
    if (dn > 0) {
        const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
        const fy: f32 = @as(f32, @floatFromInt(y)) + 0.75;
        const fz: f32 = @as(f32, @floatFromInt(z)) + 0.5;
        if (self.sim.spawnLootBagFrom(fx, fy, fz, &drop_inv, 0, dn)) |bag_nid| {
            self.broadcastLootSpawn(bag_nid) catch {};
        }
    }
    return total;
}

/// Harvest wrapper for the dig chokes (breaker's inventory, no overall
/// gate): the terrain harvest drop path.
pub fn tryBlockHarvestDrop(self: *Game, peer_slot: usize, x: i32, y: i32, z: i32, block_id: u16) u32 {
    return rollBlockDropEvent(self, peer_slot, x, y, z, block_id, .harvest, 1.0);
}

/// Stock stick path (Block.DropItemsOnEvent IL_01C7-0235): resolve the
/// drop name as a BLOCK (GetBlockValue), require a non-air block and an
/// air target cell, then place it (SetBlockRPC) - the debris stays stuck
/// in the world instead of becoming a pickable item. Non-block names or
/// solid cells skip (stock loses the drop in those cases too). Returns
/// true when the block was placed.
fn tryPlaceStuckDrop(
    self: *Game,
    x: i32,
    y: i32,
    z: i32,
    name: []const u8,
    overall_prob: f32,
    prng: *rng_util.XorShift32,
) bool {
    if (overall_prob < 0.999 and prng.nextFloat() >= overall_prob) return false;
    const bid = self.maxdamage.idByName(name) orelse return false;
    if (bid == 0) return false;
    const cur = self.world.blockWorld(x, y, z) catch return false;
    if (cur != 0) return false; // target cell must be air
    self.world.setBlockWorld(x, y, z, bid) catch return false;
    if (packages.buildSetBlockBody(self.body_buf[0..64], x, y, z, bid) catch null) |sb| {
        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(x), @floatFromInt(z), self.interest_range) catch {};
    }
    return true;
}

/// Game-side Fall-event landing hook (wired as `sim.fall_land_fn`): a
/// collapsed cell that lands rolls its block's `<drop event="Fall">` rows
/// at the landing position (RE EntityFallingBlock DropItemsOnEvent IL;
/// stick rows re-place the debris block, others bag at the cell).
pub fn fallBlocksLanded(ctx: ?*anyopaque, cells: []const ecs.components.FallingCell) void {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return));
    for (cells) |cell| {
        const tid: u16 = @truncate(cell.raw & 0xffff);
        if (tid == 0) continue;
        _ = rollBlockDropEvent(g, 0, cell.x, cell.y, cell.z, tid, .fall, 1.0);
    }
}

pub fn maybeDestroyContainerOnClose(self: *Game, x: i32, y: i32, z: i32) void {
    const pos = containers_mod.PosKey{ .x = x, .y = y, .z = z };
    const cont = self.containers.get(pos) orelse return;
    const ll = cont.loot_list;
    if (ll.len == 0) return;
    const lc = self.loot.containerByName(ll) orelse return;
    if (lc.destroy_on_close == 0) return;
    if (lc.destroy_on_close == 2) {
        // "empty": destroy only when the player emptied it.
        var empty = true;
        for (cont.slots) |s| {
            if (s.count > 0 and s.item_id != 0) {
                empty = false;
                break;
            }
        }
        if (!empty) return;
    }
    // Drop the remaining contents ("true" mode; "empty" has nothing left).
    var drop_inv: ecs.components.Inventory = .{};
    var n: usize = 0;
    for (cont.slots) |s| {
        if (s.count > 0 and s.item_id != 0 and n < ecs.components.max_inv_slots) {
            drop_inv.slots[n] = s;
            n += 1;
        }
    }
    const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
    const fy: f32 = @as(f32, @floatFromInt(y)) + 0.75;
    const fz: f32 = @as(f32, @floatFromInt(z)) + 0.5;
    if (n > 0) {
        if (self.sim.spawnLootBagFrom(fx, fy, fz, &drop_inv, 0, n)) |bag_nid| {
            self.broadcastLootSpawn(bag_nid) catch {};
        }
    }
    self.containers.remove(pos);
    // Block takes MaxDamage (stock DamageBlock(..., MaxDamage, ...)): air +
    // broadcast, exactly like the block-break paths (tick.zig).
    _ = self.world.setBlockWorld(x, y, z, 0) catch {};
    self.clearBlockHp(x, y, z);
    self.clearBlockRaw(x, y, z);
    if (packages.buildSetBlockBody(&self.body_buf, x, y, z, 0)) |sb| {
        self.broadcastNear("NetPackageSetBlock", sb, fx, fz, self.interest_range) catch {};
    } else |_| {}
}
