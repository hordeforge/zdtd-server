//! Health replicate path - extracted verbatim from game.zig.
//! Thin forwarder keeps callers unchanged.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const interest = @import("../../ecs/interest.zig");

/// Drain the hp dirty bit into stock EntityStatChanged(Health) packages.
/// See game.zig replicatePlayerHealth for the full doc comment.
pub fn replicatePlayerHealth(self: *Game) void {
    // Walk the dirty set rather than all `max_entities` slots: this runs every
    // tick and only an hp-dirty entity can have an update, and every hp writer
    // either funnels through markDirty or syncs explicitly (the WindowFull
    // retry below). A snapshot, because the body destroys and re-marks
    // entities on the death path while it walks.
    var dirty_now = self.sim.dirty_bits;
    var dirty_it = dirty_now.iterator(.{});
    while (dirty_it.next()) |idx| {
        const i: ecs.Slot = @intCast(idx);
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
                // Death ledger: stock EntityAlive.OnEntityDeath (IL=146) bumps
                // the victim's Died through AddScore(1, 0, 0, -1, 0), and
                // EntityNetworkStats.killed is filled from get_Died()
                // (FillFromEntity IL=150). Count each corpse once.
                if (!oc.death_counted) {
                    oc.deaths += 1;
                    oc.death_counted = true;
                }
                // AI-inflicted deaths land here (the C2S kill path bags its own
                // victims and latches `bagged_this_death`, so a death is never
                // bagged twice): DropOnDeath modes 1..3 drop the victim's real
                // inventory range as a bag at the death position.
                if (!oc.bagged_this_death) self.spawnDeathBag(i);
                if (oc.peer) |op| {
                    // Stock EntityPlayer.HandleClientDeath (IL=71) switches on
                    // GameStats DeathPenalty and runs the matching
                    // game_on_death_* sequence. The runner applies the
                    // ActionBaseTargetAction legs (RemoveDeathBuffs, honouring
                    // the injured sequence's `exclude_tags="deathpenalty_injured"`)
                    // and sends one ClientSequenceAction (12) response per
                    // ActionBaseClientAction leg - AddXPDeficit among them,
                    // which earns the deficit on the dead client.
                    const seq_name = Game.deathSequenceName(self.death_penalty);
                    if (seq_name) |sname| {
                        if (!self.runGameEventSequence(oc.slot, sname)) {
                            // Offline floor (no stock gameevents.xml): the two
                            // sequences that declare AddXPDeficit still have to
                            // drive the client's deficit, at stock's index 0.
                            if (self.death_penalty == 1 or self.death_penalty == 2) {
                                var key_buf: [64]u8 = undefined;
                                if (std.fmt.bufPrint(&key_buf, "{s}0", .{sname})) |key| {
                                    if (packages.buildGameEventSequenceAction(self.body_buf[200..456], sname, oc.entity_id, key)) |sdb| {
                                        self.sendGame(op, "NetPackageGameEventResponse", sdb) catch {
                                            self.harness.counters.inc(.net_send_errors);
                                        };
                                    } else |_| {}
                                } else |_| {}
                            }
                        }
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
