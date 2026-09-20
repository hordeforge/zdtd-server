# Wasm plugin host

This page owns the Wasm guest runtime: module loading and manifest validation, the `Hook` table, the host verbs a guest may call, fuel and memory budgets, and the reload and effect-withdrawal contract. It does not own the guest modules themselves, the sim verbs a guest may queue (those live in `ecs/command.zig` and the host-side `BotManager`), the operator policy that decides which mods load (`zdtd.toml` `[mods]` and `[plugin]`, PRD 0005), or the game events that trigger the verdict and observer hooks.

`src/plugin` is a leaf package below `server`. Its header states the dependency rule: "Dependency direction: leaf layer below server (server imports plugin, never the reverse). Must not import server, ecs, wire, world, assets, litenet, or apm. Wasm runtime may use util (io_fs) only." (`src/plugin/root.zig:6`). Nothing in `src/plugin` knows about `*Game`; the host side of every callback lives in `src/server/game/wasm_host.zig`.

Sources: [`src/plugin/root.zig`](../../src/plugin/root.zig), [`src/plugin/wasm.zig`](../../src/plugin/wasm.zig), [`src/plugin/manifest.zig`](../../src/plugin/manifest.zig), [`src/plugin/resolver.zig`](../../src/plugin/resolver.zig), [`src/plugin/api.zig`](../../src/plugin/api.zig), [`src/plugin/host.zig`](../../src/plugin/host.zig), [`src/server/game/wasm_host.zig`](../../src/server/game/wasm_host.zig), [`mods/plugin_common.zig`](../../mods/plugin_common.zig), [`docs/PLUGIN_API.md`](../PLUGIN_API.md), [`docs/PLUGIN_DEV.md`](../PLUGIN_DEV.md), [`docs/adr/0020-wasm-only-plugin-api.md`](../adr/0020-wasm-only-plugin-api.md)

## Package boundary and who calls whom

Two unrelated things share the package. The shipping plugin format is a `.wasm` module loaded by `WasmHost` (`src/plugin/wasm.zig`). The static host (`src/plugin/host.zig`, `src/plugin/api.zig`) is in-tree test scaffolding: "Product plugins are Wasm modules (`wasm.zig`); this table is not a shipping native ABI. No dynlib, no stock IModApi." (`src/plugin/api.zig:1`).

Boot order. `main` discovers manifests under `mods/` and `plugins/` (`src/main.zig:766`, `src/main.zig:769`), resolves them into a load plan (`src/main.zig:808`), and stores it on `InitOptions.plugin_plan` (`src/main.zig:820`). World init then loads through the plan, falling back to the legacy `[plugin] modules` list when no plan exists (`src/server/game/init_world.zig:363`), applies the operator queued-verb policy over every loaded slot (`src/server/game/init_world.zig:372`), and calls `on_enable` on each module (`src/server/game/init_world.zig:377`). Shutdown runs the reverse order before the stores are freed (`src/server/game/lifecycle.zig:31`).

The `Game` holds two fields. `wasm_plugins: plugin_mod.wasm.WasmHost = .{}` (`src/server/game.zig:411`) is the slot table, and `wasm_ctx: plugin_mod.wasm.HostCtx = undefined` (`src/server/game.zig:422`) is the callback context built with the Game-side functions (`src/server/game.zig:921`):

```zig
            .wasm_ctx = .{
                .data = self,
                .log_fn = &wasmLog,
                .tick_fn = &wasmTick,
                .queue_fn = &wasmQueue,
                .withdraw_fn = &wasmWithdraw,
                .sense_fn = &wasmSense,
                .query_fn = &wasmQuery,
            },
```

(`src/server/game.zig:921`.) Three `World` callbacks close the loop back into the host: `kill_verdict_fn` (`src/server/game/init_assets.zig:687`), `pre_drain_fn` (`src/server/game/init_assets.zig:710`), and `op_src_withdrawn_fn` (`src/server/game/init_assets.zig:716`). Their signatures sit on `World` at `src/ecs/world.zig:547`, `src/ecs/world.zig:576`, and `src/ecs/world.zig:584`.

## The Hook table

