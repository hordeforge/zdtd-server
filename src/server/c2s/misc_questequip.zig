//! C2S quest/equipment arms: quest positions drop, equipment apply+relay.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const inv_apply = @import("../inv_apply.zig");
const reverseItemType = game_mod.Game.reverseItemType;
const relayBodyExcept = @import("misc_relay.zig").relayBodyExcept;

/// True when `name` is a quest/equipment package and was handled.
pub fn handleQuestEquip(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    _ = peer;
    if (std.mem.eql(u8, name, "NetPackagePlayerQuestPositions")) {
        // Stock C2S ProcessPackage IL=24 (research protocol-packages.md
        // 6.21.2): sender-own-id gate (ValidEntityIdForSender(entityId,
        // allowSelf=false)), then PersistentPlayerData.QuestPositions.Clear()
        // + AddRange(client's QuestPositionData list). The list is a
        // PPD-persisted quest map-marker cache (binary Write/Read + XML
        // Write/ReadXML) re-broadcast S2C via Setup(entityId, ppd) for client
        // map rendering; no server sim behavior reads it. Accepting+storing
        // would be a dead store with zero consumers, so it is dropped as a
        // documented low-value cache (YAGNI; missing beats fake).
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePlayerEquipment")) {
        // Stock NetPackagePlayerEquipment (write: entityId i32 + Equipment
        // body; ProcessPackage IL=56: Equipment.Apply + rebroadcast flags 192
        // excluding the sender). The client sends it whenever
        // bPlayerEquipmentChanged flips (an armor swap): the server applies
        // the equipment to the sim's equip slots (the armor mitigation reads
        // them) and relays the raw body to the other tracked players so they
        // render the swapped armor.
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        if (body.len < 4) return true;
        const eid = std.mem.readInt(i32, body[0..4], .little);
        // Stock ValidEntityIdForSender: the equipment is the sender's own.
        if (eid != c.entity_id) return true;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].inventory) return true;
        const eq_len = inv_apply.applyEquipmentBody(body[4..], &self.sim.inventory[ps], reverseItemType, self) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        // Trim to the parsed body: Equipment is variable length (the version
        // byte picks the slot count and each slot is either one `0` or a full
        // ItemValue), so a raw relay would forward appended bytes.
        relayBodyExcept(self, "NetPackagePlayerEquipment", body[0 .. 4 + eq_len], eid, "PlayerEquipment");
        return true;
    }
    return false;
}
