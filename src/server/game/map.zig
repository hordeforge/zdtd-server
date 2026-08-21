//! In-game minimap: per-chunk 256-cell color computation + MapChunks send.
//!
//! RE texture-atlas.md / protocol-packages.md §3.3: the client drives the map
//! by sending NetPackageMapPosition (its map middle); the server replies with
//! NetPackageMapChunks (channel 1, compressed) covering a 17x17 chunk window
//! around the middle, one 256-color piece per chunk. Colors follow
//! Chunk.CalcChunkColors -> Block.GetMapColor (MapColor property, else the
//! mesh atlas color, else gray), with water cells taking BlockLiquidv2.Color.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const map_atlas = @import("../../assets/map_atlas.zig");
const world_store = @import("../../world/store.zig");

/// Map pieces per send (the stock producer sends the whole window at once;
/// zdtd batches to bound the per-frame cost - the client just adds pieces).
/// 8 pieces = 4128 bytes raw, under the test capture cap and tiny per frame.
const map_batch: usize = 8;

/// How far above the terrain surface the top-block walk looks (stock walks
/// the whole 256 column; a minimap cell above a 64+-block structure is
/// invisible, so the bound is a documented perf floor).
const map_walk_above: i32 = 64;

/// Per-chunk 256-cell minimap colors (RE Chunk.CalcChunkColors): per cell the
/// top visible block wins; water takes BlockLiquidv2.Color, otherwise
/// Block.GetMapColor (MapColor property, else the mesh atlas color, else
/// gray).
pub fn chunkMapColors(self: *Game, cx: i32, cz: i32, out: *[256]u16) void {
    const pos = world_store.World.worldToChunk(cx * world_store.chunk_size, cz * world_store.chunk_size);
    const ch = self.world.getOrCreate(pos.pos) catch {
        @memset(out[0..256], map_atlas.gray_color5);
        return;
    };
    const water_id = self.world.terrain_ids.water;
    for (0..16) |bz| {
        for (0..16) |bx| {
            const h = ch.heightAt(@intCast(bx), @intCast(bz));
            var color: u16 = map_atlas.gray_color5;
            var found = false;
            var y: i32 = @min(@as(i32, h) + map_walk_above, world_store.y_dim - 1);
            while (y >= @as(i32, h)) : (y -= 1) {
                const bid = ch.blockAt(@intCast(bx), y, @intCast(bz));
                if (bid == 0) continue;
                found = true;
                color = blockMapColor(self, bid, water_id);
                break;
            }
            if (!found) {
                // No placed block above the surface: the synthesized terrain
                // at the surface (rawAt fallback ids) is the visible block.
                color = blockMapColor(self, ch.blockAt(@intCast(bx), h, @intCast(bz)), water_id);
            }
            out[@intCast(bz * 16 + bx)] = color;
        }
    }
}

/// One block's minimap color: water -> liquid color; else MapColor property,
/// else the mesh atlas color, else gray (RE texture-atlas.md).
fn blockMapColor(self: *Game, bid: u16, water_id: u16) u16 {
    if (bid == water_id) return map_atlas.water_color5;
    if (self.blocks.byId(bid)) |def| {
        return map_atlas.blockColor5(def.mesh, def.texture_top, def.map_color) orelse map_atlas.gray_color5;
    }
    return map_atlas.gray_color5;
}

/// Send unsent map chunks for every client with a map middle: walk the 17x17
/// window (RE MapChunkDatabase.GetMapChunkPackagesToSend), compute + send up
/// to `map_batch` pieces per tick on channel 1 compressed (MapChunks
/// Compress=true). The sent set resets when the middle moves (C2S handler).
pub fn tickMapChunks(self: *Game) void {
    for (&self.clients) |*c| {
        const peer = c.peer orelse continue;
        if (!c.joined or !c.entered or !c.map_middle_set) continue;
        const cx = c.map_middle_x >> 4;
        const cz = c.map_middle_z >> 4;
        var pieces: [map_batch]packages.MapChunkPiece = undefined;
        var n: usize = 0;
        var idx: usize = 0;
        while (idx < game_mod.map_window_n and n < map_batch) : (idx += 1) {
            if (c.map_chunks_sent[idx] != 0) continue;
            const dx: i32 = @as(i32, @intCast(idx / 17)) - game_mod.map_window_radius;
            const dz: i32 = @as(i32, @intCast(idx % 17)) - game_mod.map_window_radius;
            const kx = cx + dx;
            const kz = cz + dz;
            var colors: [256]u16 = undefined;
            chunkMapColors(self, kx, kz, &colors);
            pieces[n] = .{
                .key = (@as(i32, @intCast(@as(u32, @bitCast(kx)) & 0xFFFF)) << 16) |
                    @as(i32, @intCast(@as(u32, @bitCast(kz)) & 0xFFFF)),
                .colors = colors,
            };
            c.map_chunks_sent[idx] = 1;
            n += 1;
        }
        if (n == 0) continue;
        if (packages.buildMapChunksBody(&self.body_buf, c.entity_id, pieces[0..n])) |body| {
            // Channel 1 + deflate (MapChunks Compress=true), normal budget.
            _ = self.trySendCompressed(peer, "NetPackageMapChunks", body);
        } else |_| {
            self.harness.counters.inc(.encode_errors);
        }
    }
}

/// NetPackagePersistentPlayerPositions broadcast (RE GameManager
/// playerPositionsCountdownTimer: 6 s cadence to all clients): the client's
/// map shows online players. Entries = every joined client with a live
/// entity, as platform id + int-truncated world position (Vector3i).
pub fn tickPlayerPositions(self: *Game) void {
    if (self.player_positions_timer > 0) {
        self.player_positions_timer -= 1;
        return;
    }
    self.player_positions_timer = 120; // 6 s at 20 TPS (stock timer value)
    var entries: [game_mod.max_clients]packages.PlayerPositionEntry = undefined;
    var n: usize = 0;
    for (&self.clients) |*c| {
        if (!c.joined or c.entity_id <= 0) continue;
        const si = self.sim.slotOfNetId(c.entity_id) orelse continue;
        if (!self.sim.alive[si] or !self.sim.mask[si].transform) continue;
        if (n >= entries.len) break;
        entries[n] = .{
            .id = c.puid_primary.get(),
            .x = @intFromFloat(@trunc(self.sim.transform[si].x)),
            .y = @intFromFloat(@trunc(self.sim.transform[si].y)),
            .z = @intFromFloat(@trunc(self.sim.transform[si].z)),
        };
        n += 1;
    }
    if (n == 0) return;
    if (packages.buildPersistentPlayerPositionsBody(&self.body_buf, entries[0..n])) |body| {
        self.broadcast("NetPackagePersistentPlayerPositions", body) catch {};
    } else |_| {}
}

/// Broadcast the client's dropped-backpack marker (NetPackagePlayerSetBackpackPosition,
/// RE EntityBackpack / PersistentPlayerData): one position when the death bag
/// is live, empty when collected.
pub fn broadcastPlayerBackpack(self: *Game, c: *Client) !void {
    var positions: [1][3]i32 = undefined;
    var n: usize = 0;
    if (c.has_backpack) {
        positions[0] = .{ c.backpack_x, c.backpack_y, c.backpack_z };
        n = 1;
    }
    if (packages.buildPlayerSetBackpackPositionBody(&self.body_buf, c.entity_id, positions[0..n])) |body| {
        try self.broadcast("NetPackagePlayerSetBackpackPosition", body);
    } else |_| {
        self.harness.counters.inc(.encode_errors);
    }
}
