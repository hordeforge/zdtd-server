# Bots: host servant and Wasm brain

This subsystem owns both halves of one contract: the host-side servant that owns every bot's body (spawn, position integration, collision, line of sight, damage, sense snapshot, replication) and the Wasm guest that owns every decision (target selection, aim, movement intent, fire request). A bot is not an ECS entity: it carries no `Kind` and no ECS columns, and the only channels between brain and world are the read-only sense buffer and the `bot <verb>` queue text (src/server/game/bot.zig:1; docs/adr/0026-fps-bot-wasm-module.md:67). The boundary ends at the queue: the guest never builds package bytes, never touches ECS or world memory, and the host never picks a target or decides to fire (src/server/game/bot.zig:8). Bot code lives in the `server` package, whose root states the direction: "top of the stack. May import all other src packages" (src/server/root.zig:3). The reverse edge is forbidden, `plugin` may not import `server`, `wire`, `world`, `ecs`, `assets`, `litenet` or `apm` (scripts/lint-architecture.sh:33), which is why the Wasm host context carries an opaque owner pointer and never a `*Game` (src/plugin/wasm.zig:99).

Sources: [`src/server/game/bot.zig`](../../src/server/game/bot.zig), [`src/server/game/wasm_host.zig`](../../src/server/game/wasm_host.zig), [`src/plugin/wasm.zig`](../../src/plugin/wasm.zig), [`src/server/game/replicate.zig`](../../src/server/game/replicate.zig), [`mods/fps_bot/fps_bot.c`](../../mods/fps_bot/fps_bot.c), [`mods/fps_bot/manifest.toml`](../../mods/fps_bot/manifest.toml).

## Ownership: which half owns what

ADR 0026 fixes the split: the guest owns "the brain: target selection, aim/leading, reaction timing, strafe/dodge decisions"; the host owns "the body: the bot entity's lifecycle, replication to clients, collision/move caps, LOS validity, and damage application" (docs/adr/0026-fps-bot-wasm-module.md:47, 49). Concretely, the guest emits only `bot spawn`, `bot move`, `bot look` and `bot shoot` (mods/fps_bot/fps_bot.c:558, 566, 572); everything else about a bot is host state mutated through `BotManager` (src/server/game/bot.zig:168). Illegal requests are dropped rather than applied: a move destination outside the coordinate envelope, a non-finite speed, a shot beyond `weapon.range + shot_range_slop`, or a shot with no clear voxel line are all no-ops (src/server/game/bot.zig:323, 326, 588).

The brain is one committed `.wasm` (`mods/fps_bot/fps_bot.wasm`), declared by a manifest the loader auto-discovers; the module declares the capabilities it needs, and a module that exports hooks without the declaration is refused at load (mods/fps_bot/manifest.toml:1; src/plugin/wasm.zig:142).

```toml
name = "fps_bot"
version = "2.5.0"
icon = "icon.png"
wasm = "fps_bot.wasm"
tier = "official"
description = "Official FPS bot brain (ADR 0026): sense -> decide -> bot <verb> commands. Auto-discovered; disable via [mods] disabled = [\"fps_bot\"]."
```

## Host data structures

Operator policy is one plain struct, filled from `[bots]` in `zdtd.toml` or a preset pack. A preset pack merges all eight knobs; the `zdtd.toml` merge copies six of them and leaves `arrival_dist` and `shot_range_slop` at their defaults (src/main.zig:998, 1002).

The bot host policy record (src/server/game/bot.zig:26):

```zig
pub const BotHostConfig = struct {
    shoot_damage: f32 = 12.0,
    headshot_multiplier: f32 = 2.0,
    spawn_spread: f32 = 2.0,
    spawn_y: f32 = 70,
    max_step_up: f32 = 1.5,
    /// Move-arrival tolerance: a bot within this distance of its destination
    /// snaps onto it (anti-oscillation). Config: `[bots] arrival_dist`.
    arrival_dist: f32 = 0.05,
    /// Host fire-range slop added to the weapon range (clanker parity):
    /// `weap.range + slop` is the LOS-gated fire gate. Config:
    /// `[bots] shot_range_slop`.
    shot_range_slop: f32 = 2.0,
    /// Host loadout pool as `tag:damage:range:pellets,tag:...` (up to 8 guns;
    /// default = the builtin bot_weapon_* pool). Empty = builtin pool.
    weapon_profiles: []const u8 = "",
};
```

The manager is a fixed 16-slot table with no heap on the tick path. Doc comments on the fields are elided below; the declarations are exact (src/server/game/bot.zig:168):

