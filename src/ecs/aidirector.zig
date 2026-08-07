//! Lightweight AIDirector as ECS resource (world clock, horde, blood moon).

const std = @import("std");
const ecs_world = @import("world.zig");

pub const WorldClock = struct {
    hours: f32 = 8.0,
    day: u32 = 1,
    seconds_per_hour: f32 = 30.0,
    /// Daylight window [dawn, dusk); night is outside it. From DayLightLength:
    /// dawn fixed at 04:00, dusk = 4 + DayLightLength (stock keeps morning fixed).
    dawn: f32 = 4.0,
    dusk: f32 = 22.0,
    /// BloodMoonFrequency: blood moon every N days (0 disables).
    bloodmoon_frequency: u32 = 7,
    /// BloodMoonRange: deterministic ±day jitter around each frequency multiple.
    bloodmoon_range: u8 = 0,

    /// Real seconds per in-game hour from DayNightLength (real minutes per day).
    pub fn setDayNightLength(self: *WorldClock, minutes_per_day: u16) void {
        self.seconds_per_hour = @as(f32, @floatFromInt(minutes_per_day)) * 60.0 / 24.0;
    }

    pub fn setDayLightLength(self: *WorldClock, daylight_hours: u8) void {
        // Stock GameUtils::CalcDuskDawnHours (asm.il 1926249): a DayLightLength
        // of 0 or 24 returns (dusk 22, dawn 4); otherwise dusk starts at 22,
        // clamps to DayLightLength when > 22, becomes 12 + DL/2 when < 18, and
        // dawn = clamp(dusk - DL, 0, 23).
        const dl = daylight_hours;
        if (dl == 0 or dl == 24) {
            self.dawn = 4.0;
            self.dusk = 22.0;
            return;
        }
        var dusk: f32 = 22.0;
        if (dl > 22) dusk = @floatFromInt(dl);
        if (dl < 18) dusk = 12.0 + @as(f32, @floatFromInt(dl)) / 2.0;
        var dawn: f32 = dusk - @as(f32, @floatFromInt(dl));
        if (dawn < 0) dawn = 0;
        if (dawn > 23) dawn = 23;
        self.dusk = dusk;
        self.dawn = dawn;
    }

    pub fn tick(self: *WorldClock, dt: f32) void {
        self.hours += dt / self.seconds_per_hour;
        while (self.hours >= 24.0) {
            self.hours -= 24.0;
            self.day +%= 1;
        }
    }

    pub fn isNight(self: *const WorldClock) bool {
        return self.hours < self.dawn or self.hours >= self.dusk;
    }

    /// Stock GameUtils::IsBloodMoonTime (asm.il 1926341): the blood moon spans
    /// dusk on the scheduled day through dawn of the next day, crossing the
    /// midnight rollover. True when the current day is the scheduled day and it
    /// is at/after dusk, or the day after the scheduled day before dawn.
    pub fn isBloodMoonNight(self: *const WorldClock) bool {
        if (self.bloodmoon_frequency == 0) return false;
        if (self.hours >= self.dusk) return self.isBloodMoonDay(self.day);
        if (self.hours < self.dawn and self.day > 1) return self.isBloodMoonDay(self.day - 1);
        return false;
    }

    fn isBloodMoonDay(self: *const WorldClock, day: u32) bool {
        if (self.bloodmoon_range == 0) return day % self.bloodmoon_frequency == 0;
        // Blood moon day = c*freq + jitter(c), jitter deterministic in [0, range].
        // A given day may match the target of an adjacent cycle (jitter can push a
        // blood moon across the c*freq boundary), so test the neighbouring cycles.
        const base = day / self.bloodmoon_frequency;
        const lo = if (base == 0) 0 else base - 1;
        var c = lo;
        while (c <= base + 1) : (c += 1) {
            if (self.bloodMoonDayForCycle(c) == day) return true;
        }
        return false;
    }

    fn bloodMoonDayForCycle(self: *const WorldClock, cycle: u32) i64 {
        // Stock CalcNextDay (asm.il 412880): bmDayLast + frequency +
        // RandomRange(0, range+1) — the jitter is non-negative, so a blood moon
        // is never early relative to the frequency multiple.
        const span: u32 = @as(u32, self.bloodmoon_range) + 1;
        const jitter: i64 = @as(i64, @intCast((cycle *% 2654435761) % span));
        return @as(i64, cycle) * @as(i64, self.bloodmoon_frequency) + jitter;
    }

    /// The scheduled blood-moon day for the client's stat 58 (GameStats
    /// BloodMoonDay): the horde day of the active cycle — the next jittered
    /// cycle day at/after `today`. NOT the plain frequency multiple: with
    /// BloodMoonRange jitter the horde can land on day c*freq+1, and the old
    /// multiple put the client's red moon on the wrong night (a non-horde
    /// multiple lit up, the actual horde night showed nothing). Cycle 0 is
    /// pre-game; the first horde is cycle 1.
    pub fn bloodMoonDayFor(self: *const WorldClock, today: u32) i32 {
        if (self.bloodmoon_frequency == 0) return 0;
        const base: i64 = @intCast(@max(1, today / self.bloodmoon_frequency));
        var c: i64 = base;
        while (true) : (c += 1) {
            const day = self.bloodMoonDayForCycle(@intCast(c));
            if (day >= today) return @intCast(day);
        }
    }

    /// Stock DayTimeToWorldTime: (day-1)*24000 + hours*1000 (+ minutes*1000/60).
    /// Day 1 spans [0, 24000); WorldTimeToDays(wt) = wt/24000 + 1. A day-0
    /// clock (test convention) encodes as 0 rather than underflowing.
    pub fn worldTimeBits(self: *const WorldClock) u64 {
        const d: u64 = if (self.day > 0) self.day - 1 else 0;
        const day_part: u64 = d * 24000;
        const hour_part: u64 = @intFromFloat(self.hours * 1000.0);
        return day_part + hour_part;
    }
};

