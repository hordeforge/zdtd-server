//! Chunk streaming senders, extracted verbatim from game.zig: the join
//! spawn area burst (sendSpawnArea), the per-tick view-square stream with
//! add/remove pacing (streamChunksForClient), the per-client streamed-key
//! membership set, and storage/vending TE delivery per chunk
//! (sendContainersInChunk).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const apm = @import("../../apm/root.zig");
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const containers_mod = @import("../../world/containers.zig");
const vending_mod = @import("../../world/vending.zig");
const light_te_mod = @import("../../world/light_te.zig");
const world_store = @import("../../world/store.zig");
const replicate_te = @import("../replicate_te.zig");
const clock = @import("../../util/clock.zig");

/// Yield between join burst chunk sends so the peer's ACKs land. Loopback RTT
/// is ~100 µs, so 500 µs comfortably drains the reliable window (the LiteNet
/// fragment pump's own `ack_yield_ns` is 2 ms for the retry path); polling
/// alone races the RTT, the window stays full, and every 40 KB chunk
/// fragments against it - the join burst stalled the tick for ~2 s and a
/// second concurrent client's critical packages starved behind the flood
/// (GAP "Join-burst tick budget under concurrent load"). One-time join cost
/// only, never the per-tick stream. The deeper fix (pacing the join through
/// the stream budget / W2b async gen) is tracked in that GAP.
const join_ack_yield_ns: u64 = 500_000;
const game_join = @import("join.zig");

