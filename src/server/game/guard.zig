//! Guard/evidence helpers extracted from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const evidence_mod = @import("../evidence.zig");
const guard_policy = @import("../guard_policy.zig");
const packages = @import("../../wire/packages.zig");

/// One edit-range policy: reach check, bounds counter, and evidence record.
/// True means the action is out of range and the caller must drop it.
pub fn rejectIfBeyondEditRange(
    self: *Game,
    c: *Client,
    peer_local: i32,
    entity_id: i32,
    surf: evidence_mod.Surface,
    px: f32,
    py: f32,
    pz: f32,
    bx: f32,
    by: f32,
    bz: f32,
) bool {
    const dx = px - bx;
    const dy = py - by;
    const dz = pz - bz;
    const d2 = dx * dx + dy * dy + dz * dz;
    if (d2 <= self.max_edit_range * self.max_edit_range) return false;
    self.harness.counters.inc(.bounds_rejects);
    noteEvidence(self, c, peer_local, entity_id, .bounds, .strong, surf, @sqrt(d2), self.max_edit_range);
    return true;
}

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

pub fn quarantineDenies(self: *Game, c: *Client, surf: evidence_mod.Surface) bool {
    if (!self.authorityCorrects()) return false;
    const q = c.guard.quarantine;
    const denied = switch (surf) {
        .none => false,
        .damage => q.damage,
        .container => q.container,
        .block => q.setblock,
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
    if (bits.damage and !c.guard.quarantine.damage) {
        c.guard.quarantine.damage = true;
        changed = true;
    }
    if (bits.container and !c.guard.quarantine.container) {
        c.guard.quarantine.container = true;
        changed = true;
    }
    if (bits.setblock and !c.guard.quarantine.setblock) {
        c.guard.quarantine.setblock = true;
        changed = true;
    }
    if (!changed) return;
    self.harness.counters.inc(.guard_quarantines);
    std.debug.print("zdtd: guard quarantine slot={d} det={s} damage={} container={} setblock={}\n", .{ c.slot, @tagName(det), c.guard.quarantine.damage, c.guard.quarantine.container, c.guard.quarantine.setblock });
}

pub fn loadShedding(self: *const Game) bool {
    return self.tick_n < self.shed_until_tick;
}

fn armPolicyKick(self: *Game, c: *Client, det: evidence_mod.Detector) void {
    if (c.guard.kick_at_tick != 0) return;
    c.guard.kick_at_tick = self.tick_n + self.guard.kick_delay_ticks;
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
