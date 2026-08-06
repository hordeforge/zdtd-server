//! Stock WeatherManager storm / bloodMoon state machine, server side.
//!
//! Ported branch for branch from `WeatherManager::GenerateWeatherServerFrameUpdate`
//! (asm.il ~2051744), `WeatherManager::CalcGlobalWeatherType` (~2051850) and
//! `BiomeWeather::ServerTimeUpdate` (~2048930). Only the server runs this:
//! `WeatherManager::FrameUpdate` (~2052138) gates it on IsDedicatedServer || IsServer,
//! so a stock client never simulates weather and never fights our packages.
//!
//! Times are stock world ticks (day * 24000 + hour * 1000), what
//! `WorldClock.worldTimeBits` already produces. Kept wire-free on purpose: the
//! Game turns a BiomeState into a WeatherPackage entry, nothing here knows bytes.

const std = @import("std");
const rng = @import("../util/rng.zig");
const biome_layers = @import("../assets/biome_layers.zig");

pub const max_biomes = biome_layers.max_weather_biomes;

/// Re-evaluation gate: stock only re-runs the per biome pass once world time has
/// moved 5 ticks from the last pass (GenerateWeatherServerFrameUpdate IL_008a).
pub const update_interval_ticks: i64 = 5;

/// CalcGlobalWeatherType pushes every storm at least this far out while a blood
/// moon is up, so no storm can start inside the horde night.
pub const blood_moon_storm_push: i64 = 5000;

/// One `WeatherManager/BiomeWeather`. `group_index` is the wire groupIndex and is
/// always a valid ordinal into that biome's group set.
pub const BiomeState = struct {
    biome_id: u8 = 0,
    /// Index into Table.weather_groups of the set this state cycles through.
    slot: u8 = 0,
    group_index: u8 = 0,
    remaining_seconds: u8 = 0,
    /// 0 clear, 1 stormbuild, 2 storm (BiomeWeather::stormState).
    storm_state: u8 = 0,
    /// World tick the next storm builds at. Null is stock's int.MaxValue sentinel
    /// (storms disabled); an optional keeps that out of the arithmetic entirely.
    storm_world_time: ?i64 = 0,
    storm_duration: i64 = 0,
    next_rand_world_time: i64 = 0,
    /// temp F, precip, cloud, wind, fog. Raw biomes.xml 0..100 scale except
    /// temperature: the client divides by 100 (BiomeWeather::FogPercent, asm.il ~2048596).
    params: [5]f32 = .{ 70, 0, 15, 10, 1 },
};

pub const Config = struct {
    /// Deterministic stream: same world seed replays the same storm schedule.
    seed: u64 = 0,
    /// GamePrefs.DayNightLength, real minutes per in-game day (the 60/x time scale).
    day_night_length: u16 = 60,
    /// World::StormFrequency (SandboxOptions 57, stock default 1.0). 0 disables storms.
    storm_frequency: f32 = 1,
    /// GameStats.TimeOfDayIncPerSec, the divisor turning remaining ticks into the
    /// client's storm warning countdown. Must match the GameStats blob we send.
    time_of_day_inc_per_sec: u8 = 20,
};