```zig
pub const BotManager = struct {
    cfg: BotHostConfig = .{},
    dmg_scale: u32 = 100,
    dmg_fp: [max_bots]u32 = .{0} ** max_bots,
    attacker_fp: [max_bots]std.atomic.Value(i32) = [_]std.atomic.Value(i32){std.atomic.Value(i32).init(-1)} ** max_bots,
    bots: [max_bots]Bot = [_]Bot{.{}} ** max_bots,
    n: usize = 0,
    floor: u32 = 0,
    floor_src: i16 = 0,
    events: [max_sense_events]SenseEvent = [_]SenseEvent{.{}} ** max_sense_events,
    ev_n: usize = 0,
    loadout: [8]BotWeapon = undefined,
    loadout_n: usize = 0,
};
```

`max_bots` is `16` (src/server/game/bot.zig:17). Per-bot weapon profiles are `damage`, `range`, `pellets`, a bounded `tag` and `tag_len`, with a builtin six-gun pool and a config-parsed pool of up to eight (src/server/game/bot.zig:63, 78, 206).

The per-bot record, verbatim including the name setter (src/server/game/bot.zig:122):

```zig
pub const Bot = struct {
    net_id: i32 = -1,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    yaw: f32 = 0,
    hp: f32 = 0,
    alive: bool = false,
    dest_x: f32 = 0,
    dest_y: f32 = 0,
    dest_z: f32 = 0,
    speed: f32 = 0,
    move_active: bool = false,
    strafe_p: bool = false,
    /// Per-bot weapon (clanker WeaponProfile diversity, host-enforced)
    weapon: BotWeapon = bot_weapon_pistol,
    /// Move-arrival tolerance from [bots] arrival_dist (set at spawn).
    arrival_dist: f32 = 0.05,
    /// Operator/console display name (bounded, no heap). The stock client needs
    /// an entity_name in the player-mesh spawn body, so bots carry one.
    name: [24]u8 = .{0} ** 24,
    name_len: usize = 0,
    /// Net id of the last entity that damaged this bot (-1 = none). The guest
    /// reads it indirectly via the damage-event sense trailer (retaliation;
    /// clanker `Bot.OnDamaged` aggro-swap parity).
    last_attacker: i32 = -1,
    /// Index into `bot_loadout_pool` (sent to the guest as a kind-4 bot-info
    /// sense record so the brain can adapt range/burst/lead to the weapon).
    weapon_id: u8 = 0,
    /// 1-based wasm plugin slot that spawned this bot (0 = native/admin).
    /// Temporal composability: a withdrawn plugin's bots are despawned so
    /// they do not outlive it (paper 3.1 held inverse, same as ECS spawns).
    src: i16 = 0,

    /// Set the display name, copying at most name.len-1 bytes (NUL-terminated).
    /// An empty name falls back to the default "Bot". Cap is a UTF-8 byte
    /// budget: never split a multi-byte codepoint (spawn body is UTF-8).
    fn setName(self: *Bot, name: []const u8) void {
        const n = if (name.len == 0) default_bot_name else name;
        const cap = utf8_util.truncLen(n, self.name.len - 1);
        @memcpy(self.name[0..cap], n[0..cap]);
        self.name[cap] = 0;
        self.name_len = cap;
    }
};
```

`Bot.max` HP (`bot_max_hp` = 100) is a guest contract, not config: the brain normalizes hurt against 100, so it deliberately stays out of `BotHostConfig` (src/server/game/bot.zig:23, 59; mods/fps_bot/fps_bot.c:654).

## The sense snapshot

One read-only snapshot is the whole read path. The guest calls `zdtd_sense(ptr, len, token)` and the host writes a flat little-endian buffer capped at `host_sense_max` = 2048 bytes (mods/fps_bot/fps_bot.c:53; src/plugin/wasm.zig:88). The `token` argument is unused; the server installs `wasmSense` as the context's `sense_fn` once at construction (src/plugin/wasm.zig:1738; src/server/game.zig:927).

The payload contract, verbatim (src/server/game/bot.zig:91):

```zig
pub const sense_record_len: usize = 40;
/// Sense kind value for a bot (RFC 0001 §3: 0 player, 1 zombie, 2 bot).
const sense_kind_bot: u8 = 2;
/// Damage-event records in the sense trailer cap (RFC 0001 §3): at most this
/// many 16-byte events follow the entity records. Bounded so the guest's
/// parsing stays fixed-size; overflow events are dropped (flavor, not fidelity).
pub const max_sense_events: usize = 8;
/// Sense event kind for a damage event (RFC 0001 §3: 3 = damage).
pub const sense_kind_damage: u8 = 3;
/// Sense event kind for a bot-info record (RFC 0001 §3: 4 = bot info). The
/// host writes one per live bot each sense pass so the guest can adapt to the
/// bot's host-assigned weapon (range/burst/lead) without a record-layout bump.
pub const sense_kind_bot_info: u8 = 4;
/// Max bot-info records in the sense trailer (one per live bot; cap = slots).
pub const max_sense_info: usize = max_bots;
/// Sense event record byte size (RFC 0001 §3): kind u8 + 3 pad, attacker i32,
/// victim i32, amount f32 - packed, little-endian.
pub const sense_event_len: usize = 16;
```

