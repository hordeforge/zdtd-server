//! Chunk delivery to clients: on-demand generation/load (sendSpawnChunk), the
//! per-chunk storage-TE and power scans, container fill/send, the streamed-key
//! bookkeeping and the paced streamChunksForClient pass.
//!
//! Extracted from game.zig following the replicate_te precedent: these take
//! `*Game` (or the raw args) and are called as `chunk_stream.streamChunksForClient(g, …)`.
//! game.zig keeps one-line delegating methods so existing callers are unchanged.

const std = @import("std");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../litenet/peer.zig");
const ln_packet = @import("../litenet/packet.zig");
const packages = @import("../wire/packages.zig");
const wire_binary = @import("../wire/binary.zig");
const world_store = @import("../world/store.zig");
const containers_mod = @import("../world/containers.zig");
const ecs = @import("../ecs/root.zig");
const apm = @import("../apm/root.zig");
const clock = @import("../util/clock.zig");
const assets_block_textures = @import("../assets/block_textures.zig");
const assets_loot = @import("../assets/loot.zig");
const replicate_te = @import("replicate_te.zig");
const vending_mod = @import("../world/vending.zig");
const te_types = packages.te_types;
const max_streamed_chunks_cap = game_mod.max_streamed_chunks_cap;
const window_fast_attempts = game_mod.window_fast_attempts;
const window_retry_sleep_ns = game_mod.window_retry_sleep_ns;

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
    // Stock Chunk.write payload inside NetPackageChunk (overwrite=false first delivery).
    const body = try packages.stock_chunk.buildNetPackageChunkNew(&self.body_buf, .{
        .cx = cx,
        .cz = cz,
        .heights = &ch.heights,
        .ticks = self.sim.director.clock.worldTimeBits(),
        .biome = biome_id,
        .block_at = BlockCtx.at,
        .block_ctx = ch,
        .tex_at = BlockCtx.tex,
        .default_tex = TexCtx.def,
        .default_tex_ctx = &tex_ctx,
        .dens_at = BlockCtx.dens,
        .water_block_id = self.world.terrain_ids.water,
        .raws_scratch = &self.chunk_raws,
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
pub fn lootSeedAt(wx: i32, wy: i32, wz: i32) u32 {
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
                if (found >= 32) return;
            }
        }
    }
    // Prefab TE list (TileEntityType Loot=5, SecureLoot=10, Composite=25).
    if (self.world.prefabs) |*pf| {
        const TeCtx = struct {
            g: *Game,
            found: *u32,
            fn onTe(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, te_type: u8) void {
                const tc: *@This() = @ptrCast(@alignCast(ctx.?));
                if (tc.found.* >= 48) return;
                // Loot-like types only.
                if (!(te_types.isStorageLike(te_type) or te_type == te_types.powered or te_types.isSignLike(te_type) or te_type == te_types.light)) return;
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
        if (te_found < 48) ch.te_scanned = true;
    } else {
        ch.te_scanned = true;
    }
}

pub fn fillContainerFromLoot(self: *Game, cont: *containers_mod.Container, loot_name: []const u8, seed: u32) void {
    var stacks: [assets_loot.max_roll_stacks]assets_loot.Stack = undefined;
    const n = self.loot.rollContainer(loot_name, self.partyLootStage(), seed, &stacks);
    var si: usize = 0;
    var i: usize = 0;
    while (i < n and si < cont.slot_count) : (i += 1) {
        const eid = self.ecsIdFromItemName(stacks[i].item_name);
        if (eid == 0) continue;
        cont.setSlot(si, .{ .item_id = eid, .count = stacks[i].count, .quality = 1 });
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

pub fn sendContainersInChunk(self: *Game, peer: *ln_peer.Peer, cx: i32, cz: i32) !void {
    const x0 = cx * 16;
    const z0 = cz * 16;
    const x1 = x0 + 16;
    const z1 = z0 + 16;
    var i: usize = 0;
    while (i < containers_mod.max_containers) : (i += 1) {
        if (!self.containers.used[i]) continue;
        const cont = &self.containers.items[i];
        if (cont.pos.x < x0 or cont.pos.x >= x1 or cont.pos.z < z0 or cont.pos.z >= z1) continue;
        try replicate_te.sendStorageTe(self, peer, cont.pos.x, cont.pos.y, cont.pos.z);
    }
    var vi: usize = 0;
    while (vi < vending_mod.max_vending) : (vi += 1) {
        if (!self.vending.used[vi]) continue;
        const v = &self.vending.items[vi];
        if (v.pos.x < x0 or v.pos.x >= x1 or v.pos.z < z0 or v.pos.z >= z1) continue;
        try replicate_te.sendVendingTe(self, peer, v.pos.x, v.pos.y, v.pos.z);
    }
}

pub fn clientHasStreamed(c: *const Client, key: i64) bool {
    var i: usize = 0;
    while (i < c.streamed_n) : (i += 1) {
        if (c.streamed[i] == key) return true;
    }
    return false;
}

pub fn clientAddStreamed(self: *Game, c: *Client, key: i64) void {
    if (clientHasStreamed(c, key)) return;
    if (c.streamed_n >= max_streamed_chunks_cap) {
        // drop oldest (FIFO shift; order only matters for this policy)
        var i: usize = 1;
        while (i < c.streamed_n) : (i += 1) c.streamed[i - 1] = c.streamed[i];
        c.streamed_n -= 1;
    }
    c.streamed[c.streamed_n] = key;
    c.streamed_n += 1;
    const warn_at = @max(@as(usize, 1), (self.max_streamed_chunks * 4) / 5);
    if (!c.stream_cap_warned and c.streamed_n >= warn_at) {
        c.stream_cap_warned = true;
        std.debug.print(
            "zdtd: peer {d} stream queue near capacity n={d}/{d} (warn>={d})\n",
            .{ c.slot, c.streamed_n, self.max_streamed_chunks, warn_at },
        );
    }
}

pub fn clientRemoveStreamed(c: *Client, key: i64) void {
    var i: usize = 0;
    while (i < c.streamed_n) : (i += 1) {
        if (c.streamed[i] != key) continue;
        // Membership only; swap-remove avoids O(n) memmove.
        c.streamed_n -= 1;
        c.streamed[i] = c.streamed[c.streamed_n];
        return;
    }
}

pub fn sendSpawnArea(self: *Game, peer: *ln_peer.Peer, wx: i32, wz: i32, radius: i32) !void {
    const t = world_store.World.worldToChunk(wx, wz);
    // Honor radius 0 (single spawn chunk). Cap 17×17 for viewDist 8 mesh core.
    var r: i32 = if (radius < 0) 0 else radius;
    if (r > self.spawn_area_radius_max) r = self.spawn_area_radius_max;
    var client_ptr: ?*Client = null;
    for (&self.clients) |*cl| {
        if (cl.peer == peer) {
            client_ptr = cl;
            break;
        }
    }
    var dz: i32 = -r;
    while (dz <= r) : (dz += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            const cx = t.pos.x + dx;
            const cz = t.pos.z + dz;
            // Re-sending a chunk the client already holds costs reliable
            // window the missing chunks need, and the client logs
            // "chunk already loaded" for every one.
            if (client_ptr) |cl| {
                if (clientHasStreamed(cl, packages.makeChunkKey(cx, cz))) continue;
            }
            const delivered = try self.sendSpawnChunk(peer, cx, cz);
            if (delivered) {
                if (client_ptr) |cl| self.clientAddStreamed(cl, packages.makeChunkKey(cx, cz));
            }
            // Let ACKs land between multi-chunk sends.
            self.pollNetOnce();
        }
    }
}

/// Stream chunks around player and remove far ones (stock ChunkRemove key).
/// Caps: `self.max_streamed_chunks`, `chunk_stream_radius_{min,max}`,
/// `self.chunk_adds_per_stream_tick` (named; no magic pacing numbers).
pub fn streamChunksForClient(self: *Game, c: *Client) !void {
    const cs = apm.profiler.scope(&self.harness.prof, .chunk_stream);
    defer cs.end();
    const peer = c.peer orelse return;
    if (self.sim.slotOfNetId(c.entity_id)) |si| {
        const t = world_store.World.worldToChunk(@intFromFloat(self.sim.transform[si].x), @intFromFloat(self.sim.transform[si].z));
        // Keep a hole-free disk so light/mesh neighbor rings stay valid.
        // Client mesh needs ~2-chunk halo: with r=4 only the inner 5×5 (25)
        // become CGO; spawn overlay needs viewDist^2-10 (viewDist 7 → 39).
        // Stream up to view_radius (max self.chunk_stream_radius_max) so the meshable core clears the bar.
        var r: i32 = if (c.view_radius < 1) self.chunk_stream_radius_min else c.view_radius;
        if (r < self.chunk_stream_radius_min) r = self.chunk_stream_radius_min;
        if (r > self.chunk_stream_radius_max) r = self.chunk_stream_radius_max;
        // Shrink to a square that fits the budget: truncating the raster scan
        // instead would leave a southern band, not the centered hole-free disk
        // the comment above requires (radius 7 wants 225 vs a 169 cap).
        while (r > 1 and @as(usize, @intCast((2 * r + 1) * (2 * r + 1))) > self.max_streamed_chunks) r -= 1;
        const tcx = t.pos.x;
        const tcz = t.pos.z;
        const side: i32 = 2 * r + 1;
        // Relative membership of currently streamed keys inside the view
        // square: O(streamed_n) build, O(1) probe. Replaces O(n²) desired[]
        // linear scans (up to 169×169 per client per stream period).
        var in_view = std.StaticBitSet(256).initEmpty();
        {
            var si_i: usize = 0;
            while (si_i < c.streamed_n) : (si_i += 1) {
                const key = c.streamed[si_i];
                const cx = packages.extractChunkKeyX(key);
                const cz = packages.extractChunkKeyZ(key);
                const dx = cx - tcx;
                const dz = cz - tcz;
                if (@abs(dx) > r or @abs(dz) > r) continue;
                const bit: usize = @intCast((dx + r) + (dz + r) * side);
                if (bit < 256) in_view.set(bit);
            }
        }
        // removes: keys outside the current square
        var i: usize = 0;
        while (i < c.streamed_n) {
            const key = c.streamed[i];
            const cx = packages.extractChunkKeyX(key);
            const cz = packages.extractChunkKeyZ(key);
            const dx = cx - tcx;
            const dz = cz - tcz;
            const keep = @abs(dx) <= r and @abs(dz) <= r;
            if (!keep) {
                const rb = try packages.buildChunkRemoveBody(self.body_buf[0..16], cx, cz);
                try self.sendGame(peer, "NetPackageChunkRemove", rb);
                // Stock never sends this on view unload: DecoManager.ResetDecosForWorldChunk
                // is only broadcast from RegionFileManager chunk deletion and the C2S
                // reset handler (asm.il 1186504 / 807955). With join-time deco objects
                // live it would run RestoreGeneratedDecos over our trees on every walk-away,
                // and they can never be resent (single window). Only send when we sent none.
                if (!self.deco_trees) {
                    if (packages.stock_deco.buildDecoResetWorldChunk(self.body_buf[16..32], cx, cz)) |db| {
                        self.sendGame(peer, "NetPackageDecoResetWorldChunk", db) catch {};
                    } else |_| {}
                }
                clientRemoveStreamed(c, key);
                // do not advance i: swap-remove put a new key at i
            } else {
                i += 1;
            }
        }
        // adds: enough per pass to fill 13×13 before overlay timeout; still
        // paced so LiteNet reliable window can drain.
        var added: u32 = 0;
        var dz: i32 = -r;
        outer: while (dz <= r) : (dz += 1) {
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                if (added >= self.chunk_adds_per_stream_tick) break :outer;
                const bit: usize = @intCast((dx + r) + (dz + r) * side);
                if (bit < 256 and in_view.isSet(bit)) continue;
                const cx = tcx + dx;
                const cz = tcz + dz;
                const key = packages.makeChunkKey(cx, cz);
                // Cap path / race: bitset miss but list still holds key.
                if (clientHasStreamed(c, key)) continue;
                if (!try self.sendSpawnChunk(peer, cx, cz)) continue;
                self.clientAddStreamed(c, key);
                in_view.set(bit);
                // No per-chunk deco: the client drains and nulls DecoManager.loadedDecos
                // at the end of OnWorldLoaded, so a post-join DecoUpdate either NREs
                // (firstPackage=false) or is silently discarded (firstPackage=true).
                // Deco ships once, at RequestToEnterGame (sendDecoAroundSpawn).
                added += 1;
            }
        }
    }
}

/// Fan-out already-framed user payload to one peer (no re-encode). Soft-drops
/// WindowFull the same way as droppable streaming packages.
/// Unreliable fan-out for the motion frames (PosAndRot / Speeds): fire and
/// forget, never touches the reliable window. Oversized or failed sends are
/// dropped (motion is replaced by the next tick's frame anyway).
pub fn sendFramedUnreliable(self: *Game, peer: *ln_peer.Peer, framed: []const u8) void {
    if (framed.len > ln_packet.max_single_user) {
        // Oversized motion frame: fall back to the droppable reliable path
        // rather than silently dropping something the client waits for.
        self.sendFramedDroppable(peer, framed);
        return;
    }
    peer.sendUnreliable(&self.net.sock, framed) catch {
        self.harness.counters.inc(.net_send_errors);
    };
    self.harness.counters.add(.net_packets_out, 1);
    self.harness.counters.add(.net_bytes_out, framed.len);
}

pub fn sendFramedDroppable(self: *Game, peer: *ln_peer.Peer, framed: []const u8) void {
    // One shared retry shape (sendReliablePumped); no deadline, 64-attempt cap.
    self.sendReliablePumped(peer, "framed-stream", framed, null, 64, true) catch |err| switch (err) {
        error.WindowFull => {
            self.harness.counters.inc(.reliable_window_drops);
            const n = self.harness.counters.get(.reliable_window_drops);
            if (n == 1 or n % 100 == 0) {
                std.debug.print(
                    "zdtd: drop framed stream (reliable window full) n={d} local_id={d}\n",
                    .{ n, peer.local_id },
                );
            }
        },
        else => {},
    };
}