pub const Manager = struct {
    states: [max_biomes]BiomeState = [_]BiomeState{.{}} ** max_biomes,
    n: u8 = 0,
    rand: rng.XorShift32 = .init(1),
    storm_frequency: f32 = 1,
    day_night_length: u16 = 60,
    time_of_day_inc_per_sec: u8 = 20,
    last_update_world_time: i64 = 0,
    /// WeatherManager::weatherAllName != null: a global type overrides every biome.
    blood_moon_forced: bool = false,

    /// Seed one BiomeState per biome that has weather groups, in table order, and
    /// roll each biome's opening group so the first package we send is already real.
    pub fn initFrom(self: *Manager, table: *const biome_layers.Table, cfg: Config) void {
        self.* = .{
            .rand = .initFromU64(cfg.seed),
            .storm_frequency = if (std.math.isFinite(cfg.storm_frequency) and cfg.storm_frequency > 0)
                cfg.storm_frequency
            else
                0,
            .day_night_length = @max(cfg.day_night_length, 1),
            .time_of_day_inc_per_sec = cfg.time_of_day_inc_per_sec,
        };
        var i: usize = 0;
        while (i < table.weather_n and i < max_biomes) : (i += 1) {
            const set = &table.weather_groups[i];
            if (set.n == 0) continue;
            self.states[self.n] = .{
                .biome_id = table.weather_ids[i],
                .slot = @intCast(i),
                .storm_world_time = if (self.stormsDisabledFor(set)) null else 0,
            };
            self.setWeatherRandom(&self.states[self.n], set, 0);
            self.n += 1;
        }
    }

    /// The group set a state cycles through. Valid for the table it was seeded from.
    pub fn groupsFor(
        table: *const biome_layers.Table,
        st: *const BiomeState,
    ) *const biome_layers.WeatherGroupSet {
        return &table.weather_groups[st.slot];
    }

    /// One server pass. `world_time` is stock ticks, `blood_moon` is the director's
    /// live horde-night flag (stock reads SkyManager::IsBloodMoonVisible here).
    pub fn tick(self: *Manager, table: *const biome_layers.Table, world_time: i64, blood_moon: bool) void {
        if (self.n == 0) return;
        if (blood_moon) {
            self.forceBloodMoon(table, world_time);
            return;
        }
        self.blood_moon_forced = false;
        if (@max(world_time, self.last_update_world_time) -|
            @min(world_time, self.last_update_world_time) < update_interval_ticks) return;
        self.last_update_world_time = world_time;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            self.serverTimeUpdate(&self.states[i], groupsFor(table, &self.states[i]), world_time);
        }
    }

    /// CalcGlobalWeatherType: hold every storm off until well past the horde night,
    /// then force each biome to its own "bloodMoon" group index. SetAllWeather only
    /// re-rolls on the transition, so the group holds for the whole night.
    fn forceBloodMoon(self: *Manager, table: *const biome_layers.Table, world_time: i64) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const st = &self.states[i];
            if (st.storm_world_time) |swt| {
                if (swt -| world_time < blood_moon_storm_push)
                    st.storm_world_time = world_time +| blood_moon_storm_push;
            }
        }
        if (self.blood_moon_forced) return;
        self.blood_moon_forced = true;
        i = 0;
        while (i < self.n) : (i += 1) {
            // A biome without a bloodMoon group keeps whatever it had: stock's
            // WeatherRandomize(string) returns false and changes nothing.
            self.setWeatherNamed(&self.states[i], groupsFor(table, &self.states[i]), "bloodMoon");
        }
    }

    /// BiomeWeather::ServerTimeUpdate (asm.il ~2048930).
    fn serverTimeUpdate(
        self: *Manager,
        st: *BiomeState,
        set: *const biome_layers.WeatherGroupSet,
        world_time: i64,
    ) void {
        if (self.stormsDisabledFor(set)) {
            if (st.storm_world_time != null) {
                st.storm_world_time = null;
                st.next_rand_world_time = 0;
            }
        } else if (st.storm_world_time == null) {
            st.storm_world_time = 0;
        }

        if (st.storm_world_time) |swt| {
            const delta = world_time -| swt;
            if (delta >= 0) {
                const time_scale: f32 = 60.0 / @as(f32, @floatFromInt(self.day_night_length));
                const build_ticks = scaleTicks(durationOf(set, "stormbuild"), time_scale);
                const until_storm = build_ticks - delta;
                if (until_storm > 0) {
                    if (st.storm_state != 1) {
                        st.storm_state = 1;
                        self.setWeatherNamed(st, set, "stormbuild");
                    }
                    if (self.time_of_day_inc_per_sec > 0) {
                        const secs = @divTrunc(until_storm, self.time_of_day_inc_per_sec);
                        st.remaining_seconds = @intCast(@min(secs, 255));
                    }
                    return;
                }
                if (world_time < swt +| st.storm_duration) {
                    if (st.storm_state != 2) {
                        st.storm_state = 2;
                        self.setWeatherNamed(st, set, "storm");
                    }
                    return;
                }
                // Storm over: schedule the next one. Stock leaves remaining_seconds
                // stale here; the client only reads it while stormLevel is 1 or 2
                // (EntityPlayerLocal::WeatherStatusFrameUpdate, asm.il ~527340).
                st.storm_state = 0;
                // stormsDisabledFor kept storm_world_time null without this group.
                const storm = set.findIndex("storm").?;
                const g = &set.groups[storm];
                const gap = clampTicks(@as(f32, @floatFromInt(
                    self.randomRange(g.delay_lo, g.delay_hi),
                )) / self.storm_frequency);
                st.storm_world_time = world_time +| gap;
                var dur: i64 = g.duration;
                const eighth = @divTrunc(dur, 8);
                dur += self.randomRange(dur - eighth, dur + eighth);
                st.storm_duration = build_ticks + scaleTicks(dur, time_scale);
            }
        }
        if (world_time >= st.next_rand_world_time) self.setWeatherRandom(st, set, world_time);
    }

    /// Storms need both halves of the cycle. Without them stock would reschedule a
    /// zero-length storm on every pass, which burns rng and never shows anything.
    fn stormsDisabledFor(self: *const Manager, set: *const biome_layers.WeatherGroupSet) bool {
        return self.storm_frequency == 0 or set.findIndex("storm") == null;
    }

    /// BiomeWeather::SetWeather(int, float) (asm.il ~2049128): pick a group by the
    /// normalized probability walk, then hold it for that group's duration.
    fn setWeatherRandom(
        self: *Manager,
        st: *BiomeState,
        set: *const biome_layers.WeatherGroupSet,
        world_time: i64,
    ) void {
        const roll = self.randomFloat();
        var acc: f32 = 0;
        var i: usize = 0;
        while (i < set.n) : (i += 1) {
            acc += set.groups[i].prob;
            if (roll < acc) {
                self.selectGroup(st, set, @intCast(i));
                break;
            }
        }
        // No pick (probabilities sum below the roll) keeps the current group, as
        // BiomeDefinition::WeatherRandomize does, but the hold still refreshes.
        st.next_rand_world_time = world_time +| set.groups[st.group_index].duration;
    }

    /// BiomeWeather::SetWeather(string) (asm.il ~2049186): named group, no hold, so
    /// the group's parameters re-roll on every pass while it is held.
    fn setWeatherNamed(
        self: *Manager,
        st: *BiomeState,
        set: *const biome_layers.WeatherGroupSet,
        group_name: []const u8,
    ) void {
        const idx = set.findIndex(group_name) orelse return;
        self.selectGroup(st, set, idx);
        st.next_rand_world_time = 0;
    }

    /// BiomeDefinition::SelectWeatherGroup (asm.il ~1250209): adopt the index and
    /// roll all five ProbTypes from that group's weighted ranges.
    fn selectGroup(self: *Manager, st: *BiomeState, set: *const biome_layers.WeatherGroupSet, index: u8) void {
        std.debug.assert(index < set.n);
        st.group_index = index;
        var pt: usize = 0;
        while (pt < biome_layers.prob_type_count) : (pt += 1) {
            st.params[pt] = self.rollRange(set.groups[index].rangeSlice(pt));
        }
    }

    /// Probabilities::GetRandomValue (asm.il ~1249300): weighted pick of a range,
    /// then lerp inside it. Stock returns 0 when the condition has no entries.
    fn rollRange(self: *Manager, ranges: []const biome_layers.WeatherRange) f32 {
        const roll = self.randomFloat();
        var acc: f32 = 0;
        for (ranges) |r| {
            acc += r.weight;
            if (roll < acc) {
                const t = self.randomFloat();
                return r.lo * t + r.hi * (1 - t);
            }
        }
        return 0;
    }

    /// GameRandom::RandomRange(min, maxExclusive) (asm.il ~1011268).
    fn randomRange(self: *Manager, min: i64, max_exclusive: i64) i64 {
        if (max_exclusive <= min) return min;
        const span = max_exclusive -| min;
        const bound: u32 = @intCast(@min(span, std.math.maxInt(u32)));
        return min + self.rand.nextBounded(bound);
    }

    /// GameRandom::RandomFloat in [0, 1).
    fn randomFloat(self: *Manager) f32 {
        return @as(f32, @floatFromInt(self.rand.next() >> 8)) / @as(f32, 1 << 24);
    }
};

