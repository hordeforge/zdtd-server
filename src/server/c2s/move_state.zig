//! C2S movement arms: alive flags, speeds, teleport, velocity.
//!
//! Split out of c2s/move.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");

fn sprintMagnitude(movement_state: u8, speed_forward: f32, speed_strafe: f32) f32 {
    if (movement_state != 3) return 0;
    return @max(@abs(speed_forward), @abs(speed_strafe));
}

/// True when `name` is an entity-state package and was handled.
pub fn handleState(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageEntityAliveFlags")) {
        const f = packages.parseAliveFlagsBody(body) catch {
            self.harness.counters.inc(.decode_rejects);
            return true;
        };
        if (f.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        if (self.sim.slotOfNetId(f.entity_id)) |idx| {
            // Jump edge first: the stored word is overwritten below, so the
            // previous jump bit must be read before the verbatim store (stock
            // relay mirror).
            const was_jumping = (self.sim.flags[idx].bits & ecs.components.flag_jumping) != 0;
            const was_aiming = (self.sim.flags[idx].bits & ecs.components.flag_aiming_gun) != 0;
            const was_crouching = (self.sim.flags[idx].bits & packages.cF_crouching) != 0;
            // Store the client-reported word verbatim (stock relay mirror).
            // Server-side decisions never read these stored bits: crouch is
            // derived from the package directly below, and the S2C flags word
            // for AI entities is built from sim state in replicate.zig.
            self.sim.flags[idx].bits = f.flags;
            // Stealth (RE entity-ai.md PlayerStealth): the client reports its
            // crouch in this flags word (bit 512); the AI sense gates muffle
            // hearing and shrink sleeper detect for crouched players.
            if (self.sim.mask[idx].player) {
                self.sim.player[idx].crouching = (f.flags & packages.cF_crouching) != 0;
                // Mirror crouch into the `_crouching` cvar the stealth-armor
                // rows gate on (`CVarCompare cvar="_crouching"` on rogue /
                // assassin NoiseMultiplier). Stock sets it client-side and
                // never networks `_` names; the server projects the same value
                // from the reported flags word so the VM fold sees it. Only
                // for the sender's own entity, like the speeds path below.
                if (f.entity_id == c.entity_id) {
                    _ = c.cvars.apply("_crouching", .set, if (self.sim.player[idx].crouching) 1 else 0);
                }
                // Jump edge (stock EntityAlive.set_Jumping IL=46): the client
                // sets the 0x0010 Jumping bit when its move helper starts a
                // jump. Firing the check buffs' `onSelfJump` rows here drives
                // the leg-injury escalation (buffLegGetsWorse, $legHurtCounter)
                // off the same wire signal the client already sends. Grounded
                // by the same rule as crouch: the sender's own entity only.
                const jumping = (f.flags & ecs.components.flag_jumping) != 0;
                if (f.entity_id == c.entity_id and jumping and !was_jumping) {
                    if (self.sim.playerByPeer(c.slot)) |ps| {
                        self.fireJump(ps);
                    }
                }
                // Aim + crouch edges (own entity only, like jump): aim start
                // adds buffHoldBreathAiming01 for `holdBreathAiming` holders,
                // aim stop removes it; crouch set/clear adds/removes
                // buffCrouching (screen-effect rows).
                if (f.entity_id == c.entity_id) {
                    if (self.sim.playerByPeer(c.slot)) |ps| {
                        const aiming = (f.flags & ecs.components.flag_aiming_gun) != 0;
                        if (aiming != was_aiming) self.fireAimEdge(ps, aiming);
                        const crouching = (f.flags & packages.cF_crouching) != 0;
                        if (crouching != was_crouching) self.fireCrouchEdge(ps, crouching);
                    }
                }
            }
        }
        // Fan-out to other peers (stock tracked-players path). Re-encode from
        // the parsed fields rather than relaying the raw body: stock writes
        // exactly i32+u16 and its Process re-Setups from server state, so a
        // peer that appends trailing bytes must not have them forwarded.
        var flags_buf: [8]u8 = undefined;
        const flags_body = packages.buildAliveFlagsBody(&flags_buf, f.entity_id, f.flags) catch {
            self.harness.counters.inc(.encode_errors);
            return true;
        };
        try self.broadcastExcept("NetPackageEntityAliveFlags", flags_body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntitySpeeds")) {
        const s = packages.parseEntitySpeedsBody(body) catch {
            self.harness.counters.inc(.decode_rejects);
            return true;
        };
        if (s.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        // Sprint state for the stamina drain (MovementState 3 = sprint/aggro,
        // entity-ai.md SetMovementState); lapses on a stale timer. The same
        // report carries the movement tag `EntityHasMovementTag` gates read
        // (stock sets `CurrentMovementTag` from the move direction plus
        // `bMovementRunning`, and `SetMovementState` derives its state from the
        // same speeds).
        c.sprint_speed = sprintMagnitude(s.movement_state, s.speed_forward, s.speed_strafe);
        c.move_tag = Client.MoveTag.fromMovementState(s.movement_state);
        c.sprint_stale_cd = self.sim.rules.progression.sprint_stale_seconds;
        // Re-encode rather than relay: stock's body is exactly 13 bytes, and
        // the parser only requires a minimum, so a raw relay would forward a
        // peer's trailing bytes to everyone.
        var speeds_buf: [16]u8 = undefined;
        const speeds_body = packages.buildEntitySpeedsBody(
            &speeds_buf,
            s.entity_id,
            s.movement_state,
            s.speed_forward,
            s.speed_strafe,
        ) catch {
            self.harness.counters.inc(.encode_errors);
            return true;
        };
        try self.broadcastExcept("NetPackageEntitySpeeds", speeds_body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityTeleport")) {
        const p = packages.parsePosAndRotBody(body) catch {
            self.harness.counters.inc(.decode_rejects);
            return true;
        };
        if (p.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        // Same speed envelope as PosAndRot: without it a client teleports
        // anywhere and noteAcceptedMove rebaselines the gate to that spot.
        const env = self.applyMovementEnvelope(c, peer, p.entity_id, p.x, p.y, p.z);
        if (!env.applied) return true;
        // Void rescue: same T22 suppression as the PosAndRot path - reset the
        // envelope so the fall-out correction never counts as a reject.
        if (try self.rescueDeepVoid(peer, p.entity_id, env.x, env.y, env.z, false)) |ny| {
            // Snapped; do not fan-out void coords.
            self.resetMoveEnvelopePeer(c.slot, env.x, ny, env.z);
            return true;
        }
        var yaw: f32 = 0;
        if (self.sim.slotOfNetId(p.entity_id)) |si| yaw = self.sim.transform[si].yaw;
        self.sim.setPos(p.entity_id, env.x, env.y, env.z, yaw);
        self.noteAcceptedMove(c, env.x, env.y, env.z);
        // Clamped: the owner already got a correction; peers pick the true
        // position up on the next motion pass rather than the raw claim. The
        // gate checks all three axes: a Y-only clamp (fly attempt) must not
        // relay the raw teleport Y to peers either.
        if (env.x == p.x and env.y == p.y and env.z == p.z) {
            // Trim to the parsed body: the length is variable and anything a
            // peer appends past it must not be relayed.
            try self.broadcastExcept("NetPackageEntityTeleport", body[0..p.wire_len], c.slot);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityAddVelocity")) {
        if (body.len >= 4) {
            const eid = std.mem.readInt(i32, body[0..4], .little);
            if (eid != c.entity_id) return true;
            if (self.sim.slotOfNetId(eid)) |si| {
                self.sim.markDirty(si, .{ .pos = true });
            }
        }
        return true;
    }
    return false;
}

test "sprint magnitude covers backward and strafe movement" {
    try std.testing.expectEqual(@as(f32, 4), sprintMagnitude(3, -4, 0));
    try std.testing.expectEqual(@as(f32, 3), sprintMagnitude(3, 0, -3));
    try std.testing.expectEqual(@as(f32, 0), sprintMagnitude(2, 6, 6));
}
