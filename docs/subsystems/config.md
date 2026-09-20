# Configuration: serverconfig, zdtd.toml, presets, rules

The configuration subsystem owns every operator-tunable value the server reads before the first tick: the stock `serverconfig.xml` subset, the `zdtd.toml` operator file, the preset packs under `presets/`, the comptime-reflected TOML binder that parses both TOML surfaces, and the `Rules` overlay that carries sim parameters into the ECS world. It does not own the consumers of those values (sim systems in `src/ecs/`, wire encoders in `src/wire/`, runtime mutation in `src/server/admin_console.zig`), and it owns no XML game data: catalogs under `src/assets/` are stock data read from the operator's install, not configuration. The surface spans three packages. `src/server/root.zig:3` declares the server layer "top of the stack. May import all other src packages", so `config.zig`, `zdtd_config.zig` and `preset.zig` live there and are the only files that read operator files. `src/util/toml_bind.zig` sits in the leaf `util` layer that "must not import server, ecs, wire, world, assets, litenet, or apm" (`src/util/root.zig:3`) and is therefore importable by every layer, and `src/ecs/rules.zig` is a leaf type: the ECS package "may import util only" (`src/ecs/root.zig:3`), with one documented comptime-only exception that imports `assets/sandbox_presets.zig` to seed difficulty defaults (`src/ecs/root.zig:10`). The direction is enforced, not conventional: `check_edges ecs 'server|wire|world|litenet|apm'` (`scripts/lint-architecture.sh:49`) stops lower layers from reaching back into the server config, so the merged result is pushed down by `main.zig` exactly once.

Sources: [`src/server/config.zig`](../../src/server/config.zig), [`src/server/zdtd_config.zig`](../../src/server/zdtd_config.zig), [`src/server/preset.zig`](../../src/server/preset.zig), [`src/util/toml_bind.zig`](../../src/util/toml_bind.zig), [`src/ecs/rules.zig`](../../src/ecs/rules.zig), [`src/assets/sandbox.zig`](../../src/assets/sandbox.zig), [`src/assets/sandbox_presets.zig`](../../src/assets/sandbox_presets.zig), [`src/assets/sandbox_data.zig`](../../src/assets/sandbox_data.zig).

## Surfaces, load order, precedence

Every surface reduces to one struct and one apply function. `Config` holds the serverconfig XML subset, `zdtd_config.File` holds the operator TOML, `preset.Preset` holds a pack; each has an `applyToInitOptions` that writes only the fields the file set. The TOML surfaces are almost entirely optional fields, where `?T` means unset (`src/util/toml_bind.zig:7`); the few non-optional strings (`[quests] objective_kinds`, `[bots] weapon_profiles`) use an empty sentinel that callers treat as unset (`src/server/zdtd_config.zig:249`, `:282`). Wire geometry is fixed stock (ADR 0036); there is no `[wire]` config. The gameplay block of `Config` (`src/server/config.zig:80`):

```zig
    game_difficulty: u8 = 1, // GameDifficulty 0..5 (1 = Adventurer; the stock default game - live dedi GameDifficulty stat = 1, console-commands.md; the shipped SandboxCode is the Adventurer preset)
    blood_moon_frequency: u8 = 7, // BloodMoonFrequency (0 = off)
    blood_moon_enemy_count: u8 = 8, // BloodMoonEnemyCount per player
    player_killing_mode: u8 = 3, // PlayerKillingMode 0..3 (0 = no PvP)
    day_night_length: u16 = 60, // DayNightLength, real minutes per full day
    day_light_length: u8 = 18, // DayLightLength, daylight hours in a day
    max_spawned_zombies: u16 = 64, // MaxSpawnedZombies (server-wide alive cap)
    blood_moon_range: u8 = 0, // BloodMoonRange, ±day jitter
    zombie_move: u8 = 0, // ZombieMove 0..4 (day)
    zombie_move_night: u8 = 3, // ZombieMoveNight 0..4
    zombie_feral_move: u8 = 3, // ZombieFeralMove 0..4
    zombie_bm_move: u8 = 3, // ZombieBMMove 0..4 (blood moon)
    enemy_difficulty: u8 = 0, // EnemyDifficulty 0=normal, 1=feral
    loot_abundance: u16 = 100, // LootAbundance percent
    xp_multiplier: u16 = 100, // XPMultiplier percent
```

Above that block sit identity and transport fields (`port` 26902, `max_players` 8, `world_name`, `password`, telnet keys, `view_radius`, slot tiers, `authority_mode`), all `src/server/config.zig:30` to `:76`. The struct closes with an owned-arena pointer and its `deinit` (`src/server/config.zig:144`), because a file-loaded `Config` owns the strings it decoded; the file size cap is 1 MiB (`src/server/config.zig:11`).

