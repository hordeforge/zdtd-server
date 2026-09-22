//! Stealth + noise system: heat events, noise notify, per-player tick.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const c = @import("components.zig");
const query = @import("query.zig");
const protocol = @import("../protocol.zig");
const stealthLightLevel = @import("sensing.zig").stealthLightLevel;
const PlayerSnap = @import("sensing.zig").PlayerSnap;
const canSensePlayer = @import("sensing.zig").canSensePlayer;
const stealthLightAttackPercent = @import("sensing.zig").stealthLightAttackPercent;
const nearestPlayerSnap = @import("sensing.zig").nearestPlayerSnap;
const stealthLightPreBlend = @import("sensing.zig").stealthLightPreBlend;
const systemZombieAi = @import("ai_tasks.zig").systemZombieAi;

/// Heat window stock gives every noise-driven heat event: `NotifyNoise` passes
/// the literal 240 s to `AIDirector::NotifyActivity` (AIDirector.il.txt
/// IL_00D9); the 4th argument decays in seconds (`AIDirectorChunkData::DecayEvents`
/// subtracts the tick's seconds), and `Director.notifyActivity` takes ticks.
const stealth_heat_window_s: f32 = 240.0;

/// Player movement-noise model (RE entity-ai.md PlayerStealth): consumes the
/// stealth-noise ring pushed by the sound relay, folds each event into the
/// owning player's stealth state (stock PlayerStealth.NotifyNoise), then runs
/// the per-player noise decay/CalcVolume + attraction pass (stock TickServer).
/// Single-threaded (players are few); runs before the parallel AI pass so
/// zombies react to this tick's noise the same tick (stock entity update
/// order: players before enemies). Ring consume-owns-drain like combat noise.
pub fn systemStealth(w: *World) void {
    const take = @min(w.stealth_noise_n, c.stealth_events_cap);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const ev = w.stealth_noise_events[i];
        const s: Slot = @intCast(ev.slot);
        if (!w.alive[s] or !w.mask[s].player or !w.mask[s].transform) continue;
        stealthNotifyNoise(w, s, ev);
    }
    w.stealth_noise_n = 0;
    for (query.groupSlice(w, .player)) |s| {
        if (!w.alive[s] or !w.mask[s].player or !w.mask[s].transform) continue;
        stealthTick(w, s);
    }
}

/// Stock AIDirector.NotifyNoise (IL=84) + PlayerStealth.NotifyNoise (IL=71):
/// a relayed sound with a sounds.xml `<Noise>` row folds into the owning
/// player's stealth list, sleeper-noise volume (wake at the cap) and heat map.
fn stealthNotifyNoise(w: *World, s: Slot, ev: c.StealthNoiseEvent) void {
    const r = w.rules.ai;
    // The crouched instigator's volumeScale is muffled by the clip's
    // muffled_when_crouched (stock IL_0074-008A); the same scaled factor
    // rides the heat leg below (stock re-reads the overwritten arg).
    var scale: f32 = 1.0;
    if (w.player[s].crouching) scale = ev.muffled_when_crouched;
    const volume = ev.volume * scale;
    if (volume <= 0) return;
    const st = &w.stealth[s];
    // PlayerStealth.AddNoise: insert (volume, ticks) descending by volume.
    var idx: u8 = 0;
    while (idx < st.noise_n and st.noises[idx].volume >= volume) : (idx += 1) {}
    if (idx < c.stealth_noise_cap) {
        var j = @min(st.noise_n, c.stealth_noise_cap - 1);
        while (j > idx) : (j -= 1) st.noises[j] = st.noises[j - 1];
        st.noises[idx] = .{ .volume = volume, .ticks = ev.duration_ticks };
        if (st.noise_n < c.stealth_noise_cap) st.noise_n += 1;
    }
    // A loud noise (volume >= 11) pauses the sleeper-volume decay window.
    if (volume >= r.stealth_loud_volume) st.sleeper_noise_wait_ticks = r.stealth_loud_wait_ticks;
    // NotifyNoise curve: > 60 becomes 60 + (v-60)^1.4, then the Noise passive
    // (GetValue(88) off the victim's buffs/perks/worn items, cached per tick
    // by the survival pass; the column falls back to the Rules floor offline).
    var eff = volume;
    if (volume > 60) eff = 60 + std.math.pow(f32, volume - 60, 1.4);
    eff *= w.stealth_noise_mult[s];
    st.sleeper_noise_volume += eff;
    if (st.sleeper_noise_volume >= r.stealth_sleeper_wake_volume) {
        st.sleeper_noise_volume = r.stealth_sleeper_wake_volume;
        // Stock World.CheckSleeperVolumeNoise(pos): the Game wakes volumes
        // whose AABB contains the point (post-tick drain of this ring).
        w.pushSleeperVolumeNoise(ev.x, ev.y, ev.z);
    }
    // Heat map (stock AIDirector.NotifyActivity): heatMapStrength x the
    // (muffled) volumeScale, held for the fixed window `NotifyNoise` passes
    // (`ldc.r4 240`, AIDirector.il.txt IL_00D9 - the row's own heat_map_time
    // never reaches the live path).
    if (ev.heat_map_strength > 0) {
        w.director.notifyActivity(ev.x, ev.z, ev.heat_map_strength * scale, stealth_heat_window_s * 20.0);
    }
}

