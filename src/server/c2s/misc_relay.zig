//! C2S verbatim relays: GameMessage, SoundAtPosition, ParticleEffect.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");

/// Exact stock NetPackageEntityPhysics body size: Flags u16 | EntityId i32 |
/// 13xf32. `GetLength` (IL=2) returns 58, matching the read (IL=74).
const entity_physics_body_len: usize = 58;

pub fn relayBodyAll(self: *Game, pkg: []const u8, body: []const u8, label: []const u8) void {
    relayBodyExcept(self, pkg, body, null, label);
}

/// Relay `body` verbatim to every joined client except `except_entity_id`'s
/// client (stock allButAttachedToEntityId fan-out); null relays to all.
pub fn relayBodyExcept(self: *Game, pkg: []const u8, body: []const u8, except_entity_id: ?i32, label: []const u8) void {
    for (&self.clients) |*cl| {
        if (!cl.joined) continue;
        const peer = cl.peer orelse continue;
        if (except_entity_id) |eid| {
            if (cl.entity_id == eid) continue;
        }
        self.sendGame(peer, pkg, body) catch |err| {
            self.harness.counters.inc(.net_send_errors);
            std.debug.print("zdtd: send {s} failed: {s}\n", .{ label, @errorName(err) });
        };
    }
}

/// True when `name` is a verbatim-relay package and was handled.
pub fn handleRelay(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageGameMessage")) {
        // Stock NetPackageGameMessage (write IL=17): msgType u8
        // (EnumGameMessages PlainTextLocal=0/EntityWasKilled=1/JoinedGame=2/
        // LeftGame=3/ChangedTeam=4/Chat=5), mainEntityId i32,
        // secondaryEntityId i32. GameManager.GameMessageServer ->
        // FinishGameMessageServer (IL=69) re-broadcasts the Setup body to
        // every client with an unfiltered SendPackage, and the remote
        // client's ProcessPackage displays it (DisplayGameMessage), so the
        // sender receives its own message back too. The verbatim relay is
        // byte-identical to the stock rebuild; the client sends these for
        // EntityAlive.OnEntityDeath (isGameMessageOnDeath), team changes and
        // disconnect (LeftGame), and chat-form announcements.
        // Same rate gate as the other verbatim relays (SoundAtPosition): an
        // unthrottled spam loop would fan the raw body out to every peer for
        // free. The stock client sends these on death/team-change/disconnect,
        // all infrequent, so the inv bucket never starves legit traffic.
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        if (body.len < 9) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        relayBodyAll(self, "NetPackageGameMessage", body, "GameMessage");
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageSoundAtPosition")) {
        // Positional-audio relay (RE NetPackageSoundAtPosition write IL=25 /
        // read IL=21: pos 3xf32 | clip string | mode u8 | distance i32 |
        // entityId i32; volumeScale is Setup-only, never on the wire).
        // GameManager.PlaySoundAtPositionServer (IL=60, dedicated branch)
        // re-broadcasts the Setup body with allButAttachedToEntityId =
        // entityId, so every client except the owning player hears the sound
        // (the owner already played it locally); the distance field drives
        // the receiving client's rolloff, not the fan-out. Verbatim relay
        // excludes that entity's client, like stock. Same rate gate as
        // SetBlock: an unthrottled spam loop would fan a broadcast out to
        // every other peer for free.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const snd = packages.parseSoundAtPosition(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        // The owning entity must be the sender (a spoofed id would silence a
        // different player instead of the sender); NaN positions are forged.
        if (self.rejectIfNotSender(c, peer.local_id, snd.entity_id, .none)) return true;
        if (!std.math.isFinite(snd.pos[0]) or !std.math.isFinite(snd.pos[1]) or !std.math.isFinite(snd.pos[2])) {
            self.harness.counters.inc(.bounds_rejects);
            return true;
        }
        relayBodyExcept(self, "NetPackageSoundAtPosition", body[0..snd.wire_len], snd.entity_id, "SoundAtPosition");
        // No AI-noise leg here: on a dedicated server the relay is audio-only.
        // NetPackageSoundAtPosition.ProcessPackage -> PlaySoundAtPositionServer
        // skips AIDirector.NotifyNoise when IsDedicatedServer (RE protocol
        // doc 5.9, IL dump): the stock dedi only evaluates noise for sounds it
        // plays itself (explosions, mines, animals, minibike via
        // Audio.Manager.SignalAI / GameManager.explode). The movement-noise
        // model (sounds.xml table + PlayerStealth fold, systems.systemStealth)
        // consumes sim-side pushStealthNoise as those sources land.
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageParticleEffect")) {
        // Stock NetPackageParticleEffect (write IL=20): ParticleEffect.Write
        // (ParticleId, pos, rot, color32, two sound strings, volumeScale)
        // then entityThatCausedIt i32, forceCreation bool, worldSpawn bool.
        // GameManager.SpawnParticleEffectServer (IL=41, dedicated branch)
        // re-broadcasts the Setup body with allButAttachedToEntityId =
        // entityThatCausedIt, so every client except the causing entity's
        // owner sees the effect (the owner already spawned it locally).
        // Verbatim relay excludes that entity's client, like stock.
        // Same rate gate as SoundAtPosition (also a cosmetic relay): an
        // unthrottled spam loop would fan the raw body out to every other
        // peer for free.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const pe = packages.parseParticleEffectInvoke(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        relayBodyExcept(self, "NetPackageParticleEffect", body[0..pe.wire_len], pe.entity_caused, "ParticleEffect");
        return true;
    }
    return false;
}