`main.zig` is the only place the order is realized. `--serverconfig` is loaded first and a missing or unreadable path is fatal (`src/main.zig:549`); the config is copied into the `InitOptions` struct literal field by field (`src/main.zig:716`). `zdtd.toml` is looked up as `<world_dir>/zdtd.toml` then CWD `zdtd.toml`, first existing file wins (`src/main.zig:797`), and an unreadable one aborts startup (`src/main.zig:814`). Preset selection is `--preset`, else `[preset] name` from the already-loaded `zdtd.toml` (`src/server/zdtd_config.zig:202`, resolved at `src/main.zig:822`); a config-only mod's own preset sits below an explicit pick (`src/main.zig:901`). The published order is `defaults < serverconfig < preset < zdtd.toml < CLI` (`src/main.zig:947`), which extends the header order in `zdtd_config.zig` that lists env secrets but omits the preset tier (`src/server/zdtd_config.zig:2`). A preset or `zdtd.toml` declaring a name that does not match its filename is fatal (`src/main.zig:938`).

## The reflected TOML binder

`toml_bind.zig` is the reason a new tunable costs one field instead of a parse arm (ADR 0021 decision 1). It walks `std.meta.fields` of the destination struct: a struct field is a `[section]`, and dotted names recurse into nested structs, so `[rules.combat]` binds `File.rules.combat`. Unknown sections and keys abort with `error.UnknownTomlKey` and a log line (`src/util/toml_bind.zig:120`) instead of silently using a default. The entry point (`src/util/toml_bind.zig:33`):

```zig
pub fn bind(comptime T: type, dst: *T, src: []const u8, a: std.mem.Allocator) !void {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, try stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const end = std.mem.findScalar(u8, line, ']') orelse return error.BadToml;
            if (std.mem.trim(u8, line[end + 1 ..], " \t").len != 0) return error.BadToml;
            section = std.mem.trim(u8, line[1..end], " \t");
            if (section.len == 0) return error.BadToml;
            continue;
        }
        const eq = std.mem.findScalar(u8, line, '=') orelse return error.BadToml;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return error.BadToml;
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len == 0) return error.BadToml;
        try bindKV(T, dst, a, section, key, val);
    }
}
```

The destination field's type drives parsing and validation (`src/util/toml_bind.zig:176`): bool accepts `true/false/1/0/yes/no`, ints go through `std.fmt.parseInt` and therefore propagate overflow rather than wrapping, strings are duped through the file's arena, and floats reject `nan`/`inf` because a NaN makes every later comparison false (`src/util/toml_bind.zig:194`). `isBindable` admits scalars and `[]const u8` only (`src/util/toml_bind.zig:94`), which is why list-shaped policy (`[mods] disabled`, `[bots] weapon_profiles`) rides as a comma-separated string that the caller splits (`src/server/zdtd_config.zig:229`, `:288`). Optional per-struct comptime declarations carry the rest: `toml_label` for messages, `allow_root`/`root_sections` for flat packs, `aliases` for alternate spellings (the `zdtd_config.File` aliases rename `chunk_stream_radius_min` and `interest_range` at `src/server/zdtd_config.zig:297`), `ranges` for clamps applied at parse, and `enum_by_name` for constrained strings, which is how `[authority] mode` is canonicalized to a tag name and an unknown value becomes `error.InvalidAuthorityMode` (`src/server/zdtd_config.zig:370`).

Precedence is not encoded in the binder; it is encoded in call order. `mergeOverlay` copies only non-null overlay fields, so calling it in order yields defaults < pack < operator file (`src/util/toml_bind.zig:244`):

```zig
pub fn mergeOverlay(comptime T: type, dst: *T, o: anytype) void {
    inline for (std.meta.fields(T)) |f| {
        if (comptime isStruct(f.type)) {
            mergeOverlay(f.type, &@field(dst, f.name), &@field(o, f.name));
        } else if (@field(o, f.name)) |v| {
            @field(dst, f.name) = v;
        }
    }
}
```

Adding a tunable is therefore a mechanical edit. For the operator TOML, add an optional field to `Stream`, `Authority`, `Sim`, `Plugin`, `Quests`, `Bots` or `File` in `src/server/zdtd_config.zig`, plus one line in `applyToInitOptions` (`src/server/zdtd_config.zig:382`); the binder, unknown-key rejection, ranges and alias handling come for free. For a sim rule, add the field to `Rules` (`src/ecs/rules.zig:796`) and the same-named optional field to `RulesOverlay` (`src/ecs/rules.zig:1084`); a comptime parity test fails when the two drift (`src/ecs/rules.zig:1127`), and a second test requires every `Rules` leaf field to appear in `docs/GAME_OPTIONS.md` (`src/server/preset.zig:437`). No hand-written `std.mem.eql(u8, key, ...)` chain is added.