/// Resolved gamestages.xml `<spawn>` row: which entitygroup, and how many.
pub const StageGroup = struct {
    group: []const u8 = "",
    num: u16 = 1,
    max_alive: u16 = 1,
};

/// AIDirectorChunkEventComponent::SpawnScouts (asm.il ~415972): the scout
/// `<entityspawner>` is picked purely by party game stage at 45 / 85 / 125.
pub fn scoutSpawnerName(party_stage: i32) []const u8 {
    if (party_stage < 45) return "Scouts1";
    if (party_stage < 85) return "Scouts2";
    if (party_stage < 125) return "ScoutsFeral";
    return "ScoutsRadiated";
}

/// AIDirectorBloodMoonParty constants (asm.il 413090-413140): players within
/// 80 m join one party; horde zombies beyond 150 m teleport back; waves spawn
/// ~40 m from the focus; the per-party alive ceiling is cPartyEnemyMax 30.
pub const party_join_dist: f32 = 80.0;
pub const party_teleport_dist: f32 = 150.0;
pub const party_spawn_dist: f32 = 40.0;
pub const party_enemy_max: u32 = 30;
pub const max_bm_parties: usize = 8;

pub const BmParty = struct {
    focus_x: f32 = 0,
    focus_z: f32 = 0,
    members: u32 = 0,
    /// Horde zombies currently alive for this party (recounted each BM tick).
    alive: u32 = 0,
};