/// Stock PlayerStealth.TickServer (IL=430): per-tick noise decay (NoiseCleanup
/// + CalcVolume), sleeper-volume decay, and the attraction pass - a zombie
/// hears when `noiseVolume x (1+feralSense) / (dist x 0.6 + 0.4) x
/// detectUsScale >= 1` inside the attraction radius.
fn stealthTick(w: *World, s: Slot) void {
    const r = w.rules.ai;
    const st = &w.stealth[s];
    // RE PlayerStealth.TickServer speedAverage (step 1): lerp toward the
    // per-tick horizontal speed (blocks/s) at 0.2 when moving, decay x0.5
    // when idle. Feeds the light fold `x (1 + speedAverage x 0.15)`.
    const sdx = w.transform[s].x - st.prev_x;
    const sdz = w.transform[s].z - st.prev_z;
    const speed = @sqrt(sdx * sdx + sdz * sdz) * @as(f32, @floatFromInt(protocol.ticks_per_second));
    st.prev_x = w.transform[s].x;
    st.prev_z = w.transform[s].z;
    st.speed_average = if (speed > 0.01)
        st.speed_average + (speed - st.speed_average) * 0.2
    else
        st.speed_average * 0.5;
    // NoiseCleanup: decrement ticks, drop expired entries.
    var i: u8 = 0;
    while (i < st.noise_n) {
        if (st.noises[i].ticks <= 1) {
            var j = i;
            while (j + 1 < st.noise_n) : (j += 1) st.noises[j] = st.noises[j + 1];
            st.noise_n -= 1;
        } else {
            st.noises[i].ticks -= 1;
            i += 1;
        }
    }
    // CalcVolume: geometric-decay sum (0.6^i), then (sum x 2.35)^0.86 x 1.5
    // x the Noise passive.
    var sum: f32 = 0;
    var wgt: f32 = 1;
    for (st.noises[0..st.noise_n]) |n| {
        sum += n.volume * wgt;
        wgt *= r.stealth_noise_decay;
    }
    const vol = std.math.pow(f32, sum * r.stealth_noise_curve_a, r.stealth_noise_curve_b) *
        r.stealth_noise_scale * w.stealth_noise_mult[s];
    st.noise_volume = vol;
    // Sleeper-volume decay: 2.5/tick once the loud-noise wait window elapses.
    if (st.sleeper_noise_wait_ticks > 0) {
        st.sleeper_noise_wait_ticks -= 1;
    } else if (st.sleeper_noise_volume > 0) {
        st.sleeper_noise_volume -= r.stealth_sleeper_volume_decay;
        st.sleeper_noise_volume = @max(st.sleeper_noise_volume, 0);
    }
    // Attraction (stock TickServer IL_01BF+): while the raw sum is non-zero,
    // scan the attraction radius around the player for hearing zombies.
    if (sum <= 0) return;
    const sense = r.stealth_attract_sense_scale;
    var radius = sum * r.stealth_noise_decay * (1 + sense * 1.6);
    radius = @min(radius, r.stealth_attract_radius_cap_a + r.stealth_attract_radius_cap_b * sense);
    if (radius <= 0) return;
    const px = w.transform[s].x;
    const pz = w.transform[s].z;
    const r2 = radius * radius;
    for (query.groupSlice(w, .zombie)) |zs| {
        if (!w.alive[zs] or !w.mask[zs].zombie_ai or !w.mask[zs].transform) continue;
        const dx = w.transform[zs].x - px;
        const dz = w.transform[zs].z - pz;
        const d2 = dx * dx + dz * dz;
        if (d2 > r2) continue;
        const dist = @sqrt(d2);
        // Stock heard test (TickServer IL_0254-02B4): noiseVolume x
        // (1 + feralSense) / (dist x 0.6 + 0.4) x detectUsScale >= 1.
        const heard = vol * (1 + r.stealth_hear_feral_sense) /
            (dist * 0.6 + 0.4) * r.stealth_hear_detect_us;
        if (heard < 1) continue;
        const ai = &w.zombie_ai[zs];
        if (w.mask[zs].sleeper and !w.sleeper[zs].awake) {
            // A sleeping zombie that hears wakes and investigates (stock
            // sleeper wake; the 360-cap volume wake is the separate
            // CheckSleeperVolumeNoise leg).
            w.sleeper[zs].awake = true;
            ai.state = .chase;
            ai.alert = true;
            w.pushSleeperWake(zs);
        }
        if (ai.state == .idle or ai.state == .wander) {
            ai.alert = true;
            ai.state = .chase;
            ai.target_id = -1;
            ai.spot_x = px;
            ai.spot_z = pz;
            ai.has_spot = true;
        }
    }
}