## serverconfig.xml: stock names, clamps, sandbox code

`parse` accepts only a document containing the `<ServerSettings>` root and rejects anything else with `error.BadServerConfig` (`src/server/config.zig:442`); `<propertyOverride>`-style elements do not match because the scanner requires the exact `<property` tag followed by a delimiter (`src/server/config.zig:157`). The applied name list is `known_serverconfig_names` (`src/server/config.zig:218`); stock keys outside it are ignored silently, while a name within edit distance 2 of an applied key prints a "did you mean" hint (`src/server/config.zig:292`, called at `:561`). String attributes are entity-decoded, so `&amp;` in a password or `GameName` becomes one character (`src/server/config.zig:182`). Integers go through `clampRangeNamed`, which warns and keeps the default on non-numeric input and warns and clamps out-of-range input rather than failing (`src/server/config.zig:589`). Booleans accept only the stock spellings, so `TelnetEnabled = "yes please"` leaves the console closed instead of reading as enabled (`src/server/config.zig:577`, test at `:906`).

Stock V3.1.0 moved the difficulty knobs into one string, `SandboxCode` (`EnumGamePrefs` 296). zdtd decodes it and overlays the values (XP, block damage, blood moon, day length, zombie speeds, drops) onto `Config` after the legacy property reads (`src/server/config.zig:345`, called at `:562`), and the code still rides verbatim into the GameStats(71) echo so the client decodes the server's gates itself (`src/server/config.zig:34`, `src/main.zig:719`). The codec is `'A'` plus 3-letter groups of a base-26 option id and a value-set index (`src/assets/sandbox.zig:42`); a group decodes to the pair below (`src/assets/sandbox.zig:25`), and the option and value-set tables are generated stock data, not hand-edited (`src/assets/sandbox_data.zig:1`). The decoded group type and its cap (`src/assets/sandbox.zig:24`):

```zig
/// A decoded code group: option enum id + selected value-set index.
pub const Group = struct {
    option_id: u16,
    index: u8,
};

/// Upper bound on decoded groups: 165 options + version char (one group per
/// non-default option, so a code can never carry more than 165).
pub const max_groups = 165;
```

Lookup fails closed in the stock direction: an unknown option id is logged and skipped, an option with no zdtd consumer is skipped, and an out-of-range value index yields the option default rather than a truthy guess (`src/assets/sandbox.zig:87`, `:104`). Per-difficulty damage multipliers are not hardcoded either: they are decoded at comptime from an embedded stock preset XML (`src/assets/sandbox_presets.zig:71`) into the `[rules.difficulty]` defaults (`src/ecs/rules.zig:397`).

## Preset packs

A preset is data-only TOML under `presets/<name>.toml` with no script VM (`src/server/preset.zig:1`), optionally carried by a config-only mod. The name is validated as a single path segment before it is interpolated into a path, which is what keeps `--preset ../x` from escaping the directory (`src/server/preset.zig:124`):

```zig
/// True when name is a single path segment: [A-Za-z0-9_]{1,64}, no dots/slashes.
pub fn isValidPresetName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (!ok) return false;
    }
    return true;
}
```

The pack struct accepts flat gameplay keys plus the `[gameplay]` and `[plugin]` spellings for the same keys (`src/server/preset.zig:21`), and its `ranges` declaration clamps values at parse time, so a stored pack value is already in range when `applyToInitOptions` copies the non-null subset onto `InitOptions` (`src/server/preset.zig:28`, `:178`). The pack also carries `worldgen_seed`, `[rules.*]`, `[quests]` and `[bots]` sections (`src/server/preset.zig:91`). Rules are deliberately not applied here: `applyToInitOptions` targets `InitOptions`, and the rules overlay is merged separately by `main.zig` in precedence order (`src/server/preset.zig:176`). Every committed pack is bound against the current schema by a test that fails on a stale key (`src/server/preset.zig:292`), and the file size cap is 64 KiB (`src/server/preset.zig:14`).

## Rules: sim parameters and where they enter the sim

`Rules` is the configuration surface for sim behaviour, grouped by the system that reads it and carried on `World`, read as `w.rules.<group>.<field>` (`src/ecs/rules.zig:1`). The complete surface (`src/ecs/rules.zig:796`):

