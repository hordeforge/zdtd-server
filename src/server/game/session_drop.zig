//! Client slot teardown extracted from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const wire_binary = @import("../../wire/binary.zig");
const packages = @import("../../wire/packages.zig");

pub fn dropClientSlot(self: *Game, slot: usize, reason: []const u8) void {
    std.debug.print("zdtd: player dropped slot={d} entity={d} reason={s}\n", .{ slot, self.clients[slot].entity_id, reason });
    // Wasm-first (AGENTS rule 29): a joined player's disconnect is an event
    // for plugins (announcements/observers), not native behavior. Mirrors the
    // on_player_join notification; pre-join drops have no entity to report.
    if (self.clients[slot].joined and self.clients[slot].entity_id > 0) {
        self.plugins.playerLeave(@intCast(slot), self.clients[slot].entity_id);
        self.wasm_plugins.playerLeave(@intCast(slot), self.clients[slot].entity_id);
    }
    if (self.clients[slot].peer) |p| p.alive = false;
    self.unseatRider(self.clients[slot].entity_id) catch |err| {
        std.debug.print("zdtd: unseat on drop failed entity={d}: {s}\n", .{ self.clients[slot].entity_id, @errorName(err) });
    };
    self.clearLocksForPeer(slot);
    self.markClaimsForEntity(self.clients[slot].entity_id, false);
    if (self.parties.removePlayer(self.clients[slot].entity_id)) |r| {
        self.broadcastPartyRemoval(r, @intFromEnum(packages.stock_party.PartyActions.disconnected)) catch |err| {
            std.debug.print("zdtd: party disconnect broadcast failed: {s}\n", .{@errorName(err)});
        };
    }
    if (self.sim.playerByPeer(slot)) |ps| {
        if (self.sim.mask[ps].journal) {
            var rb: [16]u8 = undefined;
            for (self.sim.journal[ps].slots) |s| {
                if (!s.active or !s.is_shared) continue;
                var w = wire_binary.Writer{ .buf = &rb };
                w.writeI32(self.clients[slot].entity_id) catch continue;
                w.writeByte(@intFromEnum(packages.stock_quest.SharedQuestEvent.remove_quest)) catch continue;
                w.writeI32(s.quest_code) catch continue;
                const rbody = w.written();
                for (&self.clients) |*cl| {
                    if (!cl.joined or cl.entity_id == self.clients[slot].entity_id) continue;
                    if (cl.peer) |mp| {
                        self.sendGame(mp, "NetPackageSharedQuest", rbody) catch {};
                    }
                }
            }
        }
    }
    if (self.sim.playerByPeer(slot)) |ps| {
        const nid = self.sim.network_id[ps].id;
        if (nid > 0) {
            var rb: [16]u8 = undefined;
            const rm_body: ?[]const u8 = packages.buildRemoveBodyReason(&rb, nid, .despawned) catch null;
            if (rm_body) |rm| {
                for (&self.clients) |*cl| {
                    if (!cl.joined or cl.peer == null or cl.entity_id == nid) continue;
                    if (cl.peer) |p| self.sendGame(p, "NetPackageEntityRemove", rm) catch {};
                    cl.known_entities.unset(ps);
                }
            }
        }
    }
    // The player entity is now gone from every client's view; destroy the sim
    // entity so the slot frees and no ghost player lingers (a phantom in
    // listents/mem counts and a spawn-on-approach candidate for late joiners).
    // The next spawn on this peer slot reaps anyway (world.zig:1241), but
    // dropping the ghost now keeps counts and replication honest between
    // joins. Death observers have no subscribers, so no kill semantics leak.
    if (self.sim.playerByPeer(slot)) |ps| {
        self.sim.destroy(ps);
    }
    self.clients[slot] = .{};
    self.refreshInfoPlayers();
}
