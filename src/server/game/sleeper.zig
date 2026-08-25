//! Sleeper-volume scan + spawn extracted from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const apm = @import("../../apm/root.zig");
const sleepers_mod = @import("../../world/sleepers.zig");
const parallel_util = @import("../../util/parallel.zig");
const jobs = @import("../../ecs/jobs.zig");
const comps = @import("../../ecs/components.zig");
const rng_util = @import("../../util/rng.zig");

// Mirrors Game internals needed by the sleeper loop; kept here to avoid
// re-exporting private Game helpers via game.zig. The wake/stage radius is the
// Game field (`[sim] sleeper_party_radius`, default 100; PROVENANCE.md §3.7).

pub fn gatherPlayerPositions(self: *Game, px: *[game_mod.max_clients]f32, py: *[game_mod.max_clients]f32, pz: *[game_mod.max_clients]f32) usize {
    var pn: usize = 0;
    for (&self.clients) |*cl| {
        if (!cl.joined or cl.entity_id <= 0) continue;
        const si = self.sim.slotOfNetId(cl.entity_id) orelse continue;
        if (!self.sim.mask[si].transform) continue;
        if (pn >= px.len) break;
        px[pn] = self.sim.transform[si].x;
        py[pn] = self.sim.transform[si].y;
        pz[pn] = self.sim.transform[si].z;
        pn += 1;
    }
    return pn;
}

pub const SleeperScanCtx = struct {
    sl: *const sleepers_mod.Store,
    px: []const f32,
    py: []const f32,
    pz: []const f32,
    hit: []u8,

    pub fn work(ctx: SleeperScanCtx, begin: usize, end: usize) void {
        var vi = begin;
        while (vi < end) : (vi += 1) {
            if (ctx.sl.volumes[vi].triggered) continue;
            var p: usize = 0;
            while (p < ctx.px.len) : (p += 1) {
                if (ctx.sl.contains(vi, ctx.px[p], ctx.py[p], ctx.pz[p])) {
                    ctx.hit[vi] = 1;
                    break;
                }
            }
        }
    }
};

pub fn tickSleeperVolumes(self: *Game) void {
    if (self.sleepers.volumes.len == 0) return;
    var px: [game_mod.max_clients]f32 = undefined;
    var py: [game_mod.max_clients]f32 = undefined;
    var pz: [game_mod.max_clients]f32 = undefined;
    const pn = gatherPlayerPositions(self, &px, &py, &pz);
    if (pn == 0) return;

    var hit: [sleepers_mod.max_volumes]u8 = undefined;
    const vn = @min(self.sleepers.volumes.len, hit.len);
    @memset(hit[0..vn], 0);
    {
        const sc = apm.profiler.scope(&self.harness.prof, .sleeper_scan);
        defer sc.end();
        const ctx = SleeperScanCtx{
            .sl = &self.sleepers,
            .px = px[0..pn],
            .py = py[0..pn],
            .pz = pz[0..pn],
            .hit = hit[0..vn],
        };
        if (self.job_batches and vn >= parallel_util.min_parallel_items) {
            jobs.forSlotRange(vn, ctx, SleeperScanCtx.work);
        } else {
            SleeperScanCtx.work(ctx, 0, vn);
        }
    }
    self.harness.counters.add(.sleeper_volumes_scanned, vn);

    var vi: usize = 0;
    while (vi < vn) : (vi += 1) {
        if (hit[vi] == 0) continue;
        triggerVolume(self, vi);
    }
}

/// Stock Touch/CheckTrigger re-arm (Touch IL_0100-0134, CheckTrigger
/// IL_0109-014F): a cleared volume past its respawnTime becomes triggerable
/// again (respawnTime = Max(respawnTime, worldTime + 1000), the group
/// respawns on the next trigger; maxInt = never). Returns true when the
/// volume is triggerable after the call (not latched, or re-armed now).
fn rearmIfExpired(self: *Game, vi: usize) bool {
    const vol = &self.sleepers.volumes[vi];
    if (!vol.triggered) return true;
    if (vol.respawn_time == 0) return false; // live trigger, not cleared
    if (vol.respawn_time == std.math.maxInt(u64)) return false; // never re-arm
    const wt = self.sim.director.clock.worldTimeBits();
    if (wt < vol.respawn_time) return false;
    vol.respawn_time = wt + 1000;
    vol.triggered = false;
    vol.spawned_alive = 0;
    return true;
}

