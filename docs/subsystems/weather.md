# Weather, sky and world time

This page owns the environmental simulation: the per-biome weather state machine and its timers, the sky and ambient-light parameters folded from world time, the world clock itself, and the package builders and send paths that carry weather and time to clients. The state machine lives in `world/weather.zig` and is deliberately wire-free: it turns world ticks into a `BiomeState`, and knows nothing about bytes (`src/world/weather.zig:9`). The sky model in `world/sky.zig` is a set of pure functions over world time (`src/world/sky.zig:1`). The byte layout lives in `wire/packages.zig`, and the decision of when to send belongs to the `server` package (`src/server/game/weather.zig`). The clock is `ecs/aidirector.zig` `WorldClock`, which the weather scheduler only reads. The package edge is enforced: `world` may import `util` and `assets` and must not import wire, server or litenet (`src/world/root.zig:3`), and `scripts/lint-architecture.sh:50` spells the same rule as a lint. `world/weather.zig` imports `ecs/aidirector.zig` for `ticks_per_day`, an allowed world to ecs edge (`src/world/weather.zig:16`). The top of the stack, and therefore the only package that may build and send these packages, is `server`, described as "top of the stack. May import all other src packages." (`src/server/root.zig:3`). What this page does not own: chunk and map loading (`map.md`), the save ladder as a whole (`persistence.md`), and the stealth and AI systems that consume the ambient value it computes.

Sources: [`src/world/weather.zig`](../../src/world/weather.zig), [`src/server/game/weather.zig`](../../src/server/game/weather.zig), [`src/world/sky.zig`](../../src/world/sky.zig), [`src/assets/worldglobal.zig`](../../src/assets/worldglobal.zig), [`src/wire/packages.zig`](../../src/wire/packages.zig), [`src/server/game/step.zig`](../../src/server/game/step.zig), [`src/server/game/clock_persist.zig`](../../src/server/game/clock_persist.zig), [`src/server/game/blockmeta.zig`](../../src/server/game/blockmeta.zig), [`src/ecs/aidirector.zig`](../../src/ecs/aidirector.zig)

## The per-biome weather state machine

The scheduler is a port of three stock methods, named in the file header: `WeatherManager::GenerateWeatherServerFrameUpdate`, `WeatherManager::CalcGlobalWeatherType` and `BiomeWeather::ServerTimeUpdate` (`src/world/weather.zig:3`). Only the server runs it, because stock `WeatherManager::FrameUpdate` gates the simulation on dedicated-server or server role, so a stock client never simulates weather and never fights these packages (`src/world/weather.zig:6`). Times are stock world ticks, `day * 24000 + hour * 1000`, the same unit `WorldClock.worldTimeBits` produces (`src/world/weather.zig:9`).

One record per weather-capable biome, in biomes.xml order, is the whole live state (`src/world/weather.zig:31`):

```zig
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
```

The manager is a fixed array plus the schedule-relevant scalars, all copyable and all persisted (`src/world/weather.zig:67`):

```zig
pub const Manager = struct {
    states: [max_biomes]BiomeState = [_]BiomeState{.{}} ** max_biomes,
    n: u8 = 0,
    rand: rng.XorShift32 = .init(1),
    storm_frequency: f32 = 1,
    day_night_length: u16 = 60,
    time_of_day_inc_per_sec: u32 = 6,
    blood_moon_storm_push: i64 = 5000,
    last_update_world_time: i64 = 0,
    /// WeatherManager::weatherAllName != null: a global type overrides every biome.
    blood_moon_forced: bool = false,
```

`initFrom` seeds one state per biome whose group set is non-empty, rolls the opening group so the first package already carries real parameters, and disables storms for a state whose set has no `storm` group (`src/world/weather.zig:81`, `src/world/weather.zig:95`, `src/world/weather.zig:263`). `groupsFor` resolves a state's group set through its `slot`, a document ordinal into the loaded biomes.xml (`src/world/weather.zig:154`). Randomness is one seeded `XorShift32`, so the same world seed replays the same storm schedule (`src/world/weather.zig:50`).