`Hook` is a closed `enum(u8)` of 24 tags, and the matching `names` array is the export-name vocabulary used by both the prober and the dispatcher (`src/plugin/wasm.zig:20`):

```zig
pub const Hook = enum(u8) {
    on_enable = 0,
    on_tick = 1,
    on_player_join = 2,
    on_shutdown = 3,
    on_player_death = 4,
    on_entity_killed = 5,
    on_block_damage = 6,
    on_quest_complete = 7,
    on_admin_command = 8,
    on_chat = 9,
    on_player_login = 10,
    on_player_leave = 11,
    on_player_damage = 12,
    on_quest_accept = 13,
    on_craft_request = 14,
    on_loot_roll = 15,
    on_trader_event = 16,
    on_mcp_frame = 17,
    on_trade_price = 18,
    on_perk_spend = 19,
    on_stat_changed = 20,
    on_game_event = 21,
    on_evidence = 22,
    on_buff = 23,
```

`Plugin.probeHooks` fills `hook_present[i]` once at load by asking the instance for each name (`src/plugin/wasm.zig:295`), so a missing export is free rather than a per-call lookup. `hookIndex` maps a name to its slot and returns `Hook.names.len` for a name that is not a hook, which callers must treat as a failure (`src/plugin/wasm.zig:963`).

Dispatch divides the table into three shapes. Lifecycle hooks (`on_enable`, `on_tick`, `on_shutdown`, `on_player_join`, `on_player_leave`, `on_trader_event`) are void and fan out to every slot in load order (`src/plugin/wasm.zig:1434`, `src/plugin/wasm.zig:1438`, `src/plugin/wasm.zig:1442`, `src/plugin/wasm.zig:1446`). Verdict hooks return `i32` and the walk stops at the first non-zero result, with `verdict_deny = -1` and `verdict_keep = 0` as the convention (`src/plugin/wasm.zig:1450`). Request/reply hooks write into a caller buffer and the first responder wins: chat (`src/plugin/wasm.zig:1604`), admin command (`src/plugin/wasm.zig:1615`), login deny (`src/plugin/wasm.zig:1595`), and the MCP frame router, which skips a disabled module at the routing decision rather than relying on the call to refuse it (`src/plugin/wasm.zig:1652`).

The call sites that matter for a host author, all in `server`: `onTick` late in the tick (`src/server/game/step.zig:409`), join (`src/server/game.zig:2793`), leave (`src/server/game/session_drop.zig:18`), kill and death verdicts (`src/server/game/wasm_host.zig:51`), block damage (`src/server/game/world.zig:23`), loot roll at two chokepoints (`src/server/game/loot.zig:42`, `src/server/game/chunk_fill.zig:504`), quest payout (`src/server/game/step.zig:431`), quest accept (`src/server/game/hooks.zig:396`), craft (`src/server/game/craft.zig:413`), perk spend (`src/server/game.zig:1738`), GameEvent (`src/server/game.zig:1746`), stat changed (`src/server/game.zig:1754`), evidence (`src/server/game.zig:1763`), trade price (`src/server/game.zig:322`), trader event (`src/server/game/trader_wire.zig:93`), buff (`src/server/game/social.zig:143`), chat (`src/server/c2s/misc.zig:1438`), login deny (`src/server/c2s/join.zig:150`), admin command (`src/server/admin_console.zig:1162`). Every verdict site consults the static host first and the Wasm host second, so a non-zero static verdict short-circuits the Wasm walk.

## HostCtx and the host verbs

`HostCtx` is the host side of every import call (src/plugin/wasm.zig:99):

