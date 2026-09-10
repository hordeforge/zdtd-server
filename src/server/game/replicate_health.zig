//! Health replicate path - extracted verbatim from game.zig.
//! Thin forwarder keeps callers unchanged.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const interest = @import("../../ecs/interest.zig");

/// Drain the hp dirty bit into stock EntityStatChanged(Health) packages.
/// See game.zig replicatePlayerHealth for the full doc comment.
pub fn replicatePlayerHealth(self: *Game) void {
    var i: ecs.Slot = 0;
    while (i < ecs.max_entities) : (i += 1) {
        if (!self.sim.alive[i] or !self.sim.mask[i].dirty or !self.sim.dirty[i].hp) continue;
        self.sim.dirty[i].hp = false;
        self.sim.syncDirtyBit(i);
        const is_player = self.sim.mask[i].player;
        const is_mob = self.sim.kind[i] == .zombie or self.sim.kind[i] == .animal;
        if ((!is_player and !is_mob) or !self.sim.mask[i].health) continue;
        if (is_player and self.sim.health[i].hp <= 0) {
            const owner_slot = self.sim.player[i].peer_slot;
            if (owner_slot >= 0 and @as(usize, @intCast(owner_slot)) < self.clients.len) {
                const oc = &self.clients[@intCast(owner_slot)];
                // AI-inflicted deaths land here (the C2S kill path bags its own
                // victims and latches `bagged_this_death`, so a death is never
                // bagged twice): DropOnDeath modes 1..3 drop the victim's real
                // inventory range as a bag at the death position.
                if (!oc.bagged_this_death) self.spawnDeathBag(i);
                if (oc.peer) |op| {
                    // Stock EntityPlayer.HandleClientDeath (IL=71) switches on
                    // GameStats DeathPenalty and runs the matching
                    // game_on_death_* sequence; the AddXPDeficit client action
                    // reaches the dead player's client as a
                    // ClientSequenceAction (12) response, which earns the
                    // deficit locally (AddXPDeficit IL=65, passive 0x61
                    // default 0.1 clamped by 0x60 default 0.5). Only the two
                    // sequences carrying AddXPDeficit send one:
                    // game_on_death_default (DeathPenalty 1, gameevents.xml:67)
                    // and game_on_death_injured (DeathPenalty 2,
                    // gameevents.xml:78); AddXPDeficit is action index 0 in
                    // both, and root action keys are `Name:index`
                    // (SetActionKeyData), so the keys below are exact.
                    // Without this the client's local death flow is the only
                    // earn path; stock also drives it from the server side.
                    const seq: ?struct { name: []const u8, key: []const u8 } = switch (self.death_penalty) {
                        1 => .{ .name = "game_on_death_default", .key = "game_on_death_default:0" },
                        2 => .{ .name = "game_on_death_injured", .key = "game_on_death_injured:0" },
                        else => null,
                    };
                    if (seq) |sq| {
                        if (packages.buildGameEventSequenceAction(self.body_buf[200..456], sq.name, oc.entity_id, sq.key)) |sdb| {
                            self.sendGame(op, "NetPackageGameEventResponse", sdb) catch {
                                self.harness.counters.inc(.net_send_errors);
                            };
                        } else |_| {}
                    }
                    const wsp = self.world.primarySpawn();
                    var entries: [2]packages.SpawnPointEntry = undefined;
                    var en: usize = 0;
                    entries[en] = .{ .x = @floatFromInt(wsp.x), .y = @floatFromInt(wsp.y), .z = @floatFromInt(wsp.z) };
                    en += 1;
                    if (oc.has_bed and en < entries.len) {
                        entries[en] = .{ .x = @floatFromInt(oc.bed_x), .y = @floatFromInt(oc.bed_y), .z = @floatFromInt(oc.bed_z) };
                        en += 1;
                    }
                    if (packages.buildWorldSpawnPoints(self.body_buf[96..200], entries[0..en])) |spb| {
                        self.sendGame(op, "NetPackageWorldSpawnPoints", spb) catch {
                            self.harness.counters.inc(.net_send_errors);
                        };
                    } else |_| {}
                }
            }
        }
        if (!self.sim.mask[i].network_id or !self.sim.mask[i].transform) continue;
        const nid = self.sim.network_id[i].id;
        if (nid <= 0) continue;
        const body = packages.buildEntityStatChangedBody(
            self.body_buf[0..32],
            nid,
            -1,
            .health,
            self.sim.health[i].hp,
            self.sim.health[i].max_hp,
            0,
        ) catch {
            self.harness.counters.inc(.encode_errors);
            continue;
        };
        self.harness.counters.inc(.packages_encoded);
        const tp = self.sim.transform[i];
        // EntityStatChanged is latest-wins droppable under WindowFull. If any
        // interested peer could not take the send, re-dirty so the next tick
        // retries with the current HP instead of leaving the client stale.
        var any_send_failed = false;
        for (&self.clients) |*cl| {
            if (!cl.joined or !cl.entered) continue;
            const peer = cl.peer orelse continue;
            const owner = is_player and self.sim.player[i].peer_slot == @as(i32, @intCast(cl.slot));
            if (!owner and !self.clientObserves(cl, tp.x, tp.z)) continue;
            self.sendGame(peer, "NetPackageEntityStatChanged", body) catch {
                self.harness.counters.inc(.net_send_errors);
                any_send_failed = true;
            };
        }
        if (any_send_failed) {
            self.sim.dirty[i].hp = true;
            self.sim.syncDirtyBit(i);
        }
    }
}

pub fn clientObserves(self: *const Game, cl: *const Client, wx: f32, wz: f32) bool {
    if (cl.entity_id <= 0) return false;
    const oi = self.sim.slotOfNetId(cl.entity_id) orelse return false;
    if (!self.sim.mask[oi].transform) return false;
    const op = self.sim.transform[oi];
    return interest.inRange(op.x, op.z, wx, wz, cl.view_radius);
}