`tick` is the whole per-pass entry (`src/world/weather.zig:163`). It returns immediately when the manager holds no states, and while a blood moon is up it short-circuits into `forceBloodMoon` instead of the normal pass (`src/world/weather.zig:164`, `src/world/weather.zig:165`). Otherwise a 5-tick re-evaluation gate suppresses the pass, matching stock's IL_008a comparison against the last pass time (`src/world/weather.zig:24`, `src/world/weather.zig:170`). Each state then runs `serverTimeUpdate`: state 1 (`stormbuild`) counts down `remaining_seconds` as `until_storm / time_of_day_inc_per_sec`, state 2 (`storm`) holds for `storm_duration`, and after the storm clears the next one is scheduled by a `storm` group delay scaled by `60 / DayNightLength` and divided by `storm_frequency` (`src/world/weather.zig:202`, `src/world/weather.zig:229`, `src/world/weather.zig:250`). Outside a storm leg, `setWeatherRandom` runs the normalized probability walk and holds the picked group for that group's duration (`src/world/weather.zig:269`, `src/world/weather.zig:287`). Named transitions (`stormbuild`, `storm`, `bloodMoon`) go through `setWeatherNamed`, which adopts the group index and re-rolls all five parameters on every pass while held (`src/world/weather.zig:292`, `src/world/weather.zig:305`). `forceBloodMoon` pushes any scheduled storm at least `blood_moon_storm_push` ticks past the horde night, then forces each biome to its own `bloodMoon` group once per night (`src/world/weather.zig:182`, `src/world/weather.zig:187`, `src/world/weather.zig:191`). A biome with no `bloodMoon` group keeps whatever it had, which the comment records as stock's `WeatherRandomize(string)` returning false (`src/world/weather.zig:195`).

## What crosses the wire

`NetPackageWeather` has no count prefix. The client sizes its read from its own `biomeWeather.Count`, and the server sizes the body from the loaded table's `weather_n`, so the two agree only when both sides loaded the same biomes.xml; the padding and trimming comment states the earlier pinned count of five produced wrong-length bodies on modlet installs (`src/server/game/weather.zig:30`, `src/server/game/weather.zig:35`). The table keeps the ordered ids parallel to the group sets (`src/assets/biome_layers.zig:213`):

```zig
    weather_ids: [max_weather_biomes]u8 = .{0} ** max_weather_biomes,
    /// Parallel to weather_ids.
    weather_groups: [max_weather_biomes]WeatherGroupSet = [_]WeatherGroupSet{.{}} ** max_weather_biomes,
    weather_n: u8 = 0,
```

The entry struct the server fills (`src/wire/packages.zig:4082`):

```zig
pub const WeatherBiome = struct {
    biome_id: u8 = 3,
    group_index: u8 = 0,
    /// Number of weather groups this biome has in the biomes.xml we serve. The
    /// client indexes weatherGroups with groupIndex unchecked, so this bounds it.
    group_count: u8 = 1,
    remaining_seconds: u8 = 0,
    /// temp, precip, cloud, wind, fog. Raw biomes.xml scale (temp F, rest 0..100);
    /// the client divides by 100 (BiomeWeather::FogPercent, asm.il ~2048596).
    params: [5]f32 = .{ 70, 0, 20, 10, 5 },
};
```

`group_count` never reaches the wire; it only bounds the index the client will use unchecked, so an out-of-range `group_index` is emitted as 0 (`src/wire/packages.zig:4103`):

```zig
pub fn buildWeatherBody(buf: []u8, biomes: []const WeatherBiome) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    for (biomes) |b| {
        try w.writeByte(b.biome_id);
        try w.writeByte(if (b.group_index < b.group_count) b.group_index else 0);
        try w.writeByte(b.remaining_seconds);
        for (b.params) |p| try w.writeF32(p);
    }
    return w.written();
}
```