pub const Director = struct {
    /// Spawn-group kind for per-biome resolution (spawning.xml rule kind).
    pub const SpawnKind = enum(u8) { night = 0, day = 1, animal = 2 };

    clock: WorldClock = .{},
    horde_cd: f32 = 0,
    /// Entity group names from spawning.xml (empty → class_table rotation).
    night_group: []const u8 = "",
    day_group: []const u8 = "",
    animal_group: []const u8 = "",
    /// Optional pick: (ctx, group_name, seed) → class name; Game wires entitygroups.
    group_pick_ctx: ?*anyopaque = null,
    group_pick_fn: ?*const fn (?*anyopaque, []const u8, u32) ?[]const u8 = null,
    /// Per-player biome spawn-group resolver: (ctx, x, z, kind, fallback) →
    /// the group NAME for the biome under the spawn point (night/day/animal),
    /// or the fallback when the biome/rule is unknown. Game wires spawning.xml.
    biome_group_ctx: ?*anyopaque = null,
    biome_group_fn: ?*const fn (?*anyopaque, f32, f32, SpawnKind, []const u8) []const u8 = null,

    /// Party game stage (CalcGameStageAround over the online players). Drives
    /// the scout tier and the blood moon stage lookup. 0 = no players / unknown.
    party_stage: i32 = 0,
    /// Optional lookup: (ctx, spawner_name, stage) → entitygroup name plus wave
    /// size, resolving gamestages.xml. Game wires it; the ECS layer stays free
    /// of asset imports, matching the group_pick_fn contract above.
    stage_group_ctx: ?*anyopaque = null,
    stage_group_fn: ?*const fn (?*anyopaque, []const u8, i32) ?StageGroup = null,
    /// Optional lookup: (ctx, entityspawner_name) → EntityGroupName from
    /// spawning.xml, for the code-named scout spawners.
    spawner_group_ctx: ?*anyopaque = null,
    spawner_group_fn: ?*const fn (?*anyopaque, []const u8) ?[]const u8 = null,
    bloodmoon_cd: f32 = 0,
    scouts_cd: f32 = 0,
    total_spawned: u32 = 0,
    bloodmoon_active: bool = false,
    /// Blood-moon party state (AIDirectorBloodMoonParty, 413090-413140):
    /// players within cPartyJoinDistance 80 m share one focus and one
    /// per-party wave; the party gamestage is frozen for the night; horde
    /// zombies beyond cTeleportDist 150 m are teleported back.
    bm_parties: [max_bm_parties]BmParty = [_]BmParty{.{}} ** max_bm_parties,
    bm_party_n: u8 = 0,
    /// Party gamestage snapshot at dusk (stock InitParty freezes it).
    bm_stage_frozen: i32 = 0,
    /// Alive-zombie ceiling (MaxSpawnedZombies). Defaults to the dev cap; the
    /// operator's serverconfig raises it. See default_max_alive_zombies.
    max_alive: u32 = default_max_alive_zombies,
    /// GameDifficulty 0..5; scales zombie hp (proxy for stock damage scaling).
    difficulty: u8 = 2,
    /// ZombieMove / ZombieMoveNight / ZombieFeralMove / ZombieBMMove indices 0..4.
    zombie_move_day: u8 = 0,
    zombie_move_night: u8 = 3,
    zombie_move_feral: u8 = 3,
    zombie_move_bm: u8 = 3,
    /// EnemyDifficulty: 0 = normal, 1 = feral (use feral speed at all times).
    enemy_difficulty: u8 = 0,
    /// BloodMoonEnemyCount: zombies per blood-moon wave (per spawn burst).
    bloodmoon_enemy_count: u8 = 8,
    /// BloodMoonRange: deterministic ±day jitter around the frequency multiple.
    bloodmoon_range: u8 = 0,
    /// MaxSpawnedAnimals: daytime wildlife cap (0 disables animal spawning).
    max_alive_animals: u32 = 0,
    animals_cd: f32 = 0,

    /// Alive-zombie ceiling: stock MaxSpawnedZombies default is 64; we keep a
    /// smaller dev cap so long soaks do not accrete entities without despawn.
    pub const default_max_alive_zombies: u32 = 24;

    /// Zombie hp multiplier from GameDifficulty (0=Scavenger .. 5=Insane).
    pub fn hpScale(self: *const Director) f32 {
        return switch (self.difficulty) {
            0 => 0.5,
            1 => 0.75,
            2 => 1.0,
            3 => 1.25,
            4 => 1.5,
            else => 2.0,
        };
    }

    /// ZombieMove index 0..4 → speed multiplier (walk/jog/run/sprint/nightmare).
    fn moveScale(idx: u8) f32 {
        return switch (idx) {
            0 => 0.5,
            1 => 0.75,
            2 => 1.0,
            3 => 1.4,
            else => 1.7,
        };
    }

    /// Current zombie speed multiplier for the active day/night/blood-moon state.
    pub fn zombieSpeedScale(self: *const Director) f32 {
        if (self.bloodmoon_active) return moveScale(self.zombie_move_bm);
        if (self.enemy_difficulty >= 1) return moveScale(self.zombie_move_feral);
        return moveScale(if (self.clock.isNight()) self.zombie_move_night else self.zombie_move_day);
    }

    pub fn tick(self: *Director, w: *ecs_world.World, dt: f32) struct { spawned: u32, world_time: u64 } {
        const day_before = self.clock.day;
        self.clock.tick(dt);
        var spawned: u32 = 0;

        if (self.horde_cd > 0) self.horde_cd -= dt;
        if (self.bloodmoon_cd > 0) self.bloodmoon_cd -= dt;
        if (self.scouts_cd > 0) self.scouts_cd -= dt;
        if (self.animals_cd > 0) self.animals_cd -= dt;

        self.bloodmoon_active = self.clock.isBloodMoonNight();
        w.zombie_speed_scale = self.zombieSpeedScale();
        const alive_z = w.countKind(.zombie);
        if (alive_z >= self.max_alive) {
            // Daily trader restock still runs below; skip spawn branches.
            if (self.clock.day != day_before) {
                @import("systems.zig").traderRestock(w);
            }
            return .{ .spawned = 0, .world_time = self.clock.worldTimeBits() };
        }

        if (self.clock.isNight() and self.horde_cd <= 0) {
            spawned += self.spawnNearPlayers(w, 2, 18.0, 28.0, "");
            self.horde_cd = if (self.bloodmoon_active) 8.0 else 45.0;
        }
        if (self.bloodmoon_active and self.bloodmoon_cd <= 0) {
            // Freeze the party gamestage at dusk (InitParty): the ladder and
            // the horde size stay fixed for the whole night.
            if (self.bm_stage_frozen == 0) self.bm_stage_frozen = self.party_stage;
            self.buildBloodMoonParties(w);
            self.recountAndTeleportHorde(w);
            const bm = self.stageGroup(bloodmoon_spawner);
            var wave: u32 = @max(1, self.bloodmoon_enemy_count / 2);
            var bm_group: []const u8 = "";
            if (bm) |sg| {
                wave = @min(wave, @max(1, @as(u32, sg.max_alive)));
                bm_group = sg.group;
            }
            spawned += self.spawnBloodMoonParties(w, wave, bm_group);
            self.bloodmoon_cd = 6.0;
        } else if (!self.bloodmoon_active and self.bm_stage_frozen != 0) {
            // EndBloodMoon (412618): clear horde marks and the frozen stage at
            // dawn; nothing is despawned.
            self.bm_stage_frozen = 0;
            clearHordeMarks(w);
        }
        // Horde zombies keep to their party focus every tick (teleport back
        // past cTeleportDist) so a 2+ player horde cannot split.
        if (self.bloodmoon_active) {
            self.buildBloodMoonParties(w);
            self.recountAndTeleportHorde(w);
        }
        if (!self.clock.isNight() and self.scouts_cd <= 0) {
            spawned += self.spawnNearPlayers(w, 1, 30.0, 40.0, self.scoutGroup());
            self.scouts_cd = 120.0;
        }
        // Daytime wildlife up to MaxSpawnedAnimals (wander, not chase).
        if (self.max_alive_animals > 0 and !self.clock.isNight() and self.animals_cd <= 0) {
            if (w.countKind(.animal) < self.max_alive_animals) {
                spawned += self.spawnAnimalsNearPlayers(w, 1, 20.0, 45.0);
            }
            self.animals_cd = 60.0;
        }
        // Daily trader restock when day rolls.
        if (self.clock.day != day_before) {
            @import("systems.zig").traderRestock(w);
        }

        self.total_spawned +%= spawned;
        return .{ .spawned = spawned, .world_time = self.clock.worldTimeBits() };
    }

    fn spawnAnimalsNearPlayers(self: *Director, w: *ecs_world.World, count: u32, min_r: f32, max_r: f32) u32 {
        var n: u32 = 0;
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities and n < count) : (p += 1) {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            const ang = @as(f32, @floatFromInt(self.total_spawned +% n)) * 2.3;
            const r = min_r + (max_r - min_r) * @mod(ang, 1.0);
            const x = w.transform[p].x + @cos(ang) * r;
            const z = w.transform[p].z + @sin(ang) * r;
            const y = w.transform[p].y;
            // Wildlife group per player biome (fallback = the single group).
            var animal_ct: ?ecs_world.EntityClass = null;
            var agroup = self.animal_group;
            if (self.biome_group_fn) |bf| agroup = bf(self.biome_group_ctx, x, z, .animal, self.animal_group);
            if (agroup.len > 0) {
                if (self.group_pick_fn) |pick| {
                    if (pick(self.group_pick_ctx, agroup, self.total_spawned)) |cname| {
                        for (w.class_table) |ct| {
                            if (ct.kind == .animal and std.mem.eql(u8, ct.name, cname)) {
                                animal_ct = ct;
                                break;
                            }
                        }
                    }
                }
            }
            if (animal_ct == null) {
                for (w.class_table) |ct| {
                    if (ct.kind == .animal and ct.hash != 0) {
                        animal_ct = ct;
                        break;
                    }
                }
            }
            const hp: f32 = if (animal_ct) |ct| ct.max_hp else 30;
            const id = if (animal_ct) |ct|
                w.spawnAnimal(x, y, z, hp, ct.hash, ct.loot_list)
            else
                w.spawnAnimal(x, y, z, hp, 0, "");
            const nid = id orelse break;
            if (w.slotOfNetId(nid)) |slot| {
                w.zombie_ai[slot].state = .wander; // wildlife roams, does not hunt
                n += 1;
            }
        }
        return n;
    }

    /// gamestages.xml spawner name the blood moon draws from.
    pub const bloodmoon_spawner = "BloodMoonHorde";

    /// Resolve a gamestages.xml spawner at the current party stage (the
    /// blood-moon ladder reads the night-frozen stage once set).
    fn stageGroup(self: *const Director, spawner: []const u8) ?StageGroup {
        const f = self.stage_group_fn orelse return null;
        const stage = if (self.bm_stage_frozen != 0) self.bm_stage_frozen else self.party_stage;
        const sg = f(self.stage_group_ctx, spawner, stage) orelse return null;
        if (sg.group.len == 0) return null;
        return sg;
    }

    /// Daytime scout entity group for the current party stage; empty when the
    /// spawning.xml entityspawner table is unavailable.
    fn scoutGroup(self: *const Director) []const u8 {
        const f = self.spawner_group_fn orelse return "";
        return f(self.spawner_group_ctx, scoutSpawnerName(self.party_stage)) orelse "";
    }

    /// `group_override` wins over the day/night spawning.xml groups; empty
    /// keeps the existing biome-rule behaviour.
    fn spawnNearPlayers(self: *Director, w: *ecs_world.World, count: u32, min_r: f32, max_r: f32, group_override: []const u8) u32 {
        var n: u32 = 0;
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities and n < count) : (p += 1) {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            var k: u32 = 0;
            while (k < count and n < count) : (k += 1) {
                const ang = @as(f32, @floatFromInt(k + n)) * 1.7;
                const r = min_r + (max_r - min_r) * (@mod(ang, 1.0));
                const x = w.transform[p].x + @cos(ang) * r;
                const z = w.transform[p].z + @sin(ang) * r;
                const y = w.transform[p].y;
                const slot = self.spawnOneZombie(w, x, y, z, group_override, self.total_spawned +% n, false) orelse break;
                w.zombie_ai[slot].state = .chase;
                w.zombie_ai[slot].target_id = w.network_id[p].id;
                w.zombie_ai[slot].alert = true;
                n += 1;
            }
        }
        return n;
    }

    /// Cluster online players into blood-moon parties: anyone within
    /// cPartyJoinDistance (80 m) of an existing party focus joins it (focus =
    /// running average); stragglers open new parties (cap max_bm_parties).
    fn buildBloodMoonParties(self: *Director, w: *ecs_world.World) void {
        self.bm_parties = [_]BmParty{.{}} ** max_bm_parties;
        self.bm_party_n = 0;
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities) : (p += 1) {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            const x = w.transform[p].x;
            const z = w.transform[p].z;
            var joined = false;
            for (self.bm_parties[0..self.bm_party_n]) |*party| {
                const dx = party.focus_x - x;
                const dz = party.focus_z - z;
                if (dx * dx + dz * dz > party_join_dist * party_join_dist) continue;
                const m: f32 = @floatFromInt(party.members);
                party.focus_x = (party.focus_x * m + x) / (m + 1.0);
                party.focus_z = (party.focus_z * m + z) / (m + 1.0);
                party.members += 1;
                joined = true;
                break;
            }
            if (joined or self.bm_party_n >= max_bm_parties) continue;
            const np = &self.bm_parties[self.bm_party_n];
            np.* = .{ .focus_x = x, .focus_z = z, .members = 1 };
            self.bm_party_n += 1;
        }
    }

    /// One pass over horde zombies per blood-moon tick: recount each party's
    /// alive set (stock OnEntityUnloaded accounting) and teleport a drifter
    /// back to its party focus once it passes cTeleportDist (150 m).
    fn recountAndTeleportHorde(self: *Director, w: *ecs_world.World) void {
        for (self.bm_parties[0..self.bm_party_n]) |*party| party.alive = 0;
        if (self.bm_party_n == 0) return;
        const tel2 = party_teleport_dist * party_teleport_dist;
        var s: ecs_world.Slot = 0;
        while (s < ecs_world.max_entities) : (s += 1) {
            if (!w.alive[s] or !w.zombie_ai[s].is_horde) continue;
            const x = w.transform[s].x;
            const z = w.transform[s].z;
            var best_d2: f32 = std.math.floatMax(f32);
            var best_i: usize = 0;
            for (self.bm_parties[0..self.bm_party_n], 0..) |*party, i| {
                const dx = party.focus_x - x;
                const dz = party.focus_z - z;
                const d2 = dx * dx + dz * dz;
                if (d2 < best_d2) {
                    best_d2 = d2;
                    best_i = i;
                }
            }
            self.bm_parties[best_i].alive += 1;
            if (best_d2 <= tel2) continue;
            const focus = &self.bm_parties[best_i];
            const ang = @as(f32, @floatFromInt(s)) * 2.399963; // ~120 degree steps
            const nx = focus.focus_x + @cos(ang) * party_spawn_dist;
            const nz = focus.focus_z + @sin(ang) * party_spawn_dist;
            w.setPos(w.network_id[s].id, nx, w.transform[s].y, nz, 0);
        }
    }

    /// EndBloodMoon: clear IsHordeZombie on every living zombie (412618).
    fn clearHordeMarks(w: *ecs_world.World) void {
        var s: ecs_world.Slot = 0;
        while (s < ecs_world.max_entities) : (s += 1) {
            if (w.alive[s]) w.zombie_ai[s].is_horde = false;
        }
    }

    /// Spawn one wave per party around its focus (cSpawnDistance 40 + up to
    /// 10 jitter), marked horde, capped per party at
    /// min(cPartyEnemyMax 30, BloodMoonEnemyCount x members). One shared wave
    /// per party instead of one per player: 2 players in range get one horde.
    fn spawnBloodMoonParties(self: *Director, w: *ecs_world.World, wave: u32, group: []const u8) u32 {
        var n: u32 = 0;
        for (self.bm_parties[0..self.bm_party_n]) |*party| {
            const cap = @min(party_enemy_max, @as(u32, self.bloodmoon_enemy_count) * party.members);
            var k: u32 = 0;
            while (k < wave and party.alive < cap and n < wave * self.bm_party_n) : (k += 1) {
                const ang = @as(f32, @floatFromInt(self.total_spawned +% n)) * 2.399963;
                const r = party_spawn_dist + @mod(ang, 1.0) * 10.0;
                const x = party.focus_x + @cos(ang) * r;
                const z = party.focus_z + @sin(ang) * r;
                const y = nearestPlayerY(w, x, z) orelse continue;
                const slot = self.spawnOneZombie(w, x, y, z, group, self.total_spawned +% n, true) orelse continue;
                if (nearestPlayerSlot(w, x, z)) |ps| {
                    w.zombie_ai[slot].state = .chase;
                    w.zombie_ai[slot].target_id = w.network_id[ps].id;
                    w.zombie_ai[slot].alert = true;
                }
                party.alive += 1;
                n += 1;
            }
        }
        return n;
    }

    /// Pick the group class at (x,z) and spawn one zombie; mark horde when
    /// requested. Shared by the per-player ring and the party spawner.
    fn spawnOneZombie(self: *Director, w: *ecs_world.World, x: f32, y: f32, z: f32, group_override: []const u8, seed: u32, mark_horde: bool) ?ecs_world.Slot {
        var ct = w.class_table[1];
        const fallback = if (self.clock.isNight()) self.night_group else self.day_group;
        const grp = if (group_override.len > 0)
            group_override
        else if (self.biome_group_fn) |bf|
            bf(self.biome_group_ctx, x, z, if (self.clock.isNight()) .night else .day, fallback)
        else
            fallback;
        if (grp.len > 0) {
            if (self.group_pick_fn) |pick| {
                if (pick(self.group_pick_ctx, grp, seed)) |cname| {
                    for (w.class_table) |slot_ct| {
                        if (slot_ct.kind == .zombie and std.mem.eql(u8, slot_ct.name, cname)) {
                            ct = slot_ct;
                            break;
                        }
                    }
                }
            }
        } else {
            const zombie_slots = [_]usize{ 1, 8, 9, 10, 11 };
            const csel = zombie_slots[seed % zombie_slots.len];
            if (w.class_table[csel].hash != 0 and w.class_table[csel].kind == .zombie) {
                ct = w.class_table[csel];
            }
        }
        const bm_mul: f32 = if (self.bloodmoon_active) 1.5 else 1.0;
        const hp: f32 = ct.max_hp * bm_mul * self.hpScale();
        const id = if (ct.hash != 0)
            w.spawnZombieClass(x, y, z, hp, ct.hash, ct.loot_list)
        else
            w.spawnZombie(x, y, z, hp);
        const nid = id orelse return null;
        const slot = w.slotOfNetId(nid) orelse return null;
        if (mark_horde) w.zombie_ai[slot].is_horde = true;
        return slot;
    }

    /// Y of the nearest online player to (x,z), or null with no players.
    fn nearestPlayerY(w: *ecs_world.World, x: f32, z: f32) ?f32 {
        const s = nearestPlayerSlot(w, x, z) orelse return null;
        return w.transform[s].y;
    }

    fn nearestPlayerSlot(w: *ecs_world.World, x: f32, z: f32) ?ecs_world.Slot {
        var best: ?ecs_world.Slot = null;
        var best_d2: f32 = std.math.floatMax(f32);
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities) : (p += 1) {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            const dx = w.transform[p].x - x;
            const dz = w.transform[p].z - z;
            const d2 = dx * dx + dz * dz;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = p;
            }
        }
        return best;
    }
};

