//! Block editing: SetBlock, BlockTrigger, Explosions.
//! Extracted from the old c2s/inv.zig tail (643-991) verbatim.

const std = @import("std");
const chunk_fill = @import("../game/chunk_fill.zig");
const game_world = @import("../game/world.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const platform_user = packages.platform_user;
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const invsys = @import("../../ecs/inventory.zig");
const protocol = @import("../../protocol.zig");
const systems = @import("../../ecs/systems.zig");
const replicate_te = @import("../game/replicate_te.zig");
const plugin_compose = @import("../game/plugin_compose.zig");
const blocks_trigger = @import("blocks_trigger.zig");
const blocks_pickup = @import("blocks_pickup.zig");
const blocks_setblock = @import("blocks_setblock.zig");
const blocks_explosion = @import("blocks_explosion.zig");

/// Cap on the C2S-claimed explosion radii. Lives in blocks_explosion.zig;
/// this alias keeps the name resolving for any out-of-tree caller.
const max_claimed_explosion_radius = blocks_explosion.max_claimed_explosion_radius;

/// Bound on the `PassThroughDamage` downgrade-chain walk. Lives in
/// blocks_setblock.zig with the SetBlock arm.
const max_passthrough_depth = blocks_setblock.max_passthrough_depth;

pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (try blocks_trigger.handleTrigger(self, c, peer, name, body)) return true;
    if (try blocks_pickup.handlePickup(self, c, peer, name, body)) return true;
    if (try blocks_setblock.handleSetBlock(self, c, peer, name, body)) return true;
    if (try blocks_explosion.handleExplosion(self, c, peer, name, body)) return true;
    if (std.mem.eql(u8, name, "NetPackageItemActionEffects")) {
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // GameManager.ItemActionEffectsServer (IL=87,
        // il/full-v3.2.0/_global/GameManager.il.txt:8348) rebroadcasts with
        // _allButAttachedToEntityId = the firing entity, so stock skips the
        // shooter's own client, not "whoever sent the packet". Those agree
        // only when the id is the sender's own. Re-encoding is unnecessary
        // here (the parse consumes the whole body or fails), but the relay
        // still forwards body[0..wire_len] so appended bytes never fan out.
        const fx = packages.parseItemActionEffects(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (fx.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        try self.broadcastExcept("NetPackageItemActionEffects", body[0..fx.wire_len], c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageCloseAllWindows")) {
        // Stock declares this ToClient (`get_PackageDirection` IL=2 returns 2,
        // NetPackageDirection.ToClient) and its ProcessPackage returns
        // immediately when `ConnectionManager.IsServer`: the body is a
        // `_playerIdToClose` the receiving client uses to close its own modal
        // windows. A dedicated server neither receives nor forwards it.
        //
        // zdtd used to relay it to every other peer, which let any client
        // close every other player's open UI. Accept and drop instead: the
        // package is legal to arrive (a client may send it) but has no
        // server-side effect, exactly as stock has none.
        self.harness.counters.inc(.ownership_rejects);
        return true;
    }
    return false;
}
