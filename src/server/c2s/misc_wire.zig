//! C2S wire arms: block wire actions, wire-tool parent ops.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");

/// Highest `WireActions` value NetPackageWireToolActions::ProcessPackage
/// (IL=254) acts on: the switch takes 0 (SetParent) and 1 (RemoveParent) and
/// returns for anything else, so a higher op never reaches its rebroadcast.
pub const wire_tool_max_op: u8 = 1;

/// True when `name` is a wire package and was handled.
pub fn handleWire(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    _ = peer;
    if (std.mem.eql(u8, name, "NetPackageWireActions")) {
        // Same rate gate as SetBlock: unthrottled would let a spam loop fan
        // this broadcast out to every other peer for free (bandwidth DoS).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Stock parent/child wiring (SetParent/RemoveParent) drives powered state.
        _ = self.sim.power.applyWireActionsStock(body);
        // Rebroadcast raw package so peers get the client-side wire visual.
        try self.broadcastExcept("NetPackageWireActions", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageWireToolActions")) {
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Tool handshake carries one endpoint + player: visual only, no graph
        // mutation (mirrors stock ProcessPackage re-Setup+SendPackage to peers).
        // read IL=13: currentOperation u8 | tileEntityPosition Vector3i |
        // entityID i32. ProcessPackage IL=254 opens with
        // ValidEntityIdForSender(entityID, false) and returns on failure, so a
        // body naming another player is dropped, not relayed. It also returns
        // for any operation outside {0,1} before reaching either SendPackage.
        const tool = packages.parseWireToolActions(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (tool.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        if (tool.operation > wire_tool_max_op) return true;
        try self.broadcastExcept("NetPackageWireToolActions", body, c.slot);
        return true;
    }
    return false;
}