/// Spawn a sleeper volume's group (stock TouchGroup). Shared by the
/// player-entry scan and the noise scan (CheckSleeperVolumeNoise).
fn triggerVolume(self: *Game, vi: usize) void {
    if (vi >= self.sleepers.volumes.len) return;
    if (!rearmIfExpired(self, vi)) return;
    var vol = &self.sleepers.volumes[vi];
    // A completed ClearSleepers quest suppressed this volume: it never
    // re-arms (stock removes the POI's sleeper data on SleepersCleared).
    if (vol.quest_cleared) return;
    // `[sim] sleeper_cap_gate_enabled` (default false = the documented zdtd
    // divergence): when enabled, restore stock's CanSpawn(2.1f) global gate
    // (EnemyCount < MaxSpawnedZombies * 2.1, spawning.md) BEFORE waking the
    // volume, so an over-cap world leaves it armed for a later restore.
    if (self.sleeper_cap_gate_enabled) {
        const cap: u32 = @intFromFloat(@as(f32, @floatFromInt(self.sim.director.max_alive)) * 2.1);
        if (self.sim.countKind(.zombie) >= cap) return;
    }
    vol.triggered = true;
    self.sleepers.trigger_count += 1;
    // DIVERGENCE: stock SleeperVolume.UpdateSpawn gates every restore on
    // AIDirector.CanSpawn(2.1f) (EnemyCount < MaxSpawnedZombies * 2.1,
    // spawning.md); zdtd spawns regardless of the global zombie cap - the
    // volume count is group/255-capped only (ledger sleeper row).

    // Stock TouchGroup cascade (entity-ai.md TouchGroup IL=52): a volume with
    // a nonzero SleeperVolumeGroupId wakes every other volume of the same
    // prefab placement sharing that id. Origin equality keeps duplicate
    // placements of the same prefab from waking each other across the map;
    // the `triggered` latch terminates the recursion.
    if (vol.group_id != 0) {
        var vj: usize = 0;
        while (vj < self.sleepers.volumes.len) : (vj += 1) {
            if (vj == vi) continue;
            const other = &self.sleepers.volumes[vj];
            if (other.group_id != vol.group_id) continue;
            if (other.triggered or other.quest_cleared) continue;
            if (other.origin_x != vol.origin_x or other.origin_y != vol.origin_y or other.origin_z != vol.origin_z) continue;
            if (!std.mem.eql(u8, other.prefab, vol.prefab)) continue;
            triggerVolume(self, vj);
        }
    }

    const grp = vol.groups[0];
    const seed: u32 = @intCast((vi + 1) *% 2654435761 % 0xffffffff);
    const cx: f32 = @floatFromInt(@divTrunc(vol.x0 + vol.x1, 2));
    const cz: f32 = @floatFromInt(@divTrunc(vol.z0 + vol.z1, 2));
    const vol_stage: i32 = @max(0, self.partyStageAround(cx, cz, self.sleeper_party_radius));
    const stage_spawn = self.gamestages.sleeperEntityGroup(grp.class_name, vol_stage);
    const def = self.resolveSleeperClass(grp.class_name, stage_spawn, seed);
    // Stock AddSpawnCount samples RandomRange(min, max) with a position-seeded
    // random (RE entity-ai.md AddSpawnCount IL=50: fractional ceil, min>0 forces
    // at least 1), not a fixed min + (vi % span) cycle. Separate rng instance so
    // the spawn-position stream below stays unchanged.
    var count_prng = rng_util.XorShift32.init(seed +% 0x9E3779B9);
    const count: u8 = if (stage_spawn) |sg|
        @intCast(@max(1, @min(sg.num, @as(u16, 255))))
    else if (grp.max_count <= grp.min_count) grp.min_count else blk: {
        const span = grp.max_count - grp.min_count + 1;
        break :blk grp.min_count + @as(u8, @intCast(count_prng.nextBounded(span)));
    };
    const alive_cap: u8 = if (stage_spawn) |sg|
        @intCast(@max(1, @min(sg.max_alive, @as(u16, 255))))
    else
        255;

    if (vol.spawns.len > 0) {
        const cap: usize = @min(@as(usize, @min(count, alive_cap)), vol.spawns.len);
        var n: usize = 0;
        while (n < cap) : (n += 1) {
            const sp = vol.spawns[n];
            _ = self.sim.spawnSleeperDef(
                @floatFromInt(sp.x),
                @floatFromInt(sp.y),
                @floatFromInt(sp.z),
                self.entityClassOf(def),
                @intCast(vi + 1),
            );
        }
        vol.spawned_alive = @intCast(@min(cap, 255));
        return;
    }

    const spanx: i32 = @max(1, vol.x1 - vol.x0);
    const spanz: i32 = @max(1, vol.z1 - vol.z0);
    const cy: f32 = @floatFromInt(vol.y0 + 1);
    var prng = rng_util.XorShift32.init(seed);
    var n: u8 = 0;
    while (n < count and n < alive_cap and n < 8) : (n += 1) {
        const ox: f32 = @floatFromInt(vol.x0 + @as(i32, @intCast(prng.nextBounded(@intCast(spanx)))));
        const oz: f32 = @floatFromInt(vol.z0 + @as(i32, @intCast(prng.nextBounded(@intCast(spanz)))));
        _ = self.sim.spawnSleeperDef(ox, cy, oz, self.entityClassOf(def), @intCast(vi + 1));
    }
    vol.spawned_alive = n;
}