test "clock advances and bloodmoon spans dusk to dawn across rollover" {
    // BM day 7: the horde runs day 7 22:00 (dusk) through day 8 04:00 (dawn),
    // including the midnight day rollover (stock IsBloodMoonTime).
    var cl: WorldClock = .{ .hours = 21.0, .day = 7, .seconds_per_hour = 1.0 };
    try std.testing.expect(!cl.isBloodMoonNight()); // before dusk
    cl.tick(2.0); // 23:00 day 7: at/after dusk
    try std.testing.expectEqual(@as(u32, 7), cl.day);
    try std.testing.expect(cl.isBloodMoonNight());
    cl.tick(3.0); // 02:00 day 8: after the rollover, before dawn
    try std.testing.expectEqual(@as(u32, 8), cl.day);
    try std.testing.expect(cl.isBloodMoonNight());
    cl.tick(3.0); // 05:00 day 8: dawn passed
    try std.testing.expect(!cl.isBloodMoonNight());
}

test "worldTimeBits encodes stock day 1 as zero offset" {
    var cl: WorldClock = .{ .hours = 8.0, .day = 1, .seconds_per_hour = 1.0 };
    // Stock DayTimeToWorldTime: (day-1)*24000 + hours*1000; WorldTimeToDays
    // (wt/24000 + 1) must round-trip the wire day.
    const wt = cl.worldTimeBits();
    try std.testing.expectEqual(@as(u64, 8000), wt);
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(wt / 24000 + 1)));
    cl.day = 7;
    cl.hours = 12.0;
    try std.testing.expectEqual(@as(u64, 6 * 24000 + 12000), cl.worldTimeBits());
    try std.testing.expectEqual(@as(u32, 7), @as(u32, @intCast(cl.worldTimeBits() / 24000 + 1)));
}