```zig
pub const HostCtx = struct {
    /// Owner state (a *Game in the server); cast by the callbacks the owner
    /// installs. Keeps this layer free of a Game dependency.
    data: ?*anyopaque = null,
    /// Set by the loader for the duration of a discovered-mod load: a mod's
    /// manifest is a claim about its capabilities, so `_zdtd_requires` presence
    /// is fail-closed for it. False on the raw load path (in-repo test
    /// fixtures, legacy `[plugin] modules`), where `--export-all` fixtures
    /// would otherwise be refused for exporting hooks they never meant to claim.
    require_declaration: bool = false,
    log_fn: *const fn (ctx: *HostCtx, level: u8, msg: []const u8) void,
    tick_fn: *const fn (ctx: *HostCtx) u64,
    /// `src` is the 1-based wasm slot the queued command came from (0 = not
    /// attributable). The owner uses it to withdraw a disabled plugin's
    /// pending effects (paper: temporal composability).
    queue_fn: *const fn (ctx: *HostCtx, src: i16, cmd: []const u8) void,
    /// Owner withdraws `src` after a plugin's `on_shutdown` (reload) so
    /// commands queued during shutdown and applied spawns do not outlive the
    /// disposed instance. Null in tests that do not own a command buffer.
    withdraw_fn: ?*const fn (ctx: *HostCtx, src: i16) void = null,
    /// Build a read-only world snapshot into `out`, returning bytes written.
    /// 0 when the owner has no sense (a plain event plugin). Signature keeps
    /// this layer free of a Game dependency; the owner casts via `data`.
    sense_fn: ?*const fn (ctx: *HostCtx, out: []u8) usize = null,
    /// Reverse-direction point query (RFC 0001 §3): the guest writes a text
    /// request (e.g. `cover x z tx tz`) and the host writes a text response,
    /// returning bytes written (0 = no answer / unknown query). Null when the
    /// owner has no query surface.
    query_fn: ?*const fn (ctx: *HostCtx, req: []const u8, out: []u8) usize = null,
```

Two more fields carry attribution: `rt_slot` maps a zwasm runtime pointer to a slot, and `plugin_slot` maps the same index to the `Plugin`, so an import that only receives a `*Caller` can recover per-plugin state (`src/plugin/wasm.zig:131`, `src/plugin/wasm.zig:134`). `pluginForCaller` is the lookup the JSON capability uses (`src/plugin/wasm.zig:1688`).

`defineImports` registers ten field names under the `zdtd` module namespace (`src/plugin/wasm.zig:1703`); the declarable set is the `host_verbs` array (`src/plugin/wasm.zig:59`) and the `linker.defineFuncCtx` list (`src/plugin/wasm.zig:1822`). A guest imports `zdtd.log`, not `zdtd.zdtd_log` (`src/plugin/wasm.zig:1698`).

The verbs a host author has to reason about:

- `queue(ptr, len) -> i32`: attributes the command by matching `Caller.rt` against `rt_slot`; an unattributed command returns 1 and is dropped rather than being run as native (`src/plugin/wasm.zig:1726`). Game-side, `wasmQueue` drops a command longer than `max_plugin_cmd_len = 128` (`src/server/game/wasm_host.zig:65`, `src/server/game/wasm_host.zig:93`), applies the queued-verb policy first (`src/server/game/wasm_host.zig:99`), offers the line to the host `bot` family (`src/server/game/wasm_host.zig:104`), and otherwise parses it into an `ecs.command.Op` and pushes it with `pushSrc` (`src/server/game/wasm_host.zig:113`). Coordinates and HP are range-checked exactly like C2S movement (`src/server/game/wasm_host.zig:245`).
- `sense(ptr, len, token) -> i32`: copies at most `host_sense_max = 2048` bytes into the guest (`src/plugin/wasm.zig:88`, `src/plugin/wasm.zig:1744`); the guest's `len` caps the copy, so a small guest buffer gets a truncated snapshot and no error. The token argument is reserved and ignored (`src/plugin/wasm.zig:1739`). The layout is built by `wasmSense`: a 24-byte header with magic `ZBS4`, tick, world time and blood-moon flag, then fixed records, then an event trailer (`src/server/game/wasm_host.zig:290`, `src/server/game/wasm_host.zig:302`). The record length is `bot_mod.sense_record_len`, not a literal; the comment at `src/server/game/wasm_host.zig:286` still says 32-byte records while the code writes fields through offset 36, and `docs/PLUGIN_DEV.md` documents 40-byte v4 records, so treat the code and `sense_record_len` as authoritative.
- `query(req_ptr, req_len, out_ptr, out_cap) -> i32`: text request, text response, at most `query_resp_max = 64` bytes (`src/plugin/wasm.zig:91`). Recognized requests are `cover <x> <z> <tx> <tz>`, `kind <net_id>`, `quest <def_id>`, `path <sx> <sz> <tx> <tz>`, and `mcp.allowlist` (`src/server/game/wasm_host.zig:427`). Out-of-range floats return no answer instead of trapping the cast (`src/server/game/wasm_host.zig:486`).
- `config(out_ptr, out_cap) -> i32`: raw `<mod dir>/config.toml` bytes, never parsed by the host, capped at `max_config_bytes = 4096` at bind (`src/plugin/manifest.zig:18`); an absent or oversized file fails closed to no config rather than a truncated blob (`src/plugin/manifest.zig:327`).
- `json_parse` / `json_str` / `json_raw` / `json_obj`: one parsed document per plugin in a lazily allocated `json_buf_max = 64 * 1024` fixed buffer that is replaced on the next parse (`src/plugin/wasm.zig:97`, `src/plugin/wasm.zig:209`). Dot-separated key paths; string returns report the full length so the guest can detect truncation against its own buffer (`src/plugin/wasm.zig:1783`).