One entry is 23 bytes, `biomeId u8 + groupIndex u8 + remainingSeconds u8 + 5 x f32`, and the sender checks the produced length against `weather_count * weather_entry_bytes` and prints a diagnostic on mismatch instead of sending something else (`src/server/game/weather.zig:21`, `src/server/game/weather.zig:82`). With no biomes.xml loaded at all the builder emits five mild default entries on the raw 0..100 XML scale so an unmodded client still reads a well-formed body (`src/server/game/weather.zig:24`, `src/server/game/weather.zig:52`). When the table has weather biomes the manager has no state for, the count is kept and the extra entries copy the last real state with the ids named from `weather_ids` rather than guessed (`src/server/game/weather.zig:63`).

Sending happens on three paths. `broadcastWeather` refuses to build anything when no client has entered, then broadcasts one body (`src/server/game/weather.zig:12`, `src/server/game/weather.zig:90`). The tick calls the state machine, then that broadcast, inside the same `tick_n % world_time_send_ticks == 0` branch that sends `NetPackageWorldTime`, and skips the broadcast while load shedding is armed (`src/server/game/step.zig:383`, `src/server/game/step.zig:386`, `src/server/game/step.zig:391`). The default cadence is 20 ticks, one second at 20 TPS (`src/server/game/types.zig:87`). Finally, `sendWeather` goes to one peer at the end of the enter/respawn bundle, but deliberately not on first join, because the client's `InitPackages` may still be null and an early `NetPackageWeather` underruns into a kick; a first-join client picks weather up on the next cadence broadcast (`src/server/game.zig:3039`, `src/server/game.zig:4098`). The wire test pins the entry layout by byte offset and the scenario tests read the produced body back (`src/wire/packages.zig:4131`, `src/server/scenarios.zig:5217`); both show self-consistency against the server's own assumed shape, not stock-client acceptance, and no stock round trip is claimed here.

## Sky and light parameters

`world/sky.zig` is slice 1 and slice 2 of the clone-side light model, with the header naming what stays zero: position-dependent block light, moving light entities and shade, all recorded as later slices (`src/world/sky.zig:6`). The fixed world-time mapping is two constants (`src/world/sky.zig:19`):

```zig
pub const day_ticks: u64 = 24000;
pub const ticks_per_hour: u64 = 1000;
```

`timeOfDay` reproduces `SkyManager.TimeOfDay` as `(timeOfDay % 24000) / 1000` (`src/world/sky.zig:23`). `sunMoonTarget` maps day hours into `[0, 0.5]` and night hours through the `24 - dusk` window into `[0.5, 1]`, reaching 0 at dawn, 0.5 at dusk and 1.0 at the next dawn (`src/world/sky.zig:36`). It is used directly with no per-tick state, which the comments record as a deliberate deviation from stock's `Lerp(0.05)` smoothing, worth about two minutes of lag and invisible to the day curve because both sides of the dawn discontinuity are 0.5 (`src/world/sky.zig:32`). `dayPercent` is the stock `CalcDayPercent` curve over that target: 0.5 at dawn and dusk, 1.0 at 13:00, 0.0 around 01:00 (`src/world/sky.zig:52`). `ambientLuma` applies the stock `GetLightLevel` ambient shaping `AmbientTotal^0.6 * 0.5` to that day percent (`src/world/sky.zig:67`). The client-only `isAllTimeNight` setting is not modeled (`src/world/sky.zig:51`).

The moon fold is slice 2, driven by the pinned seven-phase tables (`src/world/sky.zig:123`):

```zig
pub const moon_phases = [_]f32{ 0.05, 0.35, 0.55, 0.70, 1.40, 1.63, 1.82 };
pub const moon_brights = [_]f32{ 1.0, 0.65, 0.45, 0.25, 0.40, 0.60, 0.90 };
```

`moonBrightness` indexes that table by `(day + 5) % 7`, the integer form of stock's `((int)(dayCount + 5.5)) % 7`, and `moonAmbientScale` folds the brightness toward 1 as the day percent rises, stock's `FastLerp(moonBright, 1, dayPercent * 3.030303)`; a blood-moon window forcing the full-moon index is not modeled (`src/world/sky.zig:120`, `src/world/sky.zig:126`, `src/world/sky.zig:134`).

The per-tick fold lives in the tick path and is the only consumer of these functions. The moon term, the night floor and the final scale sit at `src/server/game/step.zig:135`, `src/server/game/step.zig:140` and `src/server/game/step.zig:141`; the fold opens at `src/server/game/step.zig:131`:

