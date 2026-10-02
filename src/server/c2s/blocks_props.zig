//! C2S `NetPackageSetProp`: a client's world prop edit.
//!
//! Stock `GameManager.ChangeProps` (RE world-chunks.md 925-945) requires the
//! chunk for every change and abandons the whole batch on a miss, then
//! `SetPropsOnClients` fans the same package out on channel 192, excluding the
//! changer. zdtd stores the resulting tuple per (chunk, prop id) and relays the
//! untouched body, so another player sees the edit live. Still missing: the
//! chunk-stream leg (a late joiner does not get props placed before it arrived)
//! and persistence.
const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");

/// Max changes honoured in one package. Stock's list is unbounded on the wire;
/// zdtd caps it and refuses a longer body rather than allocating (rule 20).
pub const max_changes_per_package = 64;

pub fn handle(
    self: *Game,
    c: *Client,
    peer: *ln_peer.Peer,
    name: []const u8,
    body: []const u8,
) anyerror!bool {
    if (!std.mem.eql(u8, name, "NetPackageSetProp")) return false;
    _ = peer;
    var plat_buf: [64]u8 = undefined;
    var id_buf: [64]u8 = undefined;
    var changes: [max_changes_per_package]packages.PropChange = undefined;
    const parsed = packages.parseSetPropBody(body, &plat_buf, &id_buf, &changes) catch {
        self.harness.counters.inc(.c2s_malformed);
        return true;
    };
    // `NetPackageSetProp::ProcessPackage` IL_0002-001E validates the claimed
    // identity before anything else: the persistent player id must be the
    // sender's (ValidUserIdForSender) and the changer entity id must be one the
    // sender owns (ValidEntityIdForSender). Both drop the package silently.
    const ps = self.sim.playerByPeer(c.slot) orelse return true;
    if (parsed.local_player_that_changed != self.sim.network_id[ps].id) {
        self.harness.counters.inc(.ownership_rejects);
        return true;
    }
    if (parsed.persistent_player) |sent| {
        if (!c.puid_primary.matches(sent) and !c.puid_native.matches(sent)) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
    } else if (c.puid_primary.get() != null or c.puid_native.get() != null) {
        self.harness.counters.inc(.ownership_rejects);
        return true;
    }

    // Stock requires the chunk for every change and drops the batch on a miss.
    for (parsed.changes) |ch| {
        if (self.world.chunkAt(.{ .x = ch.chunk_x, .z = ch.chunk_y }) == null) return true;
    }
    for (parsed.changes) |ch| {
        if (self.world.props.apply(
            ch.chunk_x,
            ch.chunk_y,
            ch.prop_id,
            ch.position,
            ch.rotation,
            ch.scale,
            ch.block_raw,
            ch.block_damage,
        ) == null) {
            // Store full: count the drop and stop, leaving the applied prefix.
            self.harness.counters.inc(.c2s_rejects);
            break;
        }
    }
    // Channel-192 fan-out, excluding the changer (it already applied locally).
    self.broadcastExcept("NetPackageSetProp", body, c.slot) catch |err| {
        self.harness.counters.inc(.net_send_errors);
        return err;
    };
    return true;
}