test "stealth: CanSeeStealth light gate gates sight by the TickServer lightLevel" {
    // EAITarget.check (IL=71): a player target must pass CanSee AND
    // CanSeeStealth (EntityAlive IL=21): lightLevel > FastLerp(min, max,
    // dist/sightRange). Stock zombieTemplateMale SightLightThreshold "-2,150":
    // noon lightLevel (46.26) sees within ~31.6% of sightRange (8 m of a
    // 30 m range, threshold 38.5); night (0) sees only point blank (threshold
    // -2 at t=0); crouching (×0.6 → 27.76) drops the noon reach below 8 m.
    // hear 0.1 keeps every assertion on the sight branch (beyond hearing).
    var w: World = .{ .rules = .{ .ai = .{
        .sense_dist_sq = 48 * 48,
        .sight_light_threshold_min = 30.0,
        .sight_light_threshold_max = 100.0,
    } } };
    defer w.deinit();
    w.class_table[0].sight_range = 30.0;
    w.class_table[0].sight_light_min = -2.0;
    w.class_table[0].sight_light_max = 150.0;
    const zyaw: f32 = 90.0; // faces +x; no walls (LOS clear).
    const hear: f32 = 0.1;
    const noon = stealthLightLevel(0.5, 0, false, 0.89, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 46.26), noon, 0.01);
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 8, 70, 0, hear, noon));
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, 20, 70, 0, hear, noon));
    const crouched = stealthLightLevel(0.5, 0, true, 0.89, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 27.76), crouched, 0.01);
    // Held-item light (selfLight blend, RE entity-ai.md TickServer step 2):
    // a pistol light (.45) at night adds selfLight x clamp(selfLight /
    // (light + 0.05), 0.5, 3.2).
    const gunlight = stealthLightLevel(0.1, 0.45, false, 0.89, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 134.15), gunlight, 0.05);
    const torchlight = stealthLightLevel(0.05, 0.35, false, 0.89, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 108.25), torchlight, 0.05);
    // The lightAttackPercent switch: a held light (>= 0.1) lifts the crouch
    // reach from the passive-89 value to 1 (full FastLerp(3, 15, t) range).
    try std.testing.expectApproxEqAbs(@as(f32, 0.89), stealthLightAttackPercent(0, 0.89), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stealthLightAttackPercent(0.45, 0.89), 0.0001);
    // Movement visibility (IL_00CD): light x (1 + speedAverage x 0.15).
    // Noon 46.26 x 1.3 = 60.14 at speedAverage 2 (a jog).
    const moving = stealthLightLevel(0.5, 0, false, 0.89, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 60.14), moving, 0.05);
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, 8, 70, 0, hear, crouched));
    // Night: lightLevel 0 sees only inside the threshold's -2 floor (t <
    // 2/152 → < ~0.4 m); 5 m is hidden. Hearing is untouched by the light
    // gate (a night 5 m player at hear 10 is still sensed by sound).
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 0.3, 70, 0, hear, 0.0));
    try std.testing.expect(!canSensePlayer(&w, 0, 0, 70, 0, zyaw, 5, 70, 0, hear, 0.0));
    try std.testing.expect(canSensePlayer(&w, 0, 0, 70, 0, zyaw, 5, 70, 0, 10.0, 0.0));
}
test "stealth: crouch muffles the hearing gate through walls" {
    // RE entity-ai.md PlayerStealth NotifyNoise: a crouched player's movement
    // noise is muffled (stock per-clip muffledWhenCrouched; rules floor
    // crouch_hear_scale 0.5), so the hearing gate shrinks while sight stays
    // unchanged. Wall between zombie and player blocks sight; hearing decides.
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 48 * 48, .smell_radius = 2.0 } } };
    defer w.deinit();
    const Wall = struct {
        fn solid(_: ?*anyopaque, x: i32, y: i32, z: i32) bool {
            return x == 4 and y >= 70 and y <= 71 and z == 0;
        }
    };
    w.solid_ctx = null;
    w.solid_fn = &Wall.solid;
    var snaps = [_]PlayerSnap{
        .{ .id = 100, .slot = 0, .x = 8, .y = 70, .z = 0, .crouching = false },
    };
    // Standing at 8 m (hear 10): heard through the wall.
    const t_stand = nearestPlayerSnap(&w, &snaps, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, 100), t_stand.id);
    // Crouched at 8 m (hear 10 x 0.5 = 5): muffled, sight blocked: not sensed.
    snaps[0].crouching = true;
    const t_crouch = nearestPlayerSnap(&w, &snaps, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, -1), t_crouch.id);
    // Crouched but close (3 m < 5): still heard.
    snaps[0] = .{ .id = 100, .slot = 0, .x = 3, .y = 70, .z = 0, .crouching = true };
    const t_close = nearestPlayerSnap(&w, &snaps, 0, 0, 70, 0, 90.0);
    try std.testing.expectEqual(@as(i32, 100), t_close.id);
}
test "stealth: crouched players only wake sleepers within FastLerp(3,15,light)" {
    // RE entity-ai.md CanSleeperAttackDetect: crouching shrinks sleeper
    // disturbance to FastLerp(3, 15, lightAttackPercent). lightAttackPercent
    // is the passive-89 when selfLight < 0.1 (TickServer IL_010B; the sim
    // carries no held-item lights, so it always applies): crouch range
    // 3 + 12×0.89 = 13.68. A crouched player 16 m inside a volume_r 20
    // sleeper stays hidden, 12 m wakes it. Standing wakes at the volume
    // radius regardless of distance within it.
    var w: World = .{ .rules = .{ .ai = .{
        .crouch_sleeper_detect_min = 3.0,
        .crouch_sleeper_detect_max = 15.0,
        .stealth_light_passive = 0.89,
    } } };
    defer w.deinit();
    const z = w.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    w.sleeper[zs].volume_r = 20;
    // Open the disturbed-level light gate (this test isolates the crouch leg;
    // the light gate itself is covered by the next test).
    w.sleeper[zs].wake_light_near = -1000;
    w.sleeper[zs].wake_light_far = -500;
    const p = w.spawnPlayer(16, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    w.player[ps].crouching = true;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.sleeper[zs].awake);
    // In the volume beyond the crouch wake reach: the sleeper STIRS (the
    // one-shot SetSleeperActive / PassiveChange) but stays asleep.
    try std.testing.expect(w.sleeper[zs].groan_sent);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_wake_n);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[0].slot);
    try std.testing.expect(w.sleeper_wake_reqs[0].groan);
    // A crouched player 12 m inside the volume wakes it (13.68 > 12).
    w.transform[ps].x = 12;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 2), w.sleeper_wake_n);
    try std.testing.expect(!w.sleeper_wake_reqs[1].groan);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[1].slot);
}

