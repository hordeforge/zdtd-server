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
const stock_inv = @import("../../wire/stock_inv.zig");
const binary = @import("../../wire/binary.zig");

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
        // b18 body (protocol-packages.md §1.5.5): `entityId i32 | blobLen i32 |
        // blob(Equipment.Write)`. The blob frames the equipment record so a
        // raw relay can trim exactly to it.
        if (body.len < 8) return true;
        const eid = std.mem.readInt(i32, body[0..4], .little);
        // Stock ValidEntityIdForSender: the equipment is the sender's own.
        if (eid != c.entity_id) return true;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].inventory) return true;
        var br: binary.Reader = .{ .data = body[4..] };
        var blob_buf: [2048]u8 = undefined;
        const blob_n = stock_inv.readBlob(&br, blob_buf[0..]) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        // The blob body is authoritative: it frames the equipment, so the relay
        // trims to exactly entityId | blobLen | blob and appended bytes cannot
        // ride along.
        _ = inv_apply.applyEquipmentBody(blob_buf[0..blob_n], &self.sim.inventory[ps], reverseItemType, self) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        relayBodyExcept(self, "NetPackagePlayerEquipment", body[0 .. 8 + blob_n], eid, "PlayerEquipment");
        return true;
    }
    return false;
}
