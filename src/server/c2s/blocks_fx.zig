//! C2S block arms: item-action FX relay, close-windows drop.
//!
//! Split out of c2s/blocks.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");

/// True when `name` is an FX package and was handled.
pub fn handleFx(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
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
        if (self.rejectIfNotSender(c, peer.local_id, fx.entity_id, .none)) return true;
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