test "stealth: standing players wake sleepers at the full volume radius" {
    // RE entity-ai.md CanSleeperAttackDetect: not crouching → true, so the
    // volume radius gates the wake (no FastLerp shrink). The crouch leg only
    // protects beyond FastLerp(3,15,0.89) = 13.68: 16 m crouched is out,
    // uncrouching wakes the 20 m volume. The disturbed-level gate is open.
    var w: World = .{ .rules = .{ .ai = .{
        .crouch_sleeper_detect_min = 3.0,
        .crouch_sleeper_detect_max = 15.0,
        .stealth_light_passive = 0.89,
    } } };
    defer w.deinit();
    const z = w.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    w.sleeper[zs].volume_r = 20;
    w.sleeper[zs].wake_light_near = -1000;
    w.sleeper[zs].wake_light_far = -500;
    const p = w.spawnPlayer(16, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    w.player[ps].crouching = true;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.sleeper[zs].awake);
    // In the volume beyond the crouch wake reach: the sleeper stirs once.
    try std.testing.expect(w.sleeper[zs].groan_sent);
    w.player[ps].crouching = false;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 2), w.sleeper_wake_n);
    try std.testing.expect(w.sleeper_wake_reqs[0].groan);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[1].slot);
    try std.testing.expect(!w.sleeper_wake_reqs[1].groan);
}
test "stealth: sleepers wake inside the GetSleeperDisturbedLevel light gate" {
    // RE UpdateSleeper wake scan (entity-ai.md): a sleeping zombie wakes the
    // nearest player with GetSleeperDisturbedLevel(dist, lightLevel) >= 2 -
    // wake = Lerp(rolledWakeNear, rolledWakeFar, dist/sightRangeBase) and
    // lightLevel > wake. With the stock roll midpoints (-17.5 / 410) over a
    // 30 m sightRange, noon (lightLevel 46.26) wakes within ~14.8% of the
    // range (4 m wakes, wake 39.4); night (0) wakes only within ~1.2 m
    // (0.04 pct, wake -0.4); a 2 m night player stays hidden.
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 48 * 48 } } };
    defer w.deinit();
    const z = w.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie, .sight_range = 30.0 }, 0).?;
    const zs = w.slotOfNetId(z).?;
    w.sleeper[zs].volume_r = 20;
    w.sleeper[zs].wake_light_near = -17.5;
    w.sleeper[zs].wake_light_far = 410.0;
    const p = w.spawnPlayer(4, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Day (ambient 0.5 → lightLevel 46.26): 4 m wakes (threshold 39.4).
    w.ambient_light = 0.5;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.sleeper[zs].awake);
    w.sleeper[zs].awake = false; // re-arm for the night case
    w.sleeper_wake_n = 0;
    // Night (lightLevel 0): 4 m hidden (threshold 39.4) - the sleeper STIRS
    // (SetSleeperActive one-shot) but stays asleep; 1 m wakes (-3.9).
    w.ambient_light = 0;
    w.transform[ps].x = 4;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(!w.sleeper[zs].awake);
    try std.testing.expect(w.sleeper[zs].groan_sent);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_wake_n);
    try std.testing.expect(w.sleeper_wake_reqs[0].groan);
    w.transform[ps].x = 1;
    for (0..3) |_| _ = systemZombieAi(&w, 0.05);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 2), w.sleeper_wake_n);
    try std.testing.expect(!w.sleeper_wake_reqs[1].groan);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[1].slot);
}
test "stealth: lightAttackPercent folds the passive-89 below 0.1 selfLight" {
    // RE PlayerStealth.TickServer IL_010B: selfLight (the held-item light,
    // GetStealthLightLevel's out param) < 0.1 → passive-89, else 1.
    try std.testing.expectApproxEqAbs(@as(f32, 0.89), stealthLightAttackPercent(0.0, 0.89), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.89), stealthLightAttackPercent(0.099, 0.89), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stealthLightAttackPercent(0.1, 0.89), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stealthLightAttackPercent(0.5, 0.89), 0.0001);
}

