//! C2S block arms: trigger, water set.
//!
//! Split out of c2s/blocks.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const world_mod = @import("../../world/root.zig");
const blocktrigger = @import("../../world/blocktrigger.zig");

/// `BlockHazard.OnTriggered` (IL=49): toggle the shared on/off state bit
/// (meta bit 1) at the cell. The sound is client-side.
fn toggleHazardState(self: *Game, wx: i32, wy: i32, wz: i32) void {
    const cur: u32 = self.world.blockWorld(wx, wy, wz) catch return;
    const meta: u32 = (cur >> 16) & 31;
    const next = blocktrigger.BlockTrigger.setOnState(meta, !blocktrigger.BlockTrigger.isOnState(meta));
    const raw = (cur & ~(@as(u32, 31) << 16)) | (next << 16);
    self.world.setBlockWorld(wx, wy, wz, @truncate(raw)) catch {};
}

/// `BlockLight.OnTriggered` (IL=26): toggle the block-light nibble at the
/// cell. The source level is the block's blocks.xml `LightValue`; toggling
/// means 0 when it is on and the level when it is off.
fn toggleBlockLight(self: *Game, wx: i32, wy: i32, wz: i32) void {
    const t = world_mod.store.World.worldToChunk(wx, wz);
    const c = self.world.getOrCreate(t.pos) catch return;
    const lights = c.lights orelse return;
    if (wy < 0 or wy >= c.*.y_dim) return;
    const idx: usize = @intCast(t.lx + t.lz * 16 + wy * 256);
    if (idx >= lights.len) return;
    const cur = lights[idx] >> 4;
    const level: u8 = if (cur > 0) 0 else 15;
    world_mod.store.Chunk.setLight(c, t.lx, wy, t.lz, level, false);
}