test "director spawns at night near player ecs" {
    var w: ecs_world.World = .{};
    var dir: Director = .{ .clock = .{ .hours = 23.0, .day = 1, .seconds_per_hour = 1.0 }, .horde_cd = 0 };
    _ = w.spawnPlayer(0, 70, 0, 0);
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(r.spawned >= 1);
    try std.testing.expect(dir.total_spawned >= 1);
}

test "zombie speed scale follows day/night/bloodmoon config" {
    // Day = walk (0 → 0.5), night = sprint (3 → 1.4), blood moon = bm setting.
    var dir: Director = .{
        .zombie_move_day = 0,
        .zombie_move_night = 3,
        .zombie_move_bm = 4,
        .zombie_move_feral = 2,
    };
    dir.clock.hours = 12.0; // day
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dir.zombieSpeedScale(), 0.001);
    dir.clock.hours = 23.0; // night
    try std.testing.expectApproxEqAbs(@as(f32, 1.4), dir.zombieSpeedScale(), 0.001);
    dir.bloodmoon_active = true;
    try std.testing.expectApproxEqAbs(@as(f32, 1.7), dir.zombieSpeedScale(), 0.001);
    dir.bloodmoon_active = false;
    dir.enemy_difficulty = 1; // feral overrides day
    dir.clock.hours = 12.0;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dir.zombieSpeedScale(), 0.001);
}

