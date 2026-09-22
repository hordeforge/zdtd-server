//! C2S session arms: PlayerData validate, PlayerDisconnect quit path.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const reverseItemType = game_mod.Game.reverseItemType;
const logPersistErr = game_mod.logPersistErr;

/// True when `name` is a session package and was handled.
pub fn handleSession(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackagePlayerData")) {
        const ps = self.sim.playerByPeer(c.slot);
        if (ps) |slot| {
            if (self.sim.mask[slot].inventory) {
                if (packages.stock_inv.applyPlayerDataNetwork(body, &self.sim.inventory[slot], reverseItemType, self)) |h| {
                    self.clampInventoryStacks(&self.sim.inventory[slot]);
                    // Entity ids are minted by sim.spawnPlayer; a mismatch is
                    // a client claiming someone else's body, never adoption.
                    // Do NOT apply ECD pos either: client PDF pos is
                    // Unity-origin relative after Origin Reposition (y=0
                    // artifacts); PosAndRot is the world-space source of truth.
                    // Success path is silent (periodic PDF is normal). Mismatch
                    // is the operator-visible signal: counter + rate-limited log.
                    if (h.entity_id != c.entity_id) {
                        self.harness.counters.inc(.ownership_rejects);
                        const n = self.harness.counters.get(.ownership_rejects);
                        if (n == 1 or n % 100 == 0) {
                            std.debug.print(
                                "zdtd: PlayerData ownership reject n={d} claimed={d} expected={d} local_id={d}\n",
                                .{ n, h.entity_id, c.entity_id, peer.local_id },
                            );
                        }
                    }
                } else |_| {
                    // Fall back to ECD head only. Parse-skip is rare; log once per 100
                    // decode rejects so a broken client is visible without per-packet noise.
                    // Parsed for validation only: the ECD head proves the body
                    // is a well-formed PlayerData write, and the save itself
                    // comes from server state.
                    if (packages.parsePlayerDataEcdHead(body)) |_| {} else |_| {
                        self.harness.counters.inc(.decode_rejects);
                        const n = self.harness.counters.get(.decode_rejects);
                        if (n == 1 or n % 100 == 0) {
                            std.debug.print(
                                "zdtd: PlayerData parse skip n={d} body_len={d} local_id={d}\n",
                                .{ n, body.len, peer.local_id },
                            );
                        }
                    }
                }
            }
        } else if (packages.parsePlayerDataEcdHead(body)) |_| {} else |_| {}
        // Defer file write to the periodic save tick (no open/rewrite per packet).
        self.players_dirty = true;
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePlayerDisconnect")) {
        // Stock quit signal (extends PlayerData: entity id, protocol-packages.md
        // NetPackagePlayerDisconnect).
        // Take the same removal path as the transport peer-death poll, but
        // immediately and after saving, so a quit is never lost to the
        // autosave interval. Accept only the sender's own entity.
        if (body.len >= 4) {
            const eid = std.mem.readInt(i32, body[0..4], .little);
            if (eid != c.entity_id) return true;
        }
        self.savePlayers() catch |e| logPersistErr(self, "save players", e);
        self.dropClientSlot(c.slot, "quit");
        return true;
    }
    return false;
}