/// Tick count from a computed float, saturating so a modded duration or a tiny
/// storm frequency can never trap @intFromFloat.
fn clampTicks(v: f32) i64 {
    if (!std.math.isFinite(v)) return 0;
    return @intFromFloat(std.math.clamp(v, -2.0e9, 2.0e9));
}

/// 60 / DayNightLength scaling (BiomeWeather::ServerTimeUpdate IL_004d).
fn scaleTicks(ticks: i64, time_scale: f32) i64 {
    return clampTicks(@as(f32, @floatFromInt(ticks)) * time_scale);
}

/// BiomeDefinition::WeatherGetDuration (asm.il ~1250079): 0 when absent.
fn durationOf(set: *const biome_layers.WeatherGroupSet, group_name: []const u8) i64 {
    const idx = set.findIndex(group_name) orelse return 0;
    return set.groups[idx].duration;
}

fn testTable() biome_layers.Table {
    var t: biome_layers.Table = .{};
    t.weather_ids[0] = 3;
    t.weather_groups[0] = biome_layers.parseWeatherGroups(
        \\<weather name="default" prob="80" duration="6"><Wind range="3,22"/></weather>
        \\<weather name="rainheavy" prob="20" duration="2"><Wind range="30,35"/></weather>
        \\<weather name="stormbuild" prob="0" duration="0.2"><Wind range="25,25"/></weather>
        \\<weather name="storm" prob="0" duration="1.1" delay="26,36"><Wind range="40,40"/></weather>
        \\<weather name="bloodMoon" prob="0"><Wind range="15,20"/></weather>
    );
    t.weather_ids[1] = 5;
    t.weather_groups[1] = biome_layers.parseWeatherGroups(
        \\<weather name="default" prob="100" duration="5"><Wind range="1,2"/></weather>
        \\<weather name="stormbuild" prob="0" duration="0.59"><Wind range="9,9"/></weather>
        \\<weather name="storm" prob="0" duration="1.3" delay="28,36"><Wind range="12,12"/></weather>
        \\<weather name="bloodMoon" prob="0"><Wind range="4,4"/></weather>
    );
    t.weather_n = 2;
    t.loaded = true;
    return t;
}