/// True when `name` is a trigger/water package and was handled.
pub fn handleTrigger(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageBlockTrigger")) {
        // Divergence (DIVERGENCES 3): stock consumes this package server-side
        // (`ProcessPackage` -> `Block::HandleTrigger` -> `TriggerManager::
        // TriggerBlocks`, Block.il.txt IL=41) and forwards nothing. zdtd has
        // no trigger-volume sim and rebroadcasts instead; receiving clients
        // ignore it, because their ProcessPackage reads
        // `Sender.bAttachedToEntity` and `Sender` is only set server-side.
        // Drop the broadcast once the trigger sim lands.
        //
        // Same rate gate as SetBlock: unthrottled would let a spam loop fan
        // this broadcast out to every nearby peer for free (bandwidth DoS).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Trust boundary (rule 17/20): the body is `Vector3i blockPos` +
        // `u32 BlockValue.rawData` (`NetPackageBlockTrigger.il.txt:16`). A
        // short body or a position outside the world is a malformed claim,
        // not a relay. T36 adds the wiring check on top of this: reject when
        // the prefab's trigger table is present at the cell and the block has
        // no `TriggersIndices` there.
        if (body.len < 16) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        const bx = std.mem.readInt(i32, body[0..4], .little);
        const by = std.mem.readInt(i32, body[4..8], .little);
        const bz = std.mem.readInt(i32, body[8..12], .little);
        const raw = std.mem.readInt(u32, body[12..16], .little);
        if (!game_mod.coordInRange(@floatFromInt(bx)) or
            !game_mod.coordInRange(@floatFromInt(by)) or
            !game_mod.coordInRange(@floatFromInt(bz)))
        {
            self.harness.counters.inc(.bounds_rejects);
            return true;
        }
        // T36 wiring check + dispatch: when a stamped prefab has trigger
        // wiring at the cell, the block must have `TriggersIndices` there, and
        // the fire latches the channel and runs the AND/OR combine before any
        // mutation. A claim on a cell with no wiring passes (the prefab may be
        // unloaded), but a claim on a wired cell that does not fire is
        // rejected, and a latch on a channel the block does not listen to is
        // refused.
        if (self.world.prefabs) |*pf| {
            if (pf.triggerAt(bx, by, bz)) |bt| {
                if (!bt.hasAnyTriggers()) {
                    self.harness.counters.inc(.phase_rejects);
                    return true;
                }
                // `BlockTrigger.OnTriggered` (IL=27): latch the fired channel,
                // then the combine. The channel is the block's own fire
                // channel (its `TriggersIndices`), which is the claim.
                var wire: blocktrigger.BlockTrigger = bt.*;
                var fired = false;
                for (bt.triggers[0..bt.triggers_n]) |ch| {
                    if (wire.latch(ch)) fired = true;
                }
                if (!fired or !wire.isOn()) {
                    self.harness.counters.inc(.phase_rejects);
                    return true;
                }
                wire.clearLatched();
                // `Block.OnTriggered` (block-shapes.md 7.3): every mutating
                // variant appends a `BlockChangeInfo` for the block position.
                // The switch toggle and the door auto-close are the other two
                // classes; these two are the world writes the relay can make.
                const cur_id: u16 = @truncate(raw);
                const cname = self.maxdamage.idName(cur_id) orelse "";
                // `BlockTriggerDowngrade` (IL=15): `HandleDowngrade` swaps the
                // block to its blocks.xml `DowngradeBlock`.
                if (self.maxdamage.downgradeTarget(cname)) |target| {
                    if (self.maxdamage.idByName(target)) |nid| {
                        self.world.setBlockWorld(bx, by, bz, nid) catch {};
                    }
                } else if (self.maxdamage.isTrapDoor(cur_id)) {
                    // `BlockTrapDoor` (IL=26): destroys itself, which is the
                    // downgrade to air (`DamageBlock(MaxDamage - damage)`).
                    self.world.setBlockWorld(bx, by, bz, 0) catch {};
                } else if (self.maxdamage.lightValue(cname) > 0) {
                    // `BlockLight.OnTriggered` (IL=26): `SetLightState(world,
                    // pos, bv, !IsLightOn)` - toggles the block-light nibble
                    // at the cell (light-mesh-water.md `Chunk.SetLight`).
                    toggleBlockLight(self, bx, by, bz);
                } else if (self.maxdamage.isHazard(cur_id)) {
                    // `BlockHazard.OnTriggered` (IL=49): toggles the hazard
                    // state (shared meta bit 1, block-shapes.md 7.3). The
                    // Start/StopSound at the block center is client-side.
                    toggleHazardState(self, bx, by, bz);
                } else if (self.maxdamage.onTriggeredEvent(cname)) |ev| {
                    // `BlockGameEvent.OnTriggered` (IL=60): runs the block's
                    // game-event sequence. `destroyOnEvent` destroys the block
                    // after it runs (the same write as the trap door).
                    _ = self.runGameEventSequence(c.slot, ev);
                    if (self.maxdamage.destroyOnEvent(cname)) {
                        self.world.setBlockWorld(bx, by, bz, 0) catch {};
                    }
                }
            }
        }
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        try self.broadcastNear("NetPackageBlockTrigger", body, self.sim.transform[ps].x, self.sim.transform[ps].z, self.interest_range);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageWaterSet")) {
        // Stock water edits (jar fill/empty, the water-cube tool) originate on
        // the acting client: ProcessPackage relays to every other peer and
        // then applies (NetPackageWaterSet.il.txt:163). Dropping it left the
        // change local to the sender and lost on relog.
        if (self.quarantineDenies(c, .block)) return true;
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        var changes: [32]packages.WaterSetChange = undefined;
        const got = packages.parseWaterSet(body, changes[0..]) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (got.n == 0) return true;
        const editor = self.sim.playerByPeer(c.slot) orelse return true;
        const editor_ent = self.sim.network_id[editor].id;
        if (got.sender != editor_ent) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const ep = self.sim.transform[editor];
        var accepted: [32]packages.WaterSetChange = undefined;
        var an: usize = 0;
        var wi: usize = 0;
        while (wi < got.n) : (wi += 1) {
            const ch = changes[wi];
            if (self.rejectIfBeyondEditRange(
                c,
                peer.local_id,
                editor_ent,
                .block,
                ep.x,
                ep.y,
                ep.z,
                @floatFromInt(ch.x),
                @floatFromInt(ch.y),
                @floatFromInt(ch.z),
            )) continue;
            if (self.claimCovering(ch.x, ch.z)) |claim| {
                if (claim.owner_entity != editor_ent) continue;
            }
            // Mass 0 empties the cell, anything else fills it. zdtd models
            // water as a block id, so the edit rides the normal block path
            // and persists with the chunk.
            const id: u16 = if (ch.mass == 0) self.world.terrain_ids.air else self.world.terrain_ids.water;
            self.world.setBlockWorld(ch.x, ch.y, ch.z, id) catch continue;
            accepted[an] = ch;
            an += 1;
        }
        if (an == 0) return true;
        // Relay only what the server accepted, never the raw body: stock
        // excludes the sender, who already applied it locally.
        var relay_buf: [4 + 2 + 32 * 14]u8 = undefined;
        const relay = packages.buildWaterSetBody(&relay_buf, editor_ent, accepted[0..an]) catch {
            self.harness.counters.inc(.encode_errors);
            return true;
        };
        try self.broadcastExcept("NetPackageWaterSet", relay, c.slot);
        return true;
    }
    return false;
}