test "group AI: combat noise alerts distant zombies to investigate" {
    // Stock NotifyNoise: a landed melee hit emits noise that alerts zombies
    // within radius even when they cannot sense the player directly; they
    // investigate the spot (has_spot) instead of wandering.
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 4 * 4, .combat_noise_radius = 24.0 } } };
    defer w.deinit();
    const a = w.spawnZombie(0, 70, 0, 40).?;
    const aslot = w.slotOfNetId(a).?;
    _ = w.spawnZombie(10, 70, 0, 40).?;
    const bslot = w.slotOfNetId(a).? + 1;
    const p = w.spawnPlayer(1, 70, 0, 0).?;
    _ = w.slotOfNetId(p).?;
    var hit: u32 = 0;
    var t: f32 = 0;
    while (t < 4.0 and hit == 0) : (t += 0.05) {
        hit = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(hit > 0); // A landed a hit -> noise.
    // B at 10 m cannot sense the player (sense 4) but the noise alerts it.
    try std.testing.expect(w.zombie_ai[aslot].alert);
    try std.testing.expect(w.zombie_ai[bslot].alert);
    try std.testing.expect(w.zombie_ai[bslot].has_spot);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w.zombie_ai[bslot].spot_x, 1.0);
}
test "group AI: combat noise wakes sleepers within radius" {
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 4 * 4, .combat_noise_radius = 24.0 } } };
    defer w.deinit();
    _ = w.spawnZombie(0, 70, 0, 40).?;
    const z = w.spawnSleeperDef(12, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    w.sleeper[zs].volume_r = 16;
    _ = w.spawnPlayer(1, 70, 0, 0).?;
    var hit: u32 = 0;
    var t: f32 = 0;
    while (t < 4.0 and hit == 0) : (t += 0.05) {
        hit = systemZombieAi(&w, 0.05);
    }
    try std.testing.expect(hit > 0);
    // The sleeper at 12 m (volume 16 would need the player closer, but the
    // noise radius 24 covers it) wakes and investigates.
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expect(w.zombie_ai[zs].has_spot);
    // The noise wake also pushed the SleeperWakeup wire event; the player at
    // 11 m was in the volume (16) first, so the sleeper stirred (groan req)
    // before the noise woke it (wake req).
    try std.testing.expect(w.sleeper[zs].groan_sent);
    try std.testing.expectEqual(@as(usize, 2), w.sleeper_wake_n);
    try std.testing.expect(w.sleeper_wake_reqs[0].groan);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[1].slot);
    try std.testing.expect(!w.sleeper_wake_reqs[1].groan);
}
test "damage wakes a sleeper and pushes the wakeup event" {
    // Stock EntityAlive.ProcessDamageResponseLocal: any damage triggers
    // ConditionalTriggerSleeperWakeUp (plus CheckSleeperVolumeNoise while
    // passive). The sim flips the sleeper awake and the Game broadcasts
    // NetPackageSleeperWakeup from the drained ring.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expect(!w.sleeper[zs].awake);
    _ = w.damageFrom(z, 10.0, -1);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_wake_n);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[0].slot);
    // The ring is consume-owns-drain: the drainer zeroes the count; a second
    // hit on the now-awake sleeper pushes nothing new.
    w.sleeper_wake_n = 0;
    _ = w.damageFrom(z, 5.0, -1);
    try std.testing.expectEqual(@as(usize, 0), w.sleeper_wake_n);
}