test "director spawns daytime animals up to cap" {
    var w: ecs_world.World = .{};
    // Noon, animal cap 3, no zombie horde interference (day).
    var dir: Director = .{
        .clock = .{ .hours = 12.0, .day = 1, .seconds_per_hour = 1.0 },
        .max_alive_animals = 3,
        .scouts_cd = 999, // suppress daytime scout zombie
    };
    _ = w.spawnPlayer(0, 70, 0, 0);
    // Each tick spawns at most one animal (60s cooldown), so drive several with
    // the cooldown reset to reach the cap.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        dir.animals_cd = 0;
        _ = dir.tick(&w, 0.1);
    }
    const animals = w.countKind(.animal);
    try std.testing.expect(animals >= 1);
    try std.testing.expect(animals <= 3); // never exceeds MaxSpawnedAnimals
}

test "bloodmoon frequency and range" {
    // Frequency 0 disables entirely.
    var cl: WorldClock = .{ .hours = 23.0, .day = 7, .bloodmoon_frequency = 0 };
    try std.testing.expect(!cl.isBloodMoonNight());
    // Frequency 7, range 0: exact multiples at night.
    cl = .{ .hours = 23.0, .day = 14, .bloodmoon_frequency = 7 };
    try std.testing.expect(cl.isBloodMoonNight());
    cl.day = 13;
    try std.testing.expect(!cl.isBloodMoonNight());
    // Range shifts the blood moon off the exact multiple; some day in each
    // cycle window must trigger, and daytime never does.
    cl = .{ .hours = 12.0, .day = 14, .bloodmoon_frequency = 7, .bloodmoon_range = 2 };
    try std.testing.expect(!cl.isBloodMoonNight()); // daytime
    var hits: u32 = 0;
    var d: u32 = 5;
    while (d <= 9) : (d += 1) {
        cl = .{ .hours = 23.0, .day = d, .bloodmoon_frequency = 7, .bloodmoon_range = 2 };
        if (cl.isBloodMoonNight()) hits += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), hits); // exactly one blood moon in cycle 1's window
}