```zig
        const day_pct = sky.dayPercent(clk.worldTimeBits(), clk.dawn, clk.dusk);
        const moon = sky.moonBrightness(clk.worldTimeBits() / sky.day_ticks);
        const luma = @max(sky.ambientLuma(day_pct), self.worldglobal.nightFloor());
        self.sim.ambient_light = luma * sky.moonAmbientScale(moon, day_pct);
```

`clk.dawn` and `clk.dusk` come from the clock, recomputed from the daylight length rather than fixed at the stock 4 and 22 (`src/ecs/aidirector.zig:46`, `src/ecs/aidirector.zig:47`). The night floor comes from `worldglobal.xml` `<environment>` ambient scales, whose stock rows are the defaults baked into the table, so a minimal or modded file degrades to them (`src/assets/worldglobal.zig:18`, `src/assets/worldglobal.zig:50`, `src/assets/worldglobal.zig:78`). The parsed table is loaded once at init into the `Game` field (`src/server/game/init_assets.zig:570`, `src/server/game.zig:592`). The computed value is written to one sim field each tick before the ECS pass, and the stealth light legs read it (`src/ecs/world.zig:291`, `src/ecs/world.zig:295`):

```zig
    ambient_light: f32 = 0,
```

## World time and how it is carried

`WorldClock` holds the day, the hours and the blood-moon schedule position (`src/ecs/aidirector.zig:35`, `src/ecs/aidirector.zig:36`). The rate the day is scaled by is the stock integer expression `24000 / (minutes * 60)`, kept in integer arithmetic on purpose, so a day over 400 real minutes divides to 0 and time stops rather than being floored (`src/ecs/aidirector.zig:25`). `worldTimeBits` is the packed `day * 24000 + hours` value the weather scheduler, the sky functions and `NetPackageWorldTime` all consume (`src/ecs/aidirector.zig:188`). The tick sends exactly that value, and only on the world-time cadence, so time and weather leave together (`src/server/game/step.zig:384`). The client is also told the time scale and the storm frequency through the GameStats blob, which is why the sim rate and the divisor cannot disagree with the display: `time_of_day_inc_per_sec` and `storm_freq` are emitted from the same fields the scheduler was configured with (`src/server/game.zig:3102`, `src/server/game.zig:3103`).

## Persistence

Weather and clock are two separate small files, both written through `util/io_fs` on the autosave cadence, default 100 ticks (`src/server/game/types.zig:91`, `src/server/game/step.zig:539`). The clock file is `clock.zcl`, magic `ZCL2`, 28 bytes: a u64 world time plus the four blood-moon schedule words (`src/server/game/clock_persist.zig:12`):

```zig
    @memcpy(buf[0..4], "ZCL2");
    const clk = &self.sim.director.clock;
    std.mem.writeInt(u64, buf[4..12], clk.worldTimeBits(), .little);
    std.mem.writeInt(u32, buf[12..16], clk.bm_cycle, .little);
    std.mem.writeInt(u32, buf[16..20], clk.bm_day_last, .little);
    std.mem.writeInt(u32, buf[20..24], clk.next_bm, .little);
    std.mem.writeInt(u32, buf[24..28], clk.bm_freq, .little);
```

Restore accepts both magics: a `ZCL1` file restores the clock and lets the schedule recompute forward from cycle 1, a `ZCL2` file restores the schedule words too, and an unreadable or mismatched file keeps a fresh clock with a printed message (`src/server/game/clock_persist.zig:41`, `src/server/game/clock_persist.zig:49`, `src/server/game/clock_persist.zig:42`).

Weather is `weather.zwt`, magic `ZWTH1`, fixed little-endian layout, 49 bytes per state (`src/world/weather.zig:441`):

```zig
pub const save_magic = "ZWTH1";
pub const save_magic_len = save_magic.len;
pub const save_state_bytes = 49;
const save_header_bytes: usize = save_magic_len + 1 + 4 + 8 + 1;
```