test "stealth noise: a loud clip folds into the player and alerts a zombie" {
    // RE entity-ai.md PlayerStealth: a relayed sound with a sounds.xml Noise
    // row accumulates into the player's stealth list; CalcVolume + the heard
    // test alert an idle zombie within the attraction radius (it investigates
    // the player's spot, same tick - stealth runs before the AI pass).
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 4 * 4 } } };
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    const z = w.spawnZombie(10, 70, 0, 40).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expect(!w.zombie_ai[zs].alert);
    // pipe_pistol_fire (stock V3.1.4): volume 62, 2 s = 40 ticks, muffle 0.8.
    w.pushStealthNoise(ps, 0, 70, 0, 62, 40, 0.8, 0);
    systemStealth(&w);
    // Radius = min(62 x 0.6, 40) = 37.2 covers 10 m; heard = 108.8 / 6.4 >= 1.
    try std.testing.expect(w.zombie_ai[zs].alert);
    try std.testing.expect(w.zombie_ai[zs].state == .chase);
    try std.testing.expect(w.zombie_ai[zs].has_spot);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w.zombie_ai[zs].spot_x, 0.01);
    // Ring consumed (consume-owns-drain), noise volume is the CalcVolume fold.
    try std.testing.expectEqual(@as(usize, 0), w.stealth_noise_n);
    try std.testing.expect(w.stealth[ps].noise_volume > 50.0);
}
test "stealth noise: crouch muffle scales the noise volume" {
    // RE AIDirector.NotifyNoise: a crouched instigator's volumeScale is
    // multiplied by the clip's muffled_when_crouched before the fold.
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // stepdirt (V3.1.4): volume 5, muffle 0.507.
    w.pushStealthNoise(ps, 0, 70, 0, 5, 20, 0.507, 0);
    systemStealth(&w);
    const standing = w.stealth[ps].noise_volume;
    // The entry itself is unfolded (5); the muffle scales the fold.
    try std.testing.expectApproxEqAbs(@as(f32, 5), w.stealth[ps].noises[0].volume, 0.001);
    w.stealth[ps] = .{};
    w.player[ps].crouching = true;
    w.pushStealthNoise(ps, 0, 70, 0, 5, 20, 0.507, 0);
    systemStealth(&w);
    const crouched = w.stealth[ps].noise_volume;
    try std.testing.expect(crouched < standing);
    // Entry volume carries the muffle: 5 x 0.507.
    try std.testing.expectApproxEqAbs(@as(f32, 5 * 0.507), w.stealth[ps].noises[0].volume, 0.001);
}
test "stealth light: pre-blend feeds the _lightlevel cvar" {
    // RE PlayerStealth TickServer IL_0078-00B9: ambient + held-light blend
    // (ratio clamped 0.5..3.2), crouch x0.6, then `_lightlevel = light x 100`
    // before the speed scale and passive blend.
    try std.testing.expectApproxEqAbs(@as(f32, 0), stealthLightPreBlend(0, 0, false), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), stealthLightPreBlend(0, 0, true), 0.0001);
    // Torch .35 on dark 0.05: ratio .35/.1 = 3.5 -> clamped 3.2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.05 + 0.35 * 3.2), stealthLightPreBlend(0.05, 0.35, false), 0.0001);
    // Crouch x0.6 on the blended value.
    try std.testing.expectApproxEqAbs(@as(f32, (0.5 + 0.0) * 0.6), stealthLightPreBlend(0.5, 0, true), 0.0001);
    // The full level still matches the old inline math at passive 1.
    try std.testing.expectApproxEqAbs(stealthLightLevel(0.5, 0, false, 1.0, 0), (0.32 + 0.68) * 0.5 * 100.0, 0.001);
}

