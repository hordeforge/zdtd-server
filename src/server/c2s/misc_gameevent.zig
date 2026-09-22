//! C2S game-event arm: request validate, verdict, sequence run.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_binary = @import("../../wire/binary.zig");

/// True when `name` is a game-event package and was handled.
pub fn handleGameEvent(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageGameEventRequest")) {
        // Stock ProcessPackage IL=211 (research protocol-packages.md 6.21.2):
        // sender player + party-target validation, then
        // GameEventManager.HandleAction; a response is sent only when the
        // action runs. Request wire (write IL=83): eventName str | entityID
        // i32 | extraData str | tag str | isTwitchEvent bool | crateShare
        // bool | allowRefunds bool | sequenceLink str | variables u8 (cap
        // 255) x (name str, value str) | ActionTarget. Execution policy is
        // plugin-owned (ADR 0035, wasm-first): the on_game_event verdict <0
        // denies the event (no response), 0 keeps the stock APPROVED ack, >0
        // keeps it too. The gameevents.xml phase-machine engine is not faked
        // natively (dormant surface: zero stock data uses GameEvent actions;
        // missing beats fake).
        var r = wire_binary.Reader{ .data = body };
        var ev_buf: [256]u8 = undefined;
        const event_name = r.readString(&ev_buf) catch return true;
        const target_eid = r.readI32() catch return true;
        // IL=211 gate: a target that is another player must be a party
        // member; non-player entities and unknown ids pass (stock gates only
        // on EntityPlayer targets via GetEntity). Rejected targets are
        // silently dropped (no response).
        if (target_eid != 0 and target_eid != c.entity_id) {
            if (self.clientByEntityId(target_eid)) |_| {
                var in_party = false;
                if (self.parties.partyByMember(c.entity_id)) |party| {
                    for (party.members[0..party.n]) |m| {
                        if (m == target_eid) {
                            in_party = true;
                            break;
                        }
                    }
                }
                if (!in_party) return true;
            }
        }
        // Walk to the variables count (u8, capped 255 by the writer) for the
        // verdict; a truncated tail keeps the ack path (stock read would
        // drop the connection instead; we fail closed per package).
        var extra_buf: [256]u8 = undefined;
        var tag_buf: [256]u8 = undefined;
        var seq_buf: [256]u8 = undefined;
        _ = r.readString(&extra_buf) catch 0;
        _ = r.readString(&tag_buf) catch 0;
        _ = r.readBool() catch false; // isTwitchEvent
        _ = r.readBool() catch false; // crateShare
        _ = r.readBool() catch false; // allowRefunds
        _ = r.readString(&seq_buf) catch "";
        const var_count = r.readByte() catch 0;
        if (self.gameEventVerdict(c.entity_id, event_name, target_eid, @intCast(var_count)) < 0) return true;
        // A supported sequence runs server side. Stock's client only forwards
        // the request (GameEventManager::HandleActionClient IL=416 sends
        // NetPackageGameEventRequest and returns), so this is where the respawn
        // family's stat restore and buff changes happen. Names that are not
        // parsed sequences - quest, trader and challenge events included - stay
        // ack-only.
        _ = self.runGameEventSequence(c.slot, event_name);
        if (packages.buildGameEventResponse(&self.body_buf, body)) |resp| {
            self.sendGame(peer, "NetPackageGameEventResponse", resp) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                std.debug.print(
                    "zdtd: GameEventResponse send failed slot={d}: {s}\n",
                    .{ c.slot, @errorName(err) },
                );
            };
        } else |err| {
            self.harness.counters.inc(.encode_errors);
            std.debug.print(
                "zdtd: GameEventResponse encode failed slot={d}: {s}\n",
                .{ c.slot, @errorName(err) },
            );
        }
        return true;
    }
    return false;
}