`encode` writes the live states in slot order plus the rng state, the last update time and the blood-moon override flag (`src/world/weather.zig:355`). `decode` is fail-closed and rejects rather than repair: wrong magic, a state count above `max_biomes` or above the current table, a truncated payload, `storm_state > 2`, a non-finite parameter, a `biome_id` that no longer matches the table slot, or a `group_index` past that biome's group count all return false and leave the manager untouched (`src/world/weather.zig:390`, `src/world/weather.zig:407`, `src/world/weather.zig:415`, `src/world/weather.zig:418`). That last check is why a modlet that reorders or removes weather biomes invalidates the save instead of resuming into a wrong group: the file is keyed by document ordinal (`src/world/weather.zig:386`). The store wrappers are `saveWeather` and `restoreWeather` in the block-meta helper (`src/server/game/blockmeta.zig:75`, `src/server/game/blockmeta.zig:83`), reached as `Game` methods (`src/server/game.zig:2231`). Restore happens at init right after the biomes.xml load seeded the manager, and the clock restore is independent of it so a world without stock biome data still resumes its saved day (`src/server/game/init_assets.zig:799`, `src/server/game/init_assets.zig:810`). Shutdown saves weather and clock with the rest of the stores (`src/server/game/lifecycle.zig:27`). The encode/decode tests assert an exact round trip and identical replay of the schedule from the restored rng state (`src/world/weather.zig:610`, `src/world/weather.zig:644`); that is self-consistency of this format, not evidence about any stock file, and no stock weather save format is claimed.

## Commands, config and divergences

Two verbs exist, both marked zdtd-only in the console enum: `storm` forces every storm-capable biome into an active storm now, and `clearweather` plus its `stormoff` alias ends any active storm and pushes the next one a full in-game day out (`src/server/admin.zig:462`, `src/server/admin.zig:464`, `src/server/admin_console.zig:555`, `src/server/admin_console.zig:563`). They call `setStormNow` and `clearStorm` on the manager, passing the live `worldTimeBits` (`src/server/admin_console.zig:557`, `src/world/weather.zig:118`, `src/world/weather.zig:137`). The help index text for both is declared beside the other console verbs (`src/server/game/constants.zig:38`, `src/server/game/constants.zig:40`).

Two tunables reach the scheduler, both bound through the reflected TOML config (`src/server/zdtd_config.zig:140`, `src/server/zdtd_config.zig:154`). `[sim] storm_frequency` is a percent, default 100, divided by 100 for the manager divisor so the client's GameStats percentage and the server's `1.0x` divisor describe the same weather; the same percent is what the GameStats blob reports as `storm_freq` (`src/server/game/init_assets.zig:794`, `src/server/game/types.zig:402`, `src/server/game.zig:3103`). A zero disables storms entirely while group cycling continues (`src/world/weather.zig:264`, `src/world/weather.zig:536`). A negative value warns and becomes 0 (`src/server/zdtd_config.zig:665`). `[sim] storm_bm_push_ticks`, default 5000, is the blood-moon storm push (`src/server/zdtd_config.zig:154`, `src/server/zdtd_config.zig:464`).

Three documented divergences touch this subsystem. A storm frequency of zero as a disable switch is a zdtd policy addition, because stock has no such value (`docs/DIVERGENCES.md:918`). The world clock advances while no player is connected, where the stock dedicated server pauses world time; the cited cost is that an idle server burns through scheduled days, horde nights and weather (`docs/DIVERGENCES.md:958`). A `DayNightLength` above 400 real minutes freezes world time, because the stock integer rate expression becomes 0 ticks per second; zdtd runs the same expression, so this is fidelity rather than policy (`docs/DIVERGENCES.md:945`). The zdtd.toml percent surface for storm frequency exists because V3.1.0 ships no serverconfig key for it, the value being world state in the GameStats blob (`docs/GAME_OPTIONS.md:169`).

## See also

- [Process loop and the 50 ms tick](tick.md)
- [Map loading and terrain](map.md)
- [Persistence and restart durability](persistence.md)
- [Gameplay flows](../GAMEPLAY.md)
- [Divergences from stock](../DIVERGENCES.md)
