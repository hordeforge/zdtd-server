//! C2S verbatim relays: GameMessage, SoundAtPosition, ParticleEffect.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");

pub fn relayBodyAll(self: *Game, pkg: []const u8, body: []const u8, label: []const u8) void {
    relayBodyExcept(self, pkg, body, null, label);
}

/// Relay `body` verbatim to every joined client except `except_entity_id`'s
/// client (stock allButAttachedToEntityId fan-out); null relays to all.
pub fn relayBodyExcept(self: *Game, pkg: []const u8, body: []const u8, except_entity_id: ?i32, label: []const u8) void {
    for (&self.clients) |*cl| {
        if (!cl.joined or cl.peer == null) continue;
        if (except_entity_id) |eid| {
            if (cl.entity_id == eid) continue;
        }
        self.sendGame(cl.peer.?, pkg, body) catch |err| {
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