Order is header, entity records, then trailer. The header is 24 bytes (`sense_header_len`) and starts with the magic `0x3453425a` ('ZBS4'), the record count, the tick, `self_net_id`, world time and the blood-moon flag (src/server/game/wasm_host.zig:290, 302). Each record is net id, kind, self, alive, pad, x, y, z, hp, yaw, vy, target id and a wearing-glider byte (src/server/game/bot.zig:88). ECS players become kind 0, zombies and animals kind 1, traders/vehicles/turrets/loot bags/falling blocks are omitted, and live bots are appended as kind 2 after the ECS records through `BotManager.fillSense` (src/server/game/wasm_host.zig:315, 366). The trailer carries one kind-4 bot-info record per live bot (its `weapon_id` and net id), then the pending kind-3 damage events, which are drained and cleared on each pass (src/server/game/bot.zig:435, 412).

Two properties matter for anyone extending this. The snapshot is global, not scoped to one bot or one plugin: bots are selected by the kind-2 tag, the per-record `self` byte and the header `self_net_id` are written as 0, and there is no host-side range or line-of-sight filter on the records (src/server/game/wasm_host.zig:306, 326; src/server/game/bot.zig:669). The guest therefore does its own culling (vision range and cone) and identifies its roster from the kind-2 records themselves (mods/fps_bot/fps_bot.c:700, 767). The guest validates the header before trusting it: magic, a count that fits the returned bytes, then fixed strides (mods/fps_bot/fps_bot.c:289).

## The queue boundary

The write path is the `zdtd.queue` import, dispatched per queued line. Bot verbs are applied immediately at the queue call, not parked in the ECS command buffer, and anything not starting with `bot` falls through to the ECS verbs (`spawn`, `despawn`, `damage`, `glide`) (src/server/game/wasm_host.zig:91):

```zig
    if (cmd.len > max_plugin_cmd_len) {
        std.debug.print("zdtd wasm: queued command too long ({d} bytes); dropped\n", .{cmd.len});
        return;
    }
    // Interception (paper 3.2.3 / ADR 0039) runs first: a verb the effective
    // policy denies never reaches the ECS buffer or the host `bot` family.
    if (pluginVerbDenied(g, src, cmd)) return;
    // `bot <verb>` commands are host-side BotManager calls (ADR 0026), not ECS
    // ops: the BotManager owns spawn/move/look/shoot/remove/count and returns
    // true for any command starting with `bot `. Everything else falls through
    // to the ECS plugin verbs (spawn/despawn/damage).
    if (g.bots.handleCommand(g, cmd, src)) return;
```

`max_plugin_cmd_len` is 128 bytes (src/server/game/wasm_host.zig:65). `handleCommand` returns true for any line whose first token is `bot`, malformed or not, so a typo is consumed rather than leaking to the ECS parser (src/server/game/bot.zig:546). The accepted shapes are `bot spawn [name] [x z]`, `bot move <id> <x> <y> <z> <speed>`, `bot look <id> <yaw>`, `bot shoot <id> <target> [head]`, `bot remove <id|all>` and `bot count <n>` (src/server/game/bot.zig:551, 573, 592, 599, 615, 626). There is no `bot cfg` arm; skill and personality overrides live entirely in the guest (mods/fps_bot/fps_bot.c:1362, 1389).

Attribution rides the queue call. `handleCommand` receives the 1-based plugin slot as `src` and stamps it on spawned bots; `bot remove all` and `bot count <n>` act only on that slot's bots, while `bot remove <id>` removes by id regardless of owner (src/server/game/bot.zig:464, 514, 615). Operator verb policy is consulted before the bot family: denying `spawn` or `despawn` also stops `bot spawn` and `bot remove` (src/server/game/wasm_host.zig:135).

## Wiring: tick, replication, damage, lifecycle

Each tick calls `tickBots` after the sim's other per-entity work (src/server/game/step.zig:201; src/server/game.zig:1890). That call drains worker-accumulated melee, integrates every bot with a live move intent through `stepMoveCollide`, and tops the population floor back up (src/server/game/bot.zig:641). Collision is host-side: a step into a solid cell, or up a terrain step taller than `max_step_up`, is blocked and the bot slides along the free axis, then its `y` is re-grounded onto the terrain surface (src/server/game/bot.zig:734; src/server/game/world.zig:783). Because `tickBots` runs before the plugin tick (src/server/game/step.zig:408), an intent queued during `onTick` is integrated on the following tick; the guest's own tick is `on_tick`, and the module declares it in `_zdtd_requires` (mods/fps_bot/fps_bot.c:1483).

