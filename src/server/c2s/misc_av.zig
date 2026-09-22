//! C2S audio + map arms: positional-audio relay, minimap drive.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");

/// True when `name` is an audio/map package and was handled.
pub fn handleAv(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageAudio")) {
        // Not a client-local cue. A client's Audio.Manager::BroadcastPlay
        // falls through to SendToServer when it holds no ServerAudio
        // (Audio/Manager.il.txt:758-790), and the dedicated server's
        // ProcessPackage routes into Audio.Server::Play, which relays a fresh
        // package to every in-range player (Audio/Server.il.txt:13-83 via
        // Audio.Client::Play at Client.il.txt:16). Doors, storage, switches
        // and locks all reach it (59 BroadcastPlay call sites), so dropping
        // it left every other player in silence.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        var name_buf: [128]u8 = undefined;
        const a = packages.parseAudioPlay(body, &name_buf) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (a.sound_group.len == 0) return true; // stock's IsNullOrEmpty early out
        if (a.play_on_entity and self.rejectIfNotSender(c, peer.local_id, a.entity_id, .none)) return true;
        // AI noise. Stock's package routes the play through Audio.Server::Play
        // (NetPackageAudio.il.txt IL_0074), whose first act is
        // Audio.Manager::SignalAI: it returns unless the instigator is an
        // EntityPlayer (Manager.il.txt IL=4696) and only the entity form
        // reaches it (the position form passes a null entity), so a player's
        // own sound - footsteps, gunfire, doors - folds through sounds.xml into
        // that player's stealth and heat state. `signalOnly` suppresses the
        // client relay below, never this leg: it is the "AI stimulus, do not
        // play" flag, so the old "signalOnly -> drop" path lost exactly the
        // noises the AI model is built on.
        if (a.play and a.play_on_entity) {
            if (self.sim.slotOfNetId(a.entity_id)) |is_| {
                if (self.sim.mask[is_].player and self.sim.mask[is_].transform) {
                    if (self.noise_table.getClip(a.sound_group)) |n| {
                        const t = self.sim.transform[is_];
                        self.sim.pushStealthNoise(
                            is_,
                            t.x,
                            t.y,
                            t.z,
                            n.volume * @min(@max(a.volume_scale, 0), self.max_claimed_noise_scale),
                            @trunc(n.time * 20.0),
                            n.muffled_when_crouched,
                            n.heat_map_strength,
                        );
                    }
                }
            }
        }
        // signalOnly means "AI stimulus, do not play": stock skips the relay
        // loop entirely for those (Server.il.txt:29, `brtrue` past the loop).
        if (a.signal_only) return true;
        // Re-encode rather than relay the raw body, and place the sound at the
        // sender when it rides an entity.
        var out_buf: [192]u8 = undefined;
        const relay = packages.buildAudioPlayBody(&out_buf, a) catch {
            self.harness.counters.inc(.encode_errors);
            return true;
        };
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        const ox: f32 = if (a.play_on_entity) self.sim.transform[ps].x else a.x;
        const oz: f32 = if (a.play_on_entity) self.sim.transform[ps].z else a.z;
        self.broadcastNearExcept("NetPackageAudio", relay, ox, oz, self.interest_range, c.slot) catch {
            self.harness.counters.inc(.net_send_errors);
        };
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageMapPosition")) {
        // In-game minimap drive (RE protocol-packages.md §3.3): the client
        // sends its map middle (entityId + Vector2i); the server fills the
        // 17x17 chunk window around it with NetPackageMapChunks. Accept only
        // the sender's own entity; a moved middle resets the sent set.
        if (body.len >= 12) {
            const eid = std.mem.readInt(i32, body[0..4], .little);
            if (eid != c.entity_id) return true;
            const mx = std.mem.readInt(i32, body[4..8], .little);
            const mz = std.mem.readInt(i32, body[8..12], .little);
            if (!c.map_middle_set or c.map_middle_x != mx or c.map_middle_z != mz) {
                c.map_middle_x = mx;
                c.map_middle_z = mz;
                c.map_middle_set = true;
                @memset(&c.map_chunks_sent, 0);
            }
        }
        return true;
    }
    return false;
}