`log` is truncated and sanitized on the host side, not in the guest: `max_wasm_log_len = 200` and the C2S text sanitizer, because an unbounded guest string could dump player data into the operator log and C0 control bytes could forge log lines (`src/server/game/wasm_host.zig:27`, `src/server/game/wasm_host.zig:41`).

The guest-side view of the same contract is `mods/plugin_common.zig`: the `extern "zdtd"` declarations (`mods/plugin_common.zig:30`), the bounded `Buf` with `out_cap = 160` (`mods/plugin_common.zig:41`), and the `Config` helper for the minimal `key = value` format (`mods/plugin_common.zig:112`).

## Budget, fuel and disable

`Budget` is the per-instance ceiling, with the shipped defaults (`src/plugin/wasm.zig:77`):

```zig
pub const Budget = struct {
    fuel: u64 = 100_000_000,
    max_memory_pages: u64 = 1024,
};
```

Fuel is a lifetime budget, not a per-call one: it is armed once at instantiate and decremented per instruction, so a module spending roughly 10k fuel per tick silently disables after minutes at the default (`src/plugin/wasm.zig:72`). The runtime enforces both; an exhausted or trapping module is disabled while other modules keep running. `zdtd_config` clamps a zeroed `[plugin] fuel` or `[plugin] max_pages` to 1 at bind (`src/server/zdtd_config.zig:669`), and `Plugin.load` repeats the clamp because the load path is also reachable from tests (`src/plugin/wasm.zig:240`). The floor exists because a zero budget would otherwise trap every module on its first call, which reads as a silent mass-disable one tick later rather than a load error.

A hook call that traps or runs out of fuel sets `disabled = true` and logs the module and hook (`src/plugin/wasm.zig:443`). Thereafter `callHook` returns false, verdict hooks report keep (`src/plugin/wasm.zig:497`), and `WasmHost.disabledCount` counts them for admin and diagnostics (`src/plugin/wasm.zig:1677`). `fuelRemaining` exposes the runtime's accounting (`src/plugin/wasm.zig:941`).

Ceilings on composition. `max_wasm_plugins = 32` slots are inline in the host; past the ceiling the loader logs and skips, which is fail-closed on composition rather than a partial module (`src/plugin/wasm.zig:954`, `src/plugin/wasm.zig:1015`). One module may be at most `max_wasm_module_bytes = 16 * 1024 * 1024` bytes (`src/plugin/wasm.zig:956`). A module whose instance exposes no runtime handle is refused, because a queued command could not then be attributed to it (`src/plugin/wasm.zig:1164`).

## Manifest, `_zdtd_requires` and fail-closed load

`manifest.toml` is bound by the comptime TOML binder, so only declared keys bind and an unknown key aborts the load (`src/plugin/manifest.zig:200`). `Manifest.validate` then enforces the semantic rules (`src/plugin/manifest.zig:254`): `name` is required; either `wasm` or `preset` is required; the config-only form may not combine `preset` with `override`/`points`/`requires`; `icon` and `preset` must be relative paths inside the mod directory; `tier` must be `official` or `user`, since core components are native and cannot be claimed by a module; every `points` entry must be a known `OverridePoint`; every `deny` verb must be a known `QueueVerb`; and `claim_mode` may only be `exclusive`, with `chain` reserved and rejected.

