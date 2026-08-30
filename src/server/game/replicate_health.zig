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
                // victims and latches has_backpack, so a death is never bagged
                // twice): DropOnDeath modes 1..3 drop the victim's real
                // inventory range as a bag at the death position.
                if (!oc.has_backpack) self.spawnDeathBag(i);
                if (oc.peer) |op| {
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
        for (&self.clients) |*cl| {
            if (!cl.joined or !cl.entered) continue;
            const peer = cl.peer orelse continue;
            const owner = is_player and self.sim.player[i].peer_slot == @as(i32, @intCast(cl.slot));
            if (!owner and !self.clientObserves(cl, tp.x, tp.z)) continue;
            self.sendGame(peer, "NetPackageEntityStatChanged", body) catch {
                self.harness.counters.inc(.net_send_errors);
            };
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