test "stealth noise: cached NoiseMultiplier scales both volumes" {
    // RE PlayerStealth CalcVolume/NotifyNoise: each multiplies by GetValue(88
    // NoiseMultiplier). The survival tick caches the buff/perk/item fold in
    // stealth_noise_mult; the legs read the column, defaulting to the neutral
    // base 1.0 offline.
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Volume 20 >= the loud threshold (11), so the decay window pauses and the
    // accumulated posts are exact on both runs (CalcVolume never decays).
    w.pushStealthNoise(ps, 0, 70, 0, 20, 20, 1.0, 0);
    systemStealth(&w);
    const base_vol = w.stealth[ps].noise_volume;
    const base_sleep = w.stealth[ps].sleeper_noise_volume;
    try std.testing.expect(base_vol > 0);
    try std.testing.expect(base_sleep > 0);
    w.stealth[ps] = .{};
    w.stealth_noise_mult[ps] = 0.5;
    w.pushStealthNoise(ps, 0, 70, 0, 20, 20, 1.0, 0);
    systemStealth(&w);
    try std.testing.expectApproxEqAbs(base_vol * 0.5, w.stealth[ps].noise_volume, 0.001);
    try std.testing.expectApproxEqAbs(base_sleep * 0.5, w.stealth[ps].sleeper_noise_volume, 0.001);
}
test "stealth noise: sleeper-volume cap queues a volume wake, then decays" {
    // RE PlayerStealth.NotifyNoise: the curved volume accumulates into
    // sleeperNoiseVolume (cap 360 → World.CheckSleeperVolumeNoise) and decays
    // 2.5/tick once the loud-noise wait window elapses.
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Loud: volume 120 → eff = 60 + 60^1.4 ~ 368.5 > 360 → cap + wake.
    w.pushStealthNoise(ps, 0, 70, 0, 120, 80, 1.0, 0);
    systemStealth(&w);
    try std.testing.expectEqual(@as(f32, 360.0), w.stealth[ps].sleeper_noise_volume);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_volume_noise_n);
    // Loud noise holds the decay for the wait window (stock 20 ticks).
    for (0..10) |_| systemStealth(&w);
    try std.testing.expectEqual(@as(f32, 360.0), w.stealth[ps].sleeper_noise_volume);
    for (0..10) |_| systemStealth(&w);
    try std.testing.expect(w.stealth[ps].sleeper_noise_volume < 360.0);
    // Quiet noise (stepcloth 3 < loud 11) decays immediately: 3 - 2.5 = 0.5.
    w.stealth[ps] = .{};
    w.pushStealthNoise(ps, 0, 70, 0, 3, 20, 1.0, 0);
    systemStealth(&w);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), w.stealth[ps].sleeper_noise_volume, 0.001);
    systemStealth(&w);
    try std.testing.expectEqual(@as(f32, 0.0), w.stealth[ps].sleeper_noise_volume);
}
test "stealth noise: a sleeping zombie that hears wakes" {
    // RE PlayerStealth attraction: a sleeping zombie inside the attraction
    // radius that passes the heard test wakes and investigates (the separate
    // 360-cap volume wake covers whole volumes).
    var w: World = .{ .rules = .{ .ai = .{ .sense_dist_sq = 4 * 4 } } };
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    const z = w.spawnSleeperDef(5, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie }, 0).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expect(!w.sleeper[zs].awake);
    // stepbush (V3.1.4): volume 11 - radius 6.6 covers 5 m, heard ~ 7 >= 1.
    w.pushStealthNoise(ps, 0, 70, 0, 11, 60, 0.507, 0);
    systemStealth(&w);
    try std.testing.expect(w.sleeper[zs].awake);
    try std.testing.expectEqual(@as(usize, 1), w.sleeper_wake_n);
    try std.testing.expectEqual(zs, w.sleeper_wake_reqs[0].slot);
}
test "stealth noise: heat rows feed the activity map" {
    // RE AIDirector.NotifyNoise: heat_map_strength > 0 adds activity to the
    // heat map for the region, held for the fixed 240 s window NotifyNoise
    // passes (the row's heat_map_time is not read by stock at all).
    var w: World = .{};
    defer w.deinit();
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Auger_Fire_Start (V3.1.4): volume 60, 2 s, heat 1.0.
    w.pushStealthNoise(ps, 0, 70, 0, 60, 40, 1.0, 1.0);
    systemStealth(&w);
    try std.testing.expectEqual(@as(usize, 1), w.director.heat_n);
    // notifyActivity: activity = value, decay = value / (duration_ticks / 20)
    // per second - 240 s = 4800 ticks → 1.0 / 240 s.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w.director.heat[0].activity, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 240.0), w.director.heat[0].decay, 0.0001);
}