The two vocabularies the manifest names are enums, not free strings. `QueueVerb` has one bit per verb and a `u16` mask so a whole policy is one integer (`src/plugin/manifest.zig:38`, `src/plugin/manifest.zig:71`); the tag names are the operator vocabulary, so there is no parallel string table to drift (`src/plugin/manifest.zig:48`). `OverridePoint` maps each dotted manifest point to the `Hook` that implements it (`src/plugin/manifest.zig:161`, `src/plugin/manifest.zig:189`).

The resolver runs once at boot and produces load order plus the claim table (`src/plugin/resolver.zig:1`). Its failure modes are all loud: a duplicate point claim names both (`src/plugin/resolver.zig:235`), a `requires` entry that does not end up in the load list is `error.RequiresUnloaded` (`src/plugin/resolver.zig:221`), a blacklisted dependency vetoes its dependent (`src/plugin/resolver.zig:158`), a second mod carrying a `preset` is `error.DuplicatePreset` (`src/plugin/resolver.zig:270`), and two mods declaring the same manifest name are a boot error because `plugin reload` could only ever address one of them (`src/plugin/resolver.zig:249`). Entries in `[mods] disabled` or `blacklist` that name a native core component are config errors (`src/plugin/resolver.zig:88`). Legacy `[plugin] modules` paths are synthesized as user-tier manifests and appended after discovery (`src/plugin/resolver.zig:287`).

`_zdtd_requires` is the module's declaration of the hooks and host verbs it needs. The ABI is a packed `i64`: low 32 bits pointer, high 32 bits length (`src/plugin/wasm.zig:349`); a length of 0 or above 4096 is an invalid range and fails the load (`src/plugin/wasm.zig:353`). Every comma-separated name must be either a hook the module actually exports or a host verb. A hook name the module does not export is `requires hook 'x' but does not export it`, and an unrecognized name is `unknown capability 'x'`; both fail loudly instead of never firing (`src/plugin/wasm.zig:365`). `sense` and `query` are accepted only when the owner installed the callback, because a module declaring one against an owner that never wired it would otherwise validate and then read zero bytes forever (`src/plugin/wasm.zig:309`).

Fail-closed applies to discovered mods only. `Plugin.load` is told `ctx.require_declaration`, and a module that exports at least one hook while declaring nothing is rejected; a module that exports no hook at all has nothing to declare and is left alone (`src/plugin/wasm.zig:335`). The loader sets the flag for each discovered mod and restores it afterwards, so the raw path (in-repo fixtures, legacy `[plugin] modules`) keeps its permissive rule (`src/plugin/wasm.zig:1034`). The load error is `RequiresUnmet` (`src/plugin/wasm.zig:137`), and `loadInto` logs the stored reason and fails the slot (`src/plugin/wasm.zig:1157`). `docs/PLUGIN_STANDARDS.md:79` states the same rule for authors.

The optional `_zdtd_api() -> i32` export lets a module declare the contract version it was built against, which the name-set check cannot see (`src/plugin/wasm.zig:400`). A version newer than `api.plugin_api_version` (currently 1, `src/plugin/api.zig:9`) is refused through the same channel as an unmet `_zdtd_requires`; an older one is accepted with a log; an absent export keeps the permissive path (`src/plugin/wasm.zig:407`). `mods/plugin_common.zig:21` carries the guest constant, and a host test asserts the shipped core plugins declare the host version (`docs/PLUGIN_API.md:50`).

One boundary worth naming: the manifest is validated but not the module. The resolver never reads the Wasm, so the loader checks host-side that a claimed override point's claimant actually exports the mapped hook, and refuses the claim with a log otherwise (`src/plugin/wasm.zig:1111`). A refused claim leaves the point on the ordinary composition path rather than silently dropping it for every other subscriber.

## Reload, withdrawal and dispose

`plugin reload <name>` implements the reload half of AGENTS rule 30. `findByName` matches an exact display name first, then a path suffix, then a `.wasm`-stem suffix, so `plugin reload bot` reaches `fps_bot.wasm` (`src/plugin/wasm.zig:1395`); the admin verb lists slots and drives the reload (`src/server/game/wasm_host.zig:527`).

