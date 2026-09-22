//! C2S progression arms: score/XP drop, skill purchase.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_binary = @import("../../wire/binary.zig");

/// True when `name` is a progression package and was handled.
pub fn handleProgress(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageEntityAddScoreServer") or std.mem.eql(u8, name, "NetPackageEntityAddExpServer")) {
        // Client-reported XP/score adds are never applied: the server awards XP
        // itself on the kill and quest paths, so accepting these would let a
        // client mint XP (AGENTS rule 17; docs/DIVERGENCES.md 1.5). Note this
        // is a trust decision, not a missing feature - the skill ledger it once
        // waited on shipped 2026-08-27 and drives the SetSkillLevelServer
        // handler below. Ack silently.
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntitySetSkillLevelServer")) {
        // ADR 0023 ledger: the client requests one skill purchase.
        // NetPackageEntitySetSkillLevelServer derives from
        // ...SetSkillLevelClient and overrides neither read nor write, so it
        // inherits that body verbatim: entityId i32 | skill string | level
        // i32 (NetPackageEntitySetSkillLevelClient.il.txt:37). The leading id
        // is not optional; skipping it read the skill from the wrong offset.
        // Server-validated; echoes the Client package on success.
        var r = wire_binary.Reader{ .data = body };
        var skill_buf: [128]u8 = undefined;
        const req_entity = r.readI32() catch return true;
        if (self.rejectIfNotSender(c, peer.local_id, req_entity, .none)) return true;
        const skill = r.readString(&skill_buf) catch return true;
        const level = r.readI32() catch return true;
        if (skill.len == 0 or level < 1 or level > 255) return true;
        // Wasm-first (AGENTS rule 29, ADR 0033): the on_perk_spend verdict
        // gates/customizes spending on top of the catalog validation - <0
        // denies the spend, 0 keeps, >0 scales the skill-point cost by
        // percent. The stat deltas stay native (the passive-effects VM).
        const cost = self.skillCostOf(c.slot, skill, @intCast(level)) orelse return true;
        const verdict = self.perkSpendVerdict(c.entity_id, skill, level, @intCast(@min(cost, std.math.maxInt(i32))));
        var eff_cost: ?u32 = null;
        if (verdict < 0) return true;
        if (verdict > 0) {
            const scaled: u64 = @as(u64, cost) * @as(u64, @intCast(verdict)) / 100;
            eff_cost = @intCast(@max(1, @min(scaled, std.math.maxInt(u32))));
        }
        if (!self.purchaseSkillAtCost(c.slot, skill, @intCast(level), eff_cost)) return true;
        if (c.entity_id > 0) {
            if (packages.stock_xp.buildEntitySetSkillLevelBody(&self.body_buf, c.entity_id, skill, level)) |sb| {
                self.sendGame(peer, "NetPackageEntitySetSkillLevelClient", sb) catch {};
            } else |_| {}
        }
        return true;
    }
    return false;
}