test "initFrom seeds one state per weather biome" {
    const t = testTable();
    var m: Manager = .{};
    m.initFrom(&t, .{ .seed = 7 });
    try std.testing.expectEqual(@as(u8, 2), m.n);
    try std.testing.expectEqual(@as(u8, 3), m.states[0].biome_id);
    try std.testing.expectEqual(@as(u8, 5), m.states[1].biome_id);
    // Opening group is a real roll, so the hold and the params are already set.
    try std.testing.expect(m.states[0].group_index < t.weather_groups[0].n);
    try std.testing.expect(m.states[0].next_rand_world_time > 0);
    try std.testing.expect(m.states[0].params[3] > 0);
}

test "storm cycle runs stormbuild then storm then clears" {
    const t = testTable();
    const set = &t.weather_groups[0];
    var m: Manager = .{};
    m.initFrom(&t, .{ .seed = 1 });
    var builds: u32 = 0;
    var storms: u32 = 0;
    var clears_after_storm: u32 = 0;
    var prev_state: u8 = 0;
    var last_remaining: u8 = 255;
    // Two full storms fit inside four in-game days at delay 26000..36000 ticks.
    var wt: i64 = 0;
    while (wt <= 96_000) : (wt += 10) {
        m.tick(&t, wt, false);
        const st = m.states[0];
        switch (st.storm_state) {
            1 => {
                if (prev_state != 1) {
                    builds += 1;
                    last_remaining = 255;
                }
                // Countdown falls monotonically inside one build window.
                try std.testing.expect(st.remaining_seconds <= last_remaining);
                last_remaining = st.remaining_seconds;
                try std.testing.expectEqual(set.findIndex("stormbuild").?, st.group_index);
            },
            2 => {
                if (prev_state != 2) storms += 1;
                try std.testing.expectEqual(set.findIndex("storm").?, st.group_index);
            },
            else => if (prev_state == 2) {
                clears_after_storm += 1;
            },
        }
        prev_state = st.storm_state;
    }
    try std.testing.expect(builds >= 2);
    try std.testing.expect(storms >= 1);
    try std.testing.expect(clears_after_storm >= 1);
    // A cleared storm always leaves the next one scheduled ahead of now.
    const next = m.states[0].storm_world_time orelse return error.TestUnexpectedResult;
    try std.testing.expect(next > 96_000 - 36_000);
}