const max_streamed_chunks_cap = game_mod.max_streamed_chunks_cap;

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
    var li: usize = 0;
    while (li < light_te_mod.max_lights) : (li += 1) {
        if (!self.light_te.used[li]) continue;
        const l = &self.light_te.items[li];
        if (l.x < x0 or l.x >= x1 or l.z < z0 or l.z >= z1) continue;
        try replicate_te.sendLightTe(self, peer, l.x, l.y, l.z);
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
            "peer {d} stream queue near capacity n={d}/{d} (warn>={d})\n",
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

/// Ring cell (dx, dz) for the perimeter of the (2r+1)² square: ring r holds
/// 8r cells (r >= 1), enumerated center-out - side 0 top row (left to
/// right), side 1 right column (top to bottom), side 2 bottom row (right to
/// left), side 3 left column (bottom to top).
fn ringCell(ring: i32, j: u32) struct { dx: i32, dz: i32 } {
    const side_len: u32 = @intCast(2 * ring);
    const side: u32 = j / side_len;
    const i: i32 = @intCast(j % side_len);
    return switch (side) {
        0 => .{ .dx = -ring + i, .dz = -ring },
        1 => .{ .dx = ring, .dz = -ring + i },
        2 => .{ .dx = ring - i, .dz = ring },
        else => .{ .dx = -ring, .dz = ring - i },
    };
}

pub fn sendSpawnArea(self: *Game, peer: *ln_peer.Peer, wx: i32, wz: i32, radius: i32) !void {
    const t = world_store.World.worldToChunk(wx, wz);
    // Honor radius 0 (single spawn chunk). Cap 17×17 for viewDist 8 mesh core.
    const r: i32 = @min(@max(radius, 0), self.spawn_area_radius_max);
    var client_ptr: ?*Client = null;
    for (&self.clients) |*cl| {
        if (cl.peer == peer) {
            client_ptr = cl;
            break;
        }
    }
    // Collision-mesh core (rings 0..1 = the spawn chunk + its 8 neighbours)
    // goes out synchronously: the client needs these meshed before
    // World.IsPositionAvailable succeeds (join comments on
    // DynamicClientArrive). The outer rings pace through `drainSpawnArea` at
    // `chunk_adds_per_stream_tick` per tick, so one join cannot stall the
    // 50 ms tick with a 289-chunk synchronous burst (GAP "Join-burst tick
    // budget under concurrent load").
    const core_r: i32 = @min(r, 1);
    var ring: i32 = 0;
    while (ring <= core_r) : (ring += 1) {
        if (ring == 0) {
            const key = packages.makeChunkKey(t.pos.x, t.pos.z);
            if (client_ptr) |cl| {
                if (clientHasStreamed(cl, key)) continue;
            }
            if (try self.sendSpawnChunk(peer, t.pos.x, t.pos.z)) {
                if (client_ptr) |cl| clientAddStreamed(self, cl, key);
            }
        } else {
            const cells: u32 = @intCast(8 * ring);
            var j: u32 = 0;
            while (j < cells) : (j += 1) {
                const cell = ringCell(ring, j);
                const cx = t.pos.x + cell.dx;
                const cz = t.pos.z + cell.dz;
                const key = packages.makeChunkKey(cx, cz);
                if (client_ptr) |cl| {
                    if (clientHasStreamed(cl, key)) continue;
                }
                if (try self.sendSpawnChunk(peer, cx, cz)) {
                    if (client_ptr) |cl| clientAddStreamed(self, cl, key);
                }
                // Let ACKs land between multi-chunk sends: polling alone races
                // the loopback RTT, so yield briefly (join-only) to keep the
                // reliable window draining and other peers' critical packets
                // interleaved.
                self.pollNetOnce();
                clock.sleepNs(join_ack_yield_ns);
            }
        }
    }
    // Outer rings: arm the paced drain. Idempotent across the two join-phase
    // call sites (DynamicClientArrive + RequestToSpawnPlayer): a second call
    // with the same center keeps the drain's ring progress instead of
    // restarting it.
    if (r > core_r) {
        if (client_ptr) |cl| {
            if (cl.pending_area_r < 0 or cl.pending_area_cx != t.pos.x or cl.pending_area_cz != t.pos.z) {
                cl.pending_area_r = r;
                cl.pending_area_cx = t.pos.x;
                cl.pending_area_cz = t.pos.z;
                cl.pending_area_ring = core_r + 1;
                cl.pending_area_idx = 0;
            }
        }
    }
}

/// Drain a client's pending spawn-area rings against a SHARED per-tick
/// budget (`chunk_adds_per_stream_tick` across all clients, center-out;
/// concurrent joins split it so the tick cannot stack 16+ chunk bodies).
/// Called from replicate for every client with a peer; no-op when nothing is
/// pending or the shared budget is exhausted. Overlap with the per-tick view
/// stream is harmless (clientHasStreamed dedupes, and the stream only runs
/// for entered/world_ready clients).
pub fn drainSpawnArea(self: *Game, c: *Client, budget: *u32) !void {
    const peer = c.peer orelse return;
    if (c.pending_area_r < 0) return;
    const ds = apm.profiler.scope(&self.harness.prof, .join_drain);
    defer ds.end();
    while (budget.* > 0) {
        const ring = c.pending_area_ring;
        if (ring > c.pending_area_r) {
            c.pending_area_r = -1; // full area drained
            return;
        }
        const cells: u32 = @intCast(8 * ring);
        if (c.pending_area_idx >= cells) {
            c.pending_area_ring += 1;
            c.pending_area_idx = 0;
            continue;
        }
        const cell = ringCell(ring, c.pending_area_idx);
        c.pending_area_idx += 1;
        const cx = c.pending_area_cx + cell.dx;
        const cz = c.pending_area_cz + cell.dz;
        const key = packages.makeChunkKey(cx, cz);
        if (clientHasStreamed(c, key)) continue;
        if (!try self.sendSpawnChunk(peer, cx, cz)) continue;
        clientAddStreamed(self, c, key);
        budget.* -= 1;
        // ACK-yield between drain chunks, same as the join core: a bursted
        // batch overflows the reliable window (measured 257 drops without it;
        // loopback RTT ~100 µs, so the 500 µs yield drains the window per
        // chunk). ~20 ms per pass stays inside the tick budget.
        self.pollNetOnce();
        clock.sleepNs(join_ack_yield_ns);
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
        const t = world_store.World.worldToChunk(@trunc(self.sim.transform[si].x), @trunc(self.sim.transform[si].z));
        // Keep a hole-free disk so light/mesh neighbor rings stay valid.
        // Client mesh needs ~2-chunk halo: with r=4 only the inner 5×5 (25)
        // become CGO; spawn overlay needs viewDist^2-10 (viewDist 7 → 39).
        // Stream up to view_radius (max self.chunk_stream_radius_max) so the meshable core clears the bar.
        var r: i32 = @min(@max(c.view_radius, self.chunk_stream_radius_min), self.chunk_stream_radius_max);
        // Shrink to a square that fits the budget: truncating the raster scan
        // instead would leave a southern band, not the centered hole-free disk
        // the comment above requires (radius 7 wants 225 vs a 169 cap).
        while (r > 1 and @as(usize, @intCast((2 * r + 1) * (2 * r + 1))) > self.max_streamed_chunks) r -= 1;
        const tcx = t.pos.x;
        const tcz = t.pos.z;
        const side: i32 = 2 * r + 1;
        // Relative membership of currently streamed keys inside the view
        // square: O(streamed_n) build, O(1) probe. Replaces O(n²) desired[]
        // linear scans (up to 625×625 per client per stream period). 640 bits
        // covers the r=12 square (25×25 = 625).
        var in_view = std.StaticBitSet(640).initEmpty();
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
                if (bit < 640) in_view.set(bit);
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
                if (bit < 640 and in_view.isSet(bit)) continue;
                const cx = tcx + dx;
                const cz = tcz + dz;
                const key = packages.makeChunkKey(cx, cz);
                // Cap path / race: bitset miss but list still holds key.
                if (clientHasStreamed(c, key)) continue;
                if (!try self.sendSpawnChunk(peer, cx, cz)) continue;
                clientAddStreamed(self, c, key);
                in_view.set(bit);
                // Deco for the newly-streamed chunk: the client's
                // DecoManager.Read adds post-join firstPackage=false updates
                // (RE IL), so decorations stream with the world instead of the
                // join window only. Tracked per deco chunk; harmless overlap
                // with the join burst (client HashSet + mirror both dedupe).
                game_join.sendDecoForStreamedChunk(self, c, peer, cx, cz) catch |err| {
                    std.debug.print("zdtd: stream deco failed at {d},{d}: {s}\n", .{ cx, cz, @errorName(err) });
                };
                added += 1;
            }
        }
    }
}