```zig
pub const Rules = struct {
    systems: Systems = .{},
    combat: Combat = .{},
    c2s: C2s = .{},
    glide: Glide = .{},
    ai: Ai = .{},
    bloodmoon: Bloodmoon = .{},
    progression: Progression = .{},
    world: WorldGroup = .{},
    geometry: Geometry = .{},
    worldgen: WorldgenGroup = .{},
    vehicle: Vehicle = .{},
    director: Director = .{},
    difficulty: Difficulty = .{},
    water: Water = .{},
    power: Power = .{},
    trader: Trader = .{},
};
```

`Systems` is the one group that is behaviour rather than numbers: each entry defaults on, so the default table is the stock pipeline, and a disabled system is skipped rather than stubbed, with phase order deliberately not configurable because it encodes a real dependency (buffs before ai) (`src/ecs/rules.zig:15`). Values that stock also ships as per-entity data are floors, not replacements; the doc comment on `Combat.attack_damage` states the rule explicitly ("**Floor**: entityclasses.xml HandItem → items.xml DamageEntity wins when non-zero", `src/ecs/rules.zig:57`).

The merge happens once in `main.zig`: defaults, then the preset pack's overlay, then the operator's, then the result is assigned to `InitOptions.rules` (`src/main.zig:936`). Two groups validate fail-closed on the merged result and abort startup with the message returned by `validate` (`src/main.zig:944`). The geometry case explains the ceiling that motivates it (`src/ecs/rules.zig:585`):

```zig
    pub fn validate(self: Geometry) ?[]const u8 {
        if (self.height_scale < 0) return "[rules.geometry] height_scale must be >= 0";
        if (self.sea_level < 0) return "[rules.geometry] sea_level must be >= 0";
        if (self.height_ceiling > 255) {
            return "[rules.geometry] height_ceiling above 255 is unrepresentable (the height plane is byte in every profile)";
        }
        return null;
    }
```

At `Game.createWithOptions` the rules are installed in a single block: `self.sim.rules = opts.rules` (`src/server/game.zig:955`), plus the derived copies the block store and lock table read directly - `world.geometry` (`:958`), `world.worldgen_params` (`:961`), `sim.poi_locks.grace_ticks` (`:967`). Nothing on the tick path reads a config file; the tick reads `w.rules.*`. `sanitizeInitOptions` runs on the merged `InitOptions` before the game is created and repairs invalid stream and authority values with a warning rather than failing (`src/server/zdtd_config.zig:490`, called at `src/main.zig:1012`).

## Runtime override, and what persists

Configuration is read at startup and never written back. The one module-level record is `config.effective`, the last loaded `Config`, set by `main.zig` for the console dumps (`src/server/config.zig:438`, `src/main.zig:618`). Runtime `setgamepref` / `sg` does not touch `Config`, `zdtd.toml` or `Rules`: it parses an integer, clamps it with its own range table (documented as deliberately independent of the startup ranges), and writes the sim or `Game` field that the GameStats blob reads, for twelve known names; anything else returns false and the console replies that the pref is not runtime-writable (`src/server/admin_console.zig:987`). `getoptions` prints every applied serverconfig name, preferring the GameStats blob over the loaded config (`src/server/admin_console.zig:839`). `exportcurrentconfigs` writes that same list to `<world_dir>/exported_config.txt` (`src/server/admin_console.zig:910`), which is a diagnostic dump and not a reloadable config file. Persistence of world state is the world store's business, not this subsystem's.

Fail-closed summary, with the failure each check prevents: missing `<ServerSettings>` root (`src/server/config.zig:442`), unknown TOML key or section (`src/util/toml_bind.zig:120`), unknown enum name (`src/util/toml_bind.zig:224`), non-finite float (`src/util/toml_bind.zig:198`), preset file whose declared name differs from the filename (`src/main.zig:938`), and the geometry/worldgen validators above. Size caps bound all three readers: 1 MiB serverconfig, 256 KiB `zdtd.toml` (`src/server/zdtd_config.zig:352`), 64 KiB preset.

## See also

- [ecs.md](ecs.md) - the systems that read `Rules` on the tick path.
- [assets.md](assets.md) - the stock XML catalogs that win over `Rules` floors.
- [admin.md](admin.md) - `setgamepref`, `getoptions`, `exportcurrentconfigs`.
- [tick.md](tick.md) - the 20 TPS loop the rules parameters feed.
- [`docs/GAME_OPTIONS.md`](../GAME_OPTIONS.md) - the generated reference for every serverconfig property, `zdtd.toml` key and `Rules` field.
- [`docs/RULES_CONFIG.md`](../RULES_CONFIG.md) and [`ADR 0021`](../adr/0021-config-driven-game-modes.md) - what moved onto config, what stayed in code, and why.