test "scout spawner tier follows the stock gamestage thresholds" {
    // SpawnScouts (asm.il ~415972): >=45 Scouts2, >=85 ScoutsFeral, >=125 radiated.
    try std.testing.expectEqualStrings("Scouts1", scoutSpawnerName(0));
    try std.testing.expectEqualStrings("Scouts1", scoutSpawnerName(44));
    try std.testing.expectEqualStrings("Scouts2", scoutSpawnerName(45));
    try std.testing.expectEqualStrings("Scouts2", scoutSpawnerName(84));
    try std.testing.expectEqualStrings("ScoutsFeral", scoutSpawnerName(85));
    try std.testing.expectEqualStrings("ScoutsFeral", scoutSpawnerName(124));
    try std.testing.expectEqualStrings("ScoutsRadiated", scoutSpawnerName(125));
    try std.testing.expectEqualStrings("ScoutsRadiated", scoutSpawnerName(std.math.maxInt(i32)));
    // A negative stage cannot come out of partyLevel but must not trap.
    try std.testing.expectEqualStrings("Scouts1", scoutSpawnerName(std.math.minInt(i32)));
}

test "director draws the daytime scout group from the stage tier" {
    const Hooks = struct {
        var asked: [64]u8 = undefined;
        var asked_len: usize = 0;
        fn spawnerGroup(_: ?*anyopaque, name: []const u8) ?[]const u8 {
            asked_len = @min(name.len, asked.len);
            @memcpy(asked[0..asked_len], name[0..asked_len]);
            return "ZombieScoutsFeral";
        }
        fn pick(_: ?*anyopaque, group: []const u8, _: u32) ?[]const u8 {
            if (std.mem.eql(u8, group, "ZombieScoutsFeral")) return "zombieJoe";
            return null;
        }
    };
    var w: ecs_world.World = .{};
    _ = w.spawnPlayer(0, 70, 0, 0);
    var dir: Director = .{
        .clock = .{ .hours = 12.0, .day = 1, .seconds_per_hour = 1.0 },
        .party_stage = 90,
        .spawner_group_fn = &Hooks.spawnerGroup,
        .group_pick_fn = &Hooks.pick,
    };
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(r.spawned >= 1);
    try std.testing.expectEqualStrings("ScoutsFeral", Hooks.asked[0..Hooks.asked_len]);
}

