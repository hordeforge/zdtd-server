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