/// True when `name` is an avatar-state relay package and was handled.
pub fn handleAvatar(self: *Game, c: *Client, _peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    _ = _peer;
    if (std.mem.eql(u8, name, "NetPackageEntityPhysics")) {
        // Stock NetPackageEntityPhysics (read IL=74, GetLength IL=2 = 58):
        // Flags u16, EntityId i32, then 13xf32 (pos 3, quat 4, velocity 3,
        // angular 3) = 58 bytes. The entity's physics master reports
        // pos/rot/velocity so the server mirrors it (ProcessPackage IL=87
        // gates on isPhysicsMaster). zdtd's movement, falling-block and
        // vehicle sims are server-authoritative (broadcast PosAndRot /
        // VehiclePositions / EntityVelocity), so the report is a redundant
        // echo (DIVERGENCES.md 1.4): validate the body and drop. The gate was
        // 62, so every valid 58-byte report was counted c2s_malformed.
        if (body.len < entity_physics_body_len) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityRagdoll")) {
        // Stock NetPackageEntityRagdoll (write IL=59): entityId i32, flags
        // u8, then conditionally (flags&1) duration/bodyPart/three vectors,
        // (flags&2) mode, (flags&4) state. The owner's client forces the
        // local ragdoll (EntityBuffs buff trigger / EModelBase.DoRagdoll);
        // the server re-broadcasts to the entity's tracked players
        // (SendPacketToTrackedPlayersAndTrackedEntity), so a verbatim relay
        // to the other clients matches stock - the owner already ragdolled.
        const rg = packages.parseRagdollInvoke(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        // Owner already ragdolled (SendPacketToTrackedPlayersAndTrackedEntity).
        // Same rate gate as the other cosmetic relays (SoundAtPosition /
        // ParticleEffect): an unthrottled spam loop would fan the raw body
        // out to every other peer for free.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Trim to the parsed body: the flag-gated tails make the length
        // variable, so a raw relay would forward bytes a peer appended.
        relayBodyExcept(self, "NetPackageEntityRagdoll", body[0..rg.wire_len], rg.entity_id, "EntityRagdoll");
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePlayerLaserSight")) {
        // Stock ProcessPackage (IL=70): on the server the body is re-sent to
        // every client except the sender's own entity, so a player sees a
        // mate's laser dot. Pure relay, no server state.
        const ls = packages.parseLaserSight(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        // Only speak for your own entity: without this a peer could paint a
        // dot on anyone. Stock leans on the sender's ClientInfo for the
        // exclusion; zdtd checks the claimed id directly.
        if (ls.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        // Same rate gate as the other cosmetic relays: the client sends on
        // aim changes, so an unthrottled loop would fan out for free.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        relayBodyExcept(self, "NetPackagePlayerLaserSight", body[0..ls.wire_len], ls.entity_id, "PlayerLaserSight");
        return true;
    }
    return false;
}
