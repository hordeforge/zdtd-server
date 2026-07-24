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
        self.dawn = 4.0;
        self.dusk = 4.0 + @as(f32, @floatFromInt(daylight_hours));
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

    pub fn isBloodMoonNight(self: *const WorldClock) bool {
        if (self.bloodmoon_frequency == 0) return false;
        if (!self.isNight()) return false;
        if (self.bloodmoon_range == 0) return self.day % self.bloodmoon_frequency == 0;
        // Blood moon day = c*freq + jitter(c), jitter deterministic in [-range,+range].
        // A given day may match the target of an adjacent cycle (jitter can push a
        // blood moon across the c*freq boundary), so test the neighbouring cycles.
        const base = self.day / self.bloodmoon_frequency;
        const lo = if (base == 0) 0 else base - 1;
        var c = lo;
        while (c <= base + 1) : (c += 1) {
            if (self.bloodMoonDayForCycle(c) == self.day) return true;
        }
        return false;
    }

    fn bloodMoonDayForCycle(self: *const WorldClock, cycle: u32) i64 {
        const span: u32 = @as(u32, self.bloodmoon_range) * 2 + 1;
        const jitter: i64 = @as(i64, @intCast((cycle *% 2654435761) % span)) - @as(i64, self.bloodmoon_range);
        return @as(i64, cycle) * @as(i64, self.bloodmoon_frequency) + jitter;
    }

    pub fn worldTimeBits(self: *const WorldClock) u64 {
        const day_part: u64 = @as(u64, self.day) * 24000;
        const hour_part: u64 = @intFromFloat(self.hours * 1000.0);
        return day_part + hour_part;
    }
};

pub const Director = struct {
    clock: WorldClock = .{},
    horde_cd: f32 = 0,
    bloodmoon_cd: f32 = 0,
    scouts_cd: f32 = 0,
    total_spawned: u32 = 0,
    bloodmoon_active: bool = false,
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
            spawned += self.spawnNearPlayers(w, 2, 18.0, 28.0);
            self.horde_cd = if (self.bloodmoon_active) 8.0 else 45.0;
        }
        if (self.bloodmoon_active and self.bloodmoon_cd <= 0) {
            const wave: u32 = @max(1, self.bloodmoon_enemy_count / 2);
            spawned += self.spawnNearPlayers(w, wave, 12.0, 22.0);
            self.bloodmoon_cd = 6.0;
        }
        if (!self.clock.isNight() and self.scouts_cd <= 0) {
            spawned += self.spawnNearPlayers(w, 1, 30.0, 40.0);
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
        // Find an animal class slot (from entityclasses when loaded).
        var animal_ct: ?ecs_world.EntityClass = null;
        for (w.class_table) |ct| {
            if (ct.kind == .animal and ct.hash != 0) {
                animal_ct = ct;
                break;
            }
        }
        var n: u32 = 0;
        var p: ecs_world.Slot = 0;
        while (p < ecs_world.max_entities and n < count) : (p += 1) {
            if (!w.alive[p] or !w.mask[p].player or !w.mask[p].transform) continue;
            const ang = @as(f32, @floatFromInt(self.total_spawned +% n)) * 2.3;
            const r = min_r + (max_r - min_r) * @mod(ang, 1.0);
            const x = w.transform[p].x + @cos(ang) * r;
            const z = w.transform[p].z + @sin(ang) * r;
            const y = w.transform[p].y;
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

    fn spawnNearPlayers(self: *Director, w: *ecs_world.World, count: u32, min_r: f32, max_r: f32) u32 {
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
                // Rotate through zombie class slots (1, 8..11) so hordes vary;
                // slots beyond 1 are filled from entitygroups when XML loads.
                const zombie_slots = [_]usize{ 1, 8, 9, 10, 11 };
                var ct = w.class_table[1];
                const csel = zombie_slots[(self.total_spawned +% n) % zombie_slots.len];
                if (w.class_table[csel].hash != 0 and w.class_table[csel].kind == .zombie) {
                    ct = w.class_table[csel];
                }
                const bm_mul: f32 = if (self.bloodmoon_active) 1.5 else 1.0;
                const hp: f32 = ct.max_hp * bm_mul * self.hpScale();
                const id = if (ct.hash != 0)
                    w.spawnZombieClass(x, y, z, hp, ct.hash, ct.loot_list)
                else
                    w.spawnZombie(x, y, z, hp);
                const nid = id orelse break;
                if (w.slotOfNetId(nid)) |slot| {
                    w.zombie_ai[slot].state = .chase;
                    w.zombie_ai[slot].target_id = w.network_id[p].id;
                    w.zombie_ai[slot].alert = true;
                    n += 1;
                }
            }
        }
        return n;
    }
};

test "clock advances and bloodmoon every 7 days" {
    var cl: WorldClock = .{ .hours = 23.0, .day = 6, .seconds_per_hour = 1.0 };
    cl.tick(2.0);
    try std.testing.expectEqual(@as(u32, 7), cl.day);
    try std.testing.expect(cl.isBloodMoonNight());
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
