//! Guard/evidence helpers extracted from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const evidence_mod = @import("../evidence.zig");
const guard_policy = @import("../guard_policy.zig");
const packages = @import("../../wire/packages.zig");
const wire_binary = @import("../../wire/binary.zig");
const vending_mod = @import("../../world/vending.zig");

pub fn noteEvidence(self: *Game, c: *Client, peer_local: i32, entity_id: i32, det: evidence_mod.Detector, sev: evidence_mod.Severity, surf: evidence_mod.Surface, observed: f32, bound: f32) void {
    if (self.loadShedding() and (sev == .info or sev == .soft)) {
        self.harness.counters.inc(.load_shed_drops);
        return;
    }
    const out = guard_policy.evaluate(&c.guard, self.guard, self.tick_n, det, sev, surf, self.authorityCorrects());
    if (out.record) {
        self.evidence.record(.{ .tick = self.tick_n, .peer_local = peer_local, .entity_id = entity_id, .detector = det, .severity = sev, .surface = surf, .observed = observed, .bound = bound });
        self.harness.counters.inc(.evidence_events);
    }
    switch (out.action) {
        .none => {},
        .quarantine => applyQuarantine(self, c, out.bits, det),
        .would_kick => {
            self.harness.counters.inc(.guard_would_kicks);
            std.debug.print("zdtd: guard would kick slot={d} det={s} surf={s} strong={d} hard={d}\n", .{ c.slot, @tagName(det), @tagName(surf), @popCount(c.guard.strong_mask), c.guard.hard_n });
        },
        .kick => armPolicyKick(self, c, det),
    }
}

pub fn dropClientSlot(self: *Game, slot: usize, reason: []const u8) void {
    std.debug.print("zdtd: player dropped slot={d} entity={d} reason={s}\n", .{ slot, self.clients[slot].entity_id, reason });
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
    self.clients[slot] = .{};
    self.refreshInfoPlayers();
}

pub fn quarantineDenies(self: *Game, c: *Client, surf: evidence_mod.Surface) bool {
    if (!self.authorityCorrects()) return false;
    const q = c.guard.quarantine;
    const denied = switch (surf) {
        .none => false,
        .damage => q.no_damage,
        .container => q.no_container,
        .block => q.no_setblock,
    };
    if (!denied) return false;
    self.harness.counters.inc(.quarantine_rejects);
    const n = self.harness.counters.get(.quarantine_rejects);
    if (n == 1 or n % 100 == 0) {
        std.debug.print("zdtd: quarantine deny n={d} slot={d} surface={s}\n", .{ n, c.slot, @tagName(surf) });
    }
    return true;
}

fn applyQuarantine(self: *Game, c: *Client, bits: guard_policy.Quarantine, det: evidence_mod.Detector) void {
    var changed = false;
    if (bits.no_damage and !c.guard.quarantine.no_damage) {
        c.guard.quarantine.no_damage = true;
        changed = true;
    }
    if (bits.no_container and !c.guard.quarantine.no_container) {
        c.guard.quarantine.no_container = true;
        changed = true;
    }
    if (bits.no_setblock and !c.guard.quarantine.no_setblock) {
        c.guard.quarantine.no_setblock = true;
        changed = true;
    }
    if (!changed) return;
    self.harness.counters.inc(.guard_quarantines);
    std.debug.print("zdtd: guard quarantine slot={d} det={s} damage={} container={} setblock={}\n", .{ c.slot, @tagName(det), c.guard.quarantine.no_damage, c.guard.quarantine.no_container, c.guard.quarantine.no_setblock });
}

pub fn loadShedding(self: *const Game) bool {
    return self.tick_n < self.shed_until_tick;
}

fn armPolicyKick(self: *Game, c: *Client, det: evidence_mod.Detector) void {
    if (c.guard.kick_at_tick != 0) return;
    c.guard.kick_at_tick = self.tick_n + guard_policy.kick_delay_ticks;
    self.harness.counters.inc(.guard_kicks);
    if (c.peer) |p| {
        var denied: [64]u8 = undefined;
        if (packages.buildPlayerDeniedBody(&denied, .mod_decision, 0, 0, "zdtd guard policy")) |body| {
            self.sendGame(p, "NetPackagePlayerDenied", body) catch
                self.harness.counters.inc(.net_send_errors);
        } else |_| self.harness.counters.inc(.encode_errors);
    }
    std.debug.print("zdtd: guard kick armed slot={d} det={s} strong={d} hard={d} drop_tick={d}\n", .{ c.slot, @tagName(det), @popCount(c.guard.strong_mask), c.guard.hard_n, c.guard.kick_at_tick });
}