test "storm frequency zero disables storms but keeps rolling groups" {
    const t = testTable();
    var m: Manager = .{};
    m.initFrom(&t, .{ .seed = 3, .storm_frequency = 0 });
    var wt: i64 = 0;
    while (wt <= 200_000) : (wt += 500) {
        m.tick(&t, wt, false);
        try std.testing.expectEqual(@as(u8, 0), m.states[0].storm_state);
        try std.testing.expect(m.states[0].storm_world_time == null);
    }
    // Groups still cycle: the default group has 80/100 odds, rainheavy 20/100.
    try std.testing.expect(m.states[0].group_index < t.weather_groups[0].n);
}

test "blood moon forces every biome to its bloodMoon group" {
    const t = testTable();
    var m: Manager = .{};
    m.initFrom(&t, .{ .seed = 11 });
    m.tick(&t, 24_000, false);
    m.tick(&t, 24_100, true);
    var i: usize = 0;
    while (i < m.n) : (i += 1) {
        const expect = t.weather_groups[i].findIndex("bloodMoon").?;
        try std.testing.expectEqual(expect, m.states[i].group_index);
        // Storms are pushed clear of the horde night.
        const swt = m.states[i].storm_world_time orelse return error.TestUnexpectedResult;
        try std.testing.expect(swt >= 24_100 + blood_moon_storm_push);
    }
    // Leaving the blood moon releases the global override.
    m.tick(&t, 30_000, false);
    try std.testing.expect(!m.blood_moon_forced);
}

test "group index stays in range across random world time jumps" {
    const t = testTable();
    var m: Manager = .{};
    m.initFrom(&t, .{ .seed = 99 });
    var jumps: rng.XorShift32 = .init(4242);
    var wt: i64 = 0;
    var step: u32 = 0;
    while (step < 4000) : (step += 1) {
        wt +|= jumps.nextBounded(50_000);
        m.tick(&t, wt, jumps.nextBounded(8) == 0);
        var i: usize = 0;
        while (i < m.n) : (i += 1) {
            const st = m.states[i];
            try std.testing.expect(st.group_index < t.weather_groups[i].n);
            for (st.params) |p| try std.testing.expect(std.math.isFinite(p));
        }
    }
}

test "max world time does not overflow the schedule" {
    const t = testTable();
    var m: Manager = .{};
    m.initFrom(&t, .{ .seed = 5 });
    const near_max = std.math.maxInt(i64) - 1000;
    m.tick(&t, near_max, false);
    m.tick(&t, near_max, true);
    var i: usize = 0;
    while (i < m.n) : (i += 1) {
        try std.testing.expect(m.states[i].group_index < t.weather_groups[i].n);
    }
}

test "empty table leaves the manager inert" {
    const t: biome_layers.Table = .{};
    var m: Manager = .{};
    m.initFrom(&t, .{ .seed = 1 });
    try std.testing.expectEqual(@as(u8, 0), m.n);
    m.tick(&t, 5000, true);
    try std.testing.expectEqual(@as(u8, 0), m.n);
}