`WasmHost.reload` is a dispose-then-reinstantiate cycle in one slot (`src/plugin/wasm.zig:1177`). It preserves the fields the module cannot re-derive - tier, display name, the raw `config.toml` bytes for a legacy slot, and the operator verb policy masks (`src/plugin/wasm.zig:1188`, `src/plugin/wasm.zig:1203`, `src/plugin/wasm.zig:1210`) - then calls `on_shutdown` (`src/plugin/wasm.zig:1212`), withdraws the slot's effects through `withdraw_fn` (`src/plugin/wasm.zig:1217`), and deinitializes the instance (`src/plugin/wasm.zig:1219`). Withdrawal is deliberately after `on_shutdown` and before `deinit`, because shutdown may itself queue commands or spawn bots and a pre-shutdown withdraw would miss them.

A manifest-backed slot re-reads its declaration before going live: `rereadConfig` reloads `config.toml` (`src/plugin/wasm.zig:1268`) and `reconcileClaims` rebuilds its point claims and module `deny` mask from disk, refusing a claim whose hook is absent or whose point another live module holds (`src/plugin/wasm.zig:1303`, `src/plugin/wasm.zig:1345`). The reload path applies the same `require_declaration` rule as boot for manifest-backed modules, so a module swapped on disk to drop `_zdtd_requires` cannot load here and then be refused at the next restart (`src/plugin/wasm.zig:1229`). `refreshDenied` then recombines module and operator masks and `on_enable` runs on the new instance (`src/plugin/wasm.zig:1258`).

A reload that fails to parse or instantiate does not leave a hole in the slot table. `dropDisposedSlot` compacts later modules down, re-points each moved module's `rt_slot` and `plugin_slot` backlink, and shifts or releases override-point claims (`src/plugin/wasm.zig:1361`). The Game side then remaps the numeric srcs held by the command buffer and the bot manager so later withdrawal still addresses the right module (`src/server/game/wasm_host.zig:578`).

Effect withdrawal has three entry points. The periodic pass, `takeWithdrawn`, reports the 1-based slots of modules that disabled themselves since the last call and marks each once (`src/plugin/wasm.zig:1418`); `withdrawDisabledPlugins` builds the fixed array and calls `withdrawPluginSrc` for each (`src/server/game/step.zig:655`). That function drops the src's pending commands, counts effects with no inverse in `plugin_effects_not_reverted` rather than pretending they were reverted (`src/server/game/step.zig:672`), broadcasts `NetPackageEntityRemove` for applied spawns before destroying them so a client that was told about the entity is told it is gone (`src/server/game/step.zig:681`), clears attributed glide flags, and calls `BotManager.dropFrom` (`src/server/game/step.zig:691`, `src/server/game/step.zig:697`). The third is the mid-drain gate: the pre-drain pass cannot see a module that goes disabled while an op is being applied, so `World.drainCommands` asks `srcWithdrawn` once per op (`src/plugin/wasm.zig:1670`, `src/ecs/world.zig:2011`).

Known residual, stated in the design doc rather than solved in code: `bot move`, `bot look` and `bot shoot` mutate a bot immediately at queue time inside `BotManager.handleCommand`, so a withdrawal cannot undo a hit already applied (`docs/PLUGIN_API.md:54`).

Two things are deliberately absent. There is no plugin-specific persistence: module state is live process memory, recreated from disk at boot and destroyed by `shutdown`, which deinitializes every slot in reverse order and clears the attribution tables (`src/plugin/wasm.zig:1624`). Nothing about a plugin is written to a world store. And no plugin crosses the wire: plugins cannot emit package bytes, invent wire types, or skip the join state machine (`docs/adr/0020-wasm-only-plugin-api.md:36`); the only wire traffic attributable to a plugin is ordinary sim output, such as the entity-remove broadcast a withdrawal sends.

## See also

- [Process loop and the 50 ms tick](tick.md)
- [Config loading and validation](config.md)
- [APM counters and section histograms](apm.md)
- [Plugin API (host/guest contract)](../PLUGIN_API.md)
- [ADR 0020: Wasm-only plugin API](../adr/0020-wasm-only-plugin-api.md)
