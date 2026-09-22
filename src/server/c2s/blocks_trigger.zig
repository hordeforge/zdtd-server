//! C2S block arms: trigger, water set.
//!
//! Split out of c2s/blocks.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");

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
