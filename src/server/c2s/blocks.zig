//! Block editing: SetBlock, BlockTrigger, Explosions.
//! Extracted from the old c2s/inv.zig tail (643-991) verbatim.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const platform_user = packages.platform_user;
const ecs = @import("../../ecs/root.zig");
const blocks_trigger = @import("blocks_trigger.zig");
const blocks_pickup = @import("blocks_pickup.zig");
const blocks_setblock = @import("blocks_setblock.zig");
const blocks_explosion = @import("blocks_explosion.zig");
const blocks_fx = @import("blocks_fx.zig");

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
    if (try blocks_fx.handleFx(self, c, peer, name, body)) return true;
    return false;
}
