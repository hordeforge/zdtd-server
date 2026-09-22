//! C2S validate-and-drop arms: stealth, stat-changed, game-event response.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim). The client
//! reports state zdtd computes server-side; validate the body and drop.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");

/// True when `name` is a validate-and-drop package and was handled.
pub fn handleDrop(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    _ = peer;
    _ = c;
    if (std.mem.eql(u8, name, "NetPackageEntityStealth")) {
        // Stock NetPackageEntityStealth (read IL=9: id i32 | data u16 - the
        // write IL=12 ships the same two fields). The client reports its
        // stealth state for AI detection (crouch/smell/eating/sheltered/
        // alert packed into the u16). zdtd computes stealth server-side (the
        // crouch flag rides the movement frames and the AI senses row
        // derives smell from buffs), so the report is a redundant echo:
        // validate the body and drop.
        if (body.len < 6) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityStatChanged")) {
        // Stock body (read IL=24, GetLength 21): entityId i32 (the
        // NetPackageEntityTargeted base) | instigatorId i32 | enumStat u8 |
        // value f32 | max f32 | maxModifier f32. A remote client reports its
        // own stat change through EntityStats.SendStatChangePacket (IL=65,
        // the world.IsRemote() branch), and stock's ProcessPackage writes the
        // reported value straight onto the entity's Stat.
        //
        // zdtd owns health, stamina, food and water in the sim and
        // replicates them out through the same package (replicate_health,
        // join). Applying the client's number would let a peer set its own
        // health, which is exactly the authority the server keeps (AGENTS
        // rule 17): validate the body and drop.
        if (body.len < 21) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageGameEventResponse")) {
        // Stock body carries a ResponseTypes discriminator plus the event
        // name / target / extra strings (GetLength 30 is the fixed head).
        // Stock's ProcessPackage (IL=135) switches on responseType and calls
        // the matching GameEventManager handler; the one path a stock client
        // reaches SendToServer on is BlockGameEvent.OnBlockDamaged's
        // !IsServer branch (responseType 11), where the server would run
        // SendBlockDamageUpdate(pos) to bump the sequence's "Damaged" event
        // variable.
        //
        // zdtd's game-event support is the request/approve path
        // (NetPackageGameEventRequest -> gameEventVerdict -> the response
        // this server *sends*). It keeps no GameEventActionSequence state,
        // so there is no "Damaged" variable for a client-reported hit to
        // bump, and every other responseType is a client-side handler.
        // Validate the head and drop rather than half-applying one arm.
        if (body.len < 4) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        return true;
    }
    return false;
}