test "blood moon wave size is capped by the stage maxAlive" {
    const Hooks = struct {
        var seen_stage: i32 = -1;
        fn stageGroup(_: ?*anyopaque, spawner: []const u8, stage: i32) ?StageGroup {
            if (!std.mem.eql(u8, spawner, Director.bloodmoon_spawner)) return null;
            seen_stage = stage;
            return .{ .group = "ZombiesNight", .num = 300, .max_alive = 2 };
        }
    };
    var w: ecs_world.World = .{};
    _ = w.spawnPlayer(0, 70, 0, 0);
    // Blood moon night with a generous BloodMoonEnemyCount; maxAlive=2 wins.
    var dir: Director = .{
        .clock = .{ .hours = 23.0, .day = 7, .seconds_per_hour = 1.0 },
        .bloodmoon_enemy_count = 40,
        .party_stage = 61,
        .horde_cd = 999, // isolate the blood moon branch from the night horde
        .stage_group_fn = &Hooks.stageGroup,
    };
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(dir.bloodmoon_active);
    try std.testing.expectEqual(@as(i32, 61), Hooks.seen_stage);
    try std.testing.expect(r.spawned >= 1);
    try std.testing.expect(r.spawned <= 2);
}

test "director without stage hooks keeps its unstaged behaviour" {
    var w: ecs_world.World = .{};
    _ = w.spawnPlayer(0, 70, 0, 0);
    var dir: Director = .{
        .clock = .{ .hours = 23.0, .day = 7, .seconds_per_hour = 1.0 },
        .bloodmoon_enemy_count = 8,
        .horde_cd = 999,
    };
    const r = dir.tick(&w, 0.1);
    try std.testing.expect(dir.bloodmoon_active);
    try std.testing.expectEqual(@as(u32, 4), r.spawned); // BloodMoonEnemyCount / 2
}

test "bloodMoonDayFor returns the jittered horde day, not the multiple" {
    // freq 7, range 1: jitter(1) = (1*2654435761) % 2 = 1, so the first horde
    // is day 8. The old "next frequency multiple" logic said 7, lighting the
    // client's red moon on a non-horde night and showing nothing on day 8.
    var cl: WorldClock = .{ .hours = 8.0, .day = 1, .bloodmoon_frequency = 7, .bloodmoon_range = 1 };
    try std.testing.expectEqual(@as(i32, 8), cl.bloodMoonDayFor(1)); // upcoming
    try std.testing.expectEqual(@as(i32, 8), cl.bloodMoonDayFor(7)); // the night before
    try std.testing.expectEqual(@as(i32, 8), cl.bloodMoonDayFor(8)); // horde night
    try std.testing.expectEqual(@as(i32, 14), cl.bloodMoonDayFor(9)); // next cycle
    // range 0: pure multiples (the default; bmday-resend scenario unchanged).
    cl.bloodmoon_range = 0;
    try std.testing.expectEqual(@as(i32, 7), cl.bloodMoonDayFor(1));
    try std.testing.expectEqual(@as(i32, 7), cl.bloodMoonDayFor(7));
    try std.testing.expectEqual(@as(i32, 14), cl.bloodMoonDayFor(8));
    // frequency 0 = disabled.
    cl.bloodmoon_frequency = 0;
    try std.testing.expectEqual(@as(i32, 0), cl.bloodMoonDayFor(1));
}

test "blood moon party clustering pools nearby players and splits stragglers" {
    var w: ecs_world.World = .{};
    defer w.deinit();
    // Two players 40 m apart and one 200 m away: 2 parties (cPartyJoinDistance 80).
    const a = w.spawnPlayer(0, 70, 0, 0).?;
    const b = w.spawnPlayer(40, 70, 0, 1).?;
    _ = w.spawnPlayer(200, 70, 200, 2).?;
    var d: Director = .{};
    d.buildBloodMoonParties(&w);
    try std.testing.expectEqual(@as(u8, 2), d.bm_party_n);
    // The near pair shares one focus (their average), the straggler its own.
    const near = d.bm_parties[0];
    try std.testing.expect(near.members == 2);
    try std.testing.expect(@abs(near.focus_x - 20.0) < 0.01);
    const far = d.bm_parties[1];
    try std.testing.expect(far.members == 1);
    // No players at all -> no parties.
    var w2: ecs_world.World = .{};
    defer w2.deinit();
    var d2: Director = .{};
    d2.buildBloodMoonParties(&w2);
    try std.testing.expectEqual(@as(u8, 0), d2.bm_party_n);
    _ = a;
    _ = b;
}