Zombie melee on bots comes from the parallel AI workers, so it accumulates as atomic fixed-point in `dmg_fp`/`attacker_fp` and is drained into attributed damage on the main thread at the start of `tick` (src/server/game/bot.zig:382, 394; src/server/game/hooks.zig:379). Player damage arrives through the C2S damage handler, which range-gates the claimed target to the interest radius, caps the claimed strength and routes to `damageFrom` so the guest gets a damage event (src/server/c2s/misc.zig:736). `bot shoot` is the guest's request and passes the host gates: range, then a 0.5-block voxel march from the shooter's eye to the target's chest (src/server/game/bot.zig:323, 326; src/server/game/world.zig:759). A bot damaging a player still passes the `on_player_damage` verdict chain before damage lands (src/server/game/bot.zig:334).

Bots replicate through their own non-ECS path against the same interest grid: spawn-on-approach as the player-mesh class, remove when a viewer leaves range or the bot dies, and `NetPackageEntityPosAndRot` while moving or on the position heartbeat (src/server/game/replicate.zig:345, 390, 437). Per-client knowledge is the `Client.known_bots` bitset, cleaned only there since the ECS reconcile does not know about bots (src/server/game/replicate.zig:348).

Admin verbs are guest-owned. `bot help`, `bot status`, `bot list`, `bot spawn`, `bot remove`, `bot count`, `bot skill` and `bot cfg` are parsed inside `on_admin_command`, and the mutating ones re-enter the host by queueing `bot spawn` / `bot remove` / `bot count` (mods/fps_bot/fps_bot.c:1268, 1300, 1337, 1349, 1359). The core reaches that hook only on the unknown-command path, so with the module absent `bot ...` stays unknown and nothing changes in the core command table (src/server/admin_console.zig:1197, 1154). Lifecycle follows the plugin framework: disabling, trapping or reloading the module withdraws its bots and clears a floor it set, and a failed reload compacts the surviving slots' `src` values (src/server/game/step.zig:697; src/server/game/wasm_host.zig:580).

Nothing about bots persists. No bot state is written by the persistence layer, and the population floor is runtime state only; the PRD lists a persistent roster across restarts as out of scope (docs/prd/0001-fps-bot.md:82).

## Gaps and fidelity notes

- The host does not filter the sense snapshot by distance or line of sight; every alive networked player, zombie, animal and bot lands in the buffer, and the guest culls (src/server/game/wasm_host.zig:313). The guest's comment about the host hiding entities behind LOS (mods/fps_bot/fps_bot.c:867) is not implemented in the snapshot builder as of this reading (mods/fps_bot/fps_bot.c:880).
- `[bots] arrival_dist` and `[bots] shot_range_slop` are parsed into the config struct (src/server/zdtd_config.zig:286, 287) but the `zdtd.toml` merge never copies them onto `BotHostConfig`; a preset pack does (src/main.zig:998, 1002).
- ADR 0026 lists `bot cfg <id> <key> <val>` as a host verb (docs/adr/0026-fps-bot-wasm-module.md:109) and mentions a `BotDef` component; the shipped host has neither, and `bot skill` / `bot cfg` are guest-local state (mods/fps_bot/fps_bot.c:1362, 1389).
- `docs/IMPLEMENTATION_PLAN_BOTS.md` still describes bots as an ECS `Kind` with a `BotDef` column and `is_mob` replication, with line references that no longer resolve; the ADR 0026 amendment and `src/server/game/bot.zig:1` supersede it.
- Two doc comments still say a 32-byte sense record (src/server/game/bot.zig:655; src/server/game/wasm_host.zig:286) while the record is 40 bytes (src/server/game/bot.zig:91).
- Stock fidelity: a bot reaches the client as a stock player-mesh entity spawn plus `PosAndRot`, built by the stock builders (src/server/game/replicate.zig:390). No stock-client proof of bot appearance is cited in this page's sources; the integration test drives the committed guest through the host sense/queue boundary, which proves self-consistency, not stock compatibility (src/plugin/wasm.zig:3061).

## See also

- [interest.md](interest.md) - the observer grid bot spawn and range-remove use
- [tick.md](tick.md) - where `tickBots` and the plugin tick sit in the 50 ms budget
- [c2s.md](c2s.md) - the damage path that can target a bot
- [../adr/0026-fps-bot-wasm-module.md](../adr/0026-fps-bot-wasm-module.md) - the host/guest decision and its amendment
- [../IMPLEMENTATION_PLAN_BOTS.md](../IMPLEMENTATION_PLAN_BOTS.md) - original milestones (partly superseded)