/// Wake sleeper volumes whose AABB (+0.9 pad, stock SleeperVolume.CheckNoise)
/// contains a combat-noise event. The stock wake is player-independent
/// (World.CheckSleeperVolumeNoise, entity-ai.md 844): a shot inside a POI
/// spawns its sleepers even before the player enters. Must run BEFORE
/// systems.tickAll consumes the noise ring.
pub fn triggerSleeperVolumesByNoise(self: *Game) void {
    if (self.sleepers.volumes.len == 0) return;
    const take = @min(self.sim.noise_n, self.sim.noise_events.len);
    if (take == 0) return;
    wakeVolumesAt(self, self.sim.noise_events[0..take]);
}

/// Wake sleeper volumes at the movement-noise positions the stealth system
/// queued (stock PlayerStealth.NotifyNoise hitting the 360 volume cap →
/// World.CheckSleeperVolumeNoise). Runs AFTER the sim tick (the stealth
/// system pushed the points mid-tick), then drains the ring.
pub fn triggerSleeperVolumesByStealthNoise(self: *Game) void {
    defer self.sim.sleeper_volume_noise_n = 0;
    if (self.sleepers.volumes.len == 0) return;
    const take = @min(self.sim.sleeper_volume_noise_n, self.sim.sleeper_volume_noise.len);
    if (take == 0) return;
    wakeVolumesAt(self, self.sim.sleeper_volume_noise[0..take]);
}

/// The AABB-containment wake shared by the combat-noise and stealth-noise
/// rings (stock World.CheckSleeperVolumeNoise / SleeperVolume.CheckNoise).
fn wakeVolumesAt(self: *Game, events: []const comps.NoiseEvent) void {
    const pad: f32 = 0.9;
    var vi: usize = 0;
    while (vi < self.sleepers.volumes.len) : (vi += 1) {
        // A latched volume re-arms when its respawnTime passed (stock
        // Touch/CheckTrigger re-arm); the noise can then re-trigger it.
        if (!rearmIfExpired(self, vi)) continue;
        const vol = self.sleepers.volumes[vi];
        if (vol.quest_cleared) continue;
        var hit = false;
        var ni: usize = 0;
        while (ni < events.len and !hit) : (ni += 1) {
            const ev = events[ni];
            if (ev.x < @as(f32, @floatFromInt(vol.x0)) - pad or ev.x > @as(f32, @floatFromInt(vol.x1)) + pad) continue;
            if (ev.z < @as(f32, @floatFromInt(vol.z0)) - pad or ev.z > @as(f32, @floatFromInt(vol.z1)) + pad) continue;
            if (ev.y < @as(f32, @floatFromInt(vol.y0)) - pad or ev.y > @as(f32, @floatFromInt(vol.y1)) + pad) continue;
            hit = true;
        }
        if (hit) triggerVolume(self, vi);
    }
}

/// Stock SleeperVolume.ClearedUpdate (IL=33) + EntityDied (IL=31): when a
/// triggered volume's last sleeper zombie dies (and it is not still
/// spawning), respawnTime = worldTime + LootRespawnDays x 24000 ticks (or
/// never when LootRespawnDays <= 0), so a later touch re-arms the volume
/// and its group respawns. zdtd recounts the per-volume alive
/// sleeper-spawned zombies each tick through the ECS `sleeper_vol` link
/// instead of hooking every death; the transition from a positive count to
/// zero is the ClearedUpdate event.
pub fn tickSleeperRearm(self: *Game) void {
    const vols = self.sleepers.volumes.len;
    if (vols == 0) return;
    var alive: [sleepers_mod.max_volumes]u8 = .{0} ** sleepers_mod.max_volumes;
    for (self.sim.kind_groups.slice(.zombie)) |s| {
        // Stock EntityDied fires on death (hp 0), not on the later destroy
        // sweep: a dead-but-not-yet-reaped sleeper no longer counts.
        if (!self.sim.alive[s] or !self.sim.mask[s].sleeper) continue;
        if (self.sim.health[s].hp <= 0) continue;
        const v = self.sim.sleeper_vol[s];
        if (v == 0 or @as(usize, v) > vols) continue;
        alive[v - 1] +|= 1;
    }
    const days = self.loot_respawn_days;
    const wt = self.sim.director.clock.worldTimeBits();
    var vi: usize = 0;
    while (vi < vols) : (vi += 1) {
        const vol = &self.sleepers.volumes[vi];
        if (!vol.triggered or vol.quest_cleared) continue;
        if (vol.spawned_alive == 0) continue; // not spawned / already cleared
        if (alive[vi] != 0) continue; // the group is still alive
        // The last zombie died: ClearedUpdate.
        vol.respawn_time = if (days > 0) wt + @as(u64, days) * 24000 else std.math.maxInt(u64);
        vol.spawned_alive = 0;
    }
}
