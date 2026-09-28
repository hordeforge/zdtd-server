# Wasm plugin host

This page owns the Wasm guest runtime: module loading and manifest validation, the `Hook` table, the host verbs a guest may call, fuel and memory budgets, and the reload and effect-withdrawal contract. It does not own the guest modules themselves, the sim verbs a guest may queue (those live in `ecs/command.zig` and the host-side `BotManager`), the operator policy that decides which mods load (`zdtd.toml` `[mods]` and `[plugin]`, PRD 0005), or the game events that trigger the verdict and observer hooks.

`src/plugin` is a leaf package below `server`. Its header states the dependency rule: "Dependency direction: leaf layer below server (server imports plugin, never the reverse). Must not import server, ecs, wire, world, assets, litenet, or apm. Wasm runtime may use util (io_fs) only." (`src/plugin/root.zig:6`). Nothing in `src/plugin` knows about `*Game`; the host side of every callback lives in `src/server/game/wasm_host.zig`.

Sources: [`src/plugin/root.zig`](../../src/plugin/root.zig), [`src/plugin/wasm.zig`](../../src/plugin/wasm.zig), [`src/plugin/manifest.zig`](../../src/plugin/manifest.zig), [`src/plugin/resolver.zig`](../../src/plugin/resolver.zig), [`src/plugin/api.zig`](../../src/plugin/api.zig), [`src/plugin/host.zig`](../../src/plugin/host.zig), [`src/server/game/wasm_host.zig`](../../src/server/game/wasm_host.zig), [`mods/plugin_common.zig`](../../mods/plugin_common.zig), [`docs/PLUGIN_API.md`](../PLUGIN_API.md), [`docs/PLUGIN_DEV.md`](../PLUGIN_DEV.md), [`docs/adr/0020-wasm-only-plugin-api.md`](../adr/0020-wasm-only-plugin-api.md)

## Package boundary and who calls whom

Two unrelated things share the package. The shipping plugin format is a `.wasm` module loaded by `WasmHost` (`src/plugin/wasm.zig`). The static host (`src/plugin/host.zig`, `src/plugin/api.zig`) is in-tree test scaffolding: "Product plugins are Wasm modules (`wasm.zig`); this table is not a shipping native ABI. No dynlib, no stock IModApi." (`src/plugin/api.zig:1`).

Boot order. `main` discovers manifests under `mods/` and `plugins/` (`src/main.zig:855`, `src/main.zig:859`), resolves them into a load plan and stores it on `InitOptions.plugin_plan` (`src/main.zig:910`). World init then loads through the plan, falling back to the legacy `[plugin] modules` list when no plan exists (`src/server/game/init_world.zig:378`), applies the operator queued-verb policy over every loaded slot, and calls `on_enable` on each module (`src/server/game/init_world.zig:392`). Shutdown runs the reverse order before the stores are freed (`src/server/game/lifecycle.zig:39`).

The `Game` holds two fields. `wasm_plugins: plugin_mod.wasm.WasmHost = .{}` (`src/server/game.zig:222`) is the slot table, and `wasm_ctx: plugin_mod.wasm.HostCtx = undefined` (`src/server/game.zig:222`) is the callback context built with the `game/wasm_host.zig` functions (`src/server/game.zig:222`):

```zig
            .wasm_ctx = .{
                .data = self,
                .log_fn = &game_wasm_host.wasmLog,
                .tick_fn = &game_wasm_host.wasmTick,
                .queue_fn = &game_wasm_host.wasmQueue,
                .withdraw_fn = &game_wasm_host.wasmWithdraw,
                .shift_srcs_fn = &game_wasm_host.wasmShiftSrcs,
                .sense_fn = &game_wasm_host.wasmSense,
                .query_fn = &game_wasm_host.wasmQuery,
            },
```

(`src/server/game.zig:222`.) Three `World` callbacks close the loop back into the host: `kill_verdict_fn` (`src/server/game/init_assets.zig:705`), `pre_drain_fn` (`src/server/game/init_assets.zig:728`), and `op_src_withdrawn_fn` (`src/server/game/init_assets.zig:734`). Their signatures sit on `World` at `src/ecs/world.zig:547`, `src/ecs/world.zig:576`, and `src/ecs/world.zig:584`.

## The Hook table

`Hook` is a closed `enum(u8)` of 24 tags, and the matching `names` array is the export-name vocabulary used by both the prober and the dispatcher (`src/plugin/wasm.zig:20`, `src/plugin/wasm.zig:46`):

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

`Plugin.probeHooks` fills `hook_present[i]` once at load by asking the instance for each name (`src/plugin/wasm.zig:318`), so a missing export is free rather than a per-call lookup. Each hook has its own typed entry point on `Plugin`, from `callHook` (`src/plugin/wasm.zig:498`) through `callPlayerJoin` (`src/plugin/wasm.zig:511`) and the verdict forms, and the host's fan-out walks the slots in load order.

Dispatch divides the table into three shapes. Lifecycle hooks (`on_enable`, `on_tick`, `on_shutdown`, `on_player_join`, `on_player_leave`, `on_trader_event`) are void and fan out to every slot in load order through the per-hook entry points on `Plugin` (`src/plugin/wasm.zig:511`). Verdict hooks return `i32` and the walk stops at the first non-zero result, with `verdict_deny = -1` and `verdict_keep = 0` as the convention (`src/plugin/wasm.zig:556`). Request/reply hooks write into a caller buffer and the first responder wins: chat, admin command, login deny, and the MCP frame router, which skips a disabled module at the routing decision rather than relying on the call to refuse it. A trapping or fuel-exhausted module sets `disabled`, and every later walk skips it.

A host author does not chase call sites: `server/game/plugin_compose.zig` is the single dual-host facade, one function per hook (`playerDamage` at `src/server/game/plugin_compose.zig:17` through `onTick` at `src/server/game/plugin_compose.zig:123` and `adminCommand` at `src/server/game/plugin_compose.zig:147`), and its header owns the ordering rule: a verdict returns the first non-zero result, an observer fires both hosts, an optional rewrite takes the first hit. Callers must not open-code `plugins.X` then `wasm_plugins.X`; that duplicated the policy across ~20 files, which is why the chat hook reads `plugin_compose.chatFilter` (`src/server/c2s/misc_chat.zig:19`) rather than touching either host.

## HostCtx and the host verbs

`HostCtx` is the host side of every import call (src/plugin/wasm.zig:99):

```zig
pub const HostCtx = struct {
    /// Owner state (a *Game in the server); cast by the callbacks the owner
    /// installs. Keeps this layer free of a Game dependency.
    data: ?*anyopaque = null,
    /// Set by the loader for the duration of a discovered-mod load: a mod's
    /// manifest is a claim about its capabilities, so `_zdtd_requires` presence
    /// is fail-closed for it. `loadResolved` sets it for every planned module,
    /// legacy `[plugin] modules` entries included: an operator-listed path is
    /// as much a capability claim as a discovered manifest. False on the raw
    /// `loadAll`/`loadInto` path (in-repo test fixtures), where `--export-all`
    /// fixtures would otherwise be refused for exporting hooks they never meant
    /// to claim.
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
    /// Owner remaps its per-plugin attribution after a failed reload drops the
    /// slot and later modules compact down: `dropped` is the 1-based src that
    /// left, and every surviving src above it decrements. Without it a later
    /// withdrawal targets the wrong module (paper 3.1 attribution must survive
    /// compaction). Null in tests that hold no attributed state.
    shift_srcs_fn: ?*const fn (ctx: *HostCtx, dropped: i16) void = null,
    /// Build a read-only world snapshot into `out`, returning bytes written.
    /// 0 when the owner has no sense (a plain event plugin). Signature keeps
    /// this layer free of a Game dependency; the owner casts via `data`.
    /// `src` is the 1-based slot of the plugin issuing the sense (0 = not
    /// attributable / native): the bot-damage event feed is routed to the
    /// owning fiber's drain only (paper: effects stay in their component's
    /// context), while the world snapshot itself stays shared.
    sense_fn: ?*const fn (ctx: *HostCtx, src: i16, out: []u8) usize = null,
    /// Reverse-direction point query (RFC 0001 §3): the guest writes a text
    /// request (e.g. `cover x z tx tz`) and the host writes a text response,
    /// returning bytes written (0 = no answer / unknown query). Null when the
    /// owner has no query surface.
    query_fn: ?*const fn (ctx: *HostCtx, req: []const u8, out: []u8) usize = null,
```

Two more fields carry attribution: `rt_slot` maps a zwasm runtime pointer to a slot (`src/plugin/wasm.zig:144`), and `plugin_slot` maps the same index to the `Plugin` (`src/plugin/wasm.zig:147`), so an import that only receives a `*Caller` can recover per-plugin state. `pluginForCaller` is the lookup the JSON capability uses (`src/plugin/wasm.zig:1802`).

`defineImports` registers ten field names under the `zdtd` module namespace (`src/plugin/imports.zig:24`); the declarable set is the `host_verbs` array (`src/plugin/wasm.zig:59`) and the `linker.defineFuncCtx` list (`src/plugin/imports.zig:143-152`). A guest imports `zdtd.log`, not `zdtd.zdtd_log` (`src/plugin/imports.zig:143`).

The verbs a host author has to reason about:

- `queue(ptr, len) -> i32`: attributes the command by matching `Caller.rt` against `rt_slot`; an unattributed command returns 1 and is dropped rather than being run as native (`src/plugin/imports.zig:47`). Game-side, `wasmQueue` drops a command longer than `max_plugin_cmd_len = 128` (`src/server/game/wasm_host.zig:122`, `src/server/game/wasm_host.zig:122`), applies the queued-verb policy first (`src/server/game/wasm_host.zig:122`), offers the line to the host `bot` family (`src/server/game/wasm_host.zig:122`), and otherwise parses it into an `ecs.command.Op` and pushes it with `pushSrc` (`src/server/game/wasm_host.zig:122`). Coordinates and HP are range-checked exactly like C2S movement (`src/server/game/wasm_host.zig:122`).
- `sense(ptr, len, token) -> i32`: copies at most `host_sense_max = 2048` bytes into the guest (`src/plugin/wasm.zig:88`, `src/plugin/imports.zig:52`); the guest's `len` caps the copy, so a small guest buffer gets a truncated snapshot and no error. The token argument is reserved and ignored (`src/plugin/imports.zig:53`). The layout is built by `wasmSense`: a 24-byte header with magic `ZBS4`, tick, world time and blood-moon flag, then fixed records, then an event trailer (`src/server/game/wasm_host.zig:406`, `src/server/game/wasm_host.zig:406`). The record length is `bot_mod.sense_record_len`, not a literal; the comment at `src/server/game/wasm_host.zig:406` still says 32-byte records while the code writes fields through offset 36, and `docs/PLUGIN_DEV.md` documents 40-byte v4 records, so treat the code and `sense_record_len` as authoritative.
- `query(req_ptr, req_len, out_ptr, out_cap) -> i32`: text request, text response, at most `query_resp_max = 64` bytes (`src/plugin/wasm.zig:91`). Recognized requests are `cover <x> <z> <tx> <tz>`, `kind <net_id>`, `quest <def_id>`, `path <sx> <sz> <tx> <tz>`, and `mcp.allowlist` (`src/server/game/wasm_host.zig:577`). Out-of-range floats return no answer instead of trapping the cast (`src/server/game/wasm_host.zig:406`).
- `config(out_ptr, out_cap) -> i32`: raw `<mod dir>/config.toml` bytes, never parsed by the host, capped at `max_config_bytes = 4096` at bind (`src/plugin/manifest.zig:18`); an absent or oversized file fails closed to no config rather than a truncated blob (`src/plugin/manifest.zig:18`).
- `json_parse` / `json_str` / `json_raw` / `json_obj`: one parsed document per plugin in a lazily allocated `json_buf_max = 64 * 1024` fixed buffer that is replaced on the next parse (`src/plugin/wasm.zig:97`, `src/plugin/wasm.zig:97`). Dot-separated key paths; string returns report the full length so the guest can detect truncation against its own buffer (`src/plugin/imports.zig:116`).

`log` is truncated and sanitized on the host side, not in the guest: `max_wasm_log_len = 200` (`src/server/game/wasm_host.zig:30`) and the C2S text sanitizer, because an unbounded guest string could dump player data into the operator log and C0 control bytes could forge log lines.

The guest-side view of the same contract is `mods/plugin_common.zig`: the `extern "zdtd"` declarations (`mods/plugin_common.zig:30`), the bounded `Buf` with `out_cap = 160` (`mods/plugin_common.zig:41`), and the `Config` helper for the minimal `key = value` format (`mods/plugin_common.zig:112`).

## Budget, fuel and disable

`Budget` is the per-instance ceiling, with the shipped defaults (`src/plugin/wasm.zig:77`):

```zig
pub const Budget = struct {
    fuel: u64 = 100_000_000,
    max_memory_pages: u64 = 1024,
};
```

Fuel is a lifetime budget, not a per-call one: armed once at instantiate and decremented per instruction, so a module spending roughly 10k fuel per tick silently disables after minutes at the default. An exhausted or trapping module is disabled while the others keep running. `zdtd_config` clamps a zeroed `[plugin] fuel` or `[plugin] max_pages` to 1 at bind (`src/server/zdtd_config.zig:669`), and `Plugin.load` repeats the clamp because the load path is reachable from tests too: a zero budget would otherwise trap every module on its first call, reading as a silent mass-disable rather than a load error.

A hook call that traps or runs out of fuel sets `disabled = true` and logs the module and hook (`src/plugin/wasm.zig:498`). Thereafter `callHook` returns false, verdict hooks report keep, and `WasmHost.disabledCount` counts them for admin and diagnostics (`src/plugin/wasm.zig:1780`).

Ceilings on composition. `max_wasm_plugins = 32` slots are inline in the host (`src/plugin/wasm.zig:1009`); past the ceiling the loader logs and skips, which is fail-closed on composition rather than a partial module. One module may be at most `max_wasm_module_bytes = 16 * 1024 * 1024` bytes (`src/plugin/wasm.zig:1011`). A module whose instance exposes no runtime handle is refused, because a queued command could not then be attributed to it (`src/plugin/wasm.zig:1237`).

## Manifest, `_zdtd_requires` and fail-closed load

`manifest.toml` is bound by the comptime TOML binder, so only declared keys bind and an unknown key aborts the load (`src/plugin/manifest.zig:330`). `Manifest.validate` then enforces the semantic rules (`src/plugin/manifest.zig:243`): `name` is required; either `wasm` or `preset` is required; the config-only form may not combine `preset` with `override`/`points`/`requires`; `icon` and `preset` must be relative paths inside the mod directory; `tier` must be `official` or `user`, since core components are native and cannot be claimed by a module; every `points` entry must be a known `OverridePoint`; every `deny` verb must be a known `QueueVerb`; and `claim_mode` may only be `exclusive`, with `chain` reserved and rejected.

The two vocabularies the manifest names are enums, not free strings. `QueueVerb` has one bit per verb and a `u16` mask so a whole policy is one integer (`src/plugin/manifest.zig:38`, `src/plugin/manifest.zig:38`); the tag names are the operator vocabulary, so there is no parallel string table to drift (`src/plugin/manifest.zig:38`). `OverridePoint` maps each dotted manifest point to the `Hook` that implements it (`src/plugin/manifest.zig:38`, `src/plugin/wasm.zig:1023`).

The resolver runs once at boot and produces load order plus the claim table (`src/plugin/resolver.zig:65`). Its failure modes are all loud: a duplicate point claim is `error.DuplicateClaim` (`src/plugin/resolver.zig:132`), a `requires` entry that does not end up in the load list is `error.RequiresUnloaded` (`src/plugin/resolver.zig:221`), a blacklisted dependency vetoes its dependent (`src/plugin/resolver.zig:147`), a second mod carrying a `preset` is `error.DuplicatePreset` (`src/plugin/resolver.zig:270`), and two mods declaring the same manifest name are a boot error because `plugin reload` could only ever address one of them. Entries in `[mods] disabled` or `blacklist` that name a native core component are config errors (`src/plugin/resolver.zig:86`). Legacy `[plugin] modules` paths are synthesized as user-tier manifests and appended after discovery (`src/plugin/resolver.zig:275`).

`_zdtd_requires` is the module's declaration of the hooks and host verbs it needs. The ABI is a packed `i64`: low 32 bits pointer, high 32 bits length (`src/plugin/wasm.zig:355`); a length of 0 or above 4096 is an invalid range and fails the load (`src/plugin/wasm.zig:355`). Every comma-separated name must be either a hook the module actually exports or a host verb. A hook name the module does not export is `requires hook 'x' but does not export it`, and an unrecognized name is `unknown capability 'x'`; both fail loudly instead of never firing (`src/plugin/wasm.zig:355`). `sense` and `query` are accepted only when the owner installed the callback (`src/plugin/wasm.zig:332`), because a module declaring one against an owner that never wired it would otherwise validate and then read zero bytes forever.

Fail-closed applies to discovered mods only. `probeRequires` is told whether the declaration is required, and a module that exports at least one hook while declaring nothing is rejected; a module that exports no hook at all has nothing to declare and is left alone (`src/plugin/wasm.zig:355`). The loader sets the flag for each discovered mod and restores it afterwards, so the raw path (in-repo fixtures, legacy `[plugin] modules`) keeps its permissive rule. The reasons are recorded by `requiresFailed` / `requiresFailed2` (`src/plugin/wasm.zig:448`, `src/plugin/wasm.zig:483`), the load error is `RequiresUnmet`, and `loadInto` logs the stored reason and fails the slot (`src/plugin/wasm.zig:1221`). `docs/PLUGIN_STANDARDS.md:79` states the same rule for authors.

The optional `_zdtd_api() -> i32` export lets a module declare the contract version it was built against, which the name-set check cannot see (`src/plugin/wasm.zig:466`). A version newer than `api.plugin_api_version` (currently 1, `src/plugin/api.zig:9`) is refused through the same channel as an unmet `_zdtd_requires`; an older one is accepted with a log; an absent export keeps the permissive path (`src/plugin/wasm.zig:467`). `mods/plugin_common.zig:21` carries the guest constant, and a host test asserts the shipped core plugins declare the host version (`docs/PLUGIN_API.md:50`).

One boundary worth naming: the manifest is validated but not the module. The resolver never reads the Wasm, so the loader checks host-side that a claimed override point's claimant actually exports the mapped hook, and refuses the claim with a log otherwise (`src/plugin/wasm.zig:1164`). A refused claim leaves the point on the ordinary composition path rather than silently dropping it for every other subscriber.

## Reload, withdrawal and dispose

`plugin reload <name>` implements the reload half of AGENTS rule 30. `findByName` matches an exact display name first, then a path suffix, then a `.wasm`-stem suffix, so `plugin reload bot` reaches `fps_bot.wasm` (`src/plugin/wasm.zig:1486`); the admin verb lists slots and drives the reload (`src/server/game/wasm_host.zig:639`).

`WasmHost.reload` is a dispose-then-reinstantiate cycle in one slot (`src/plugin/wasm.zig:1249`). It preserves the fields the module cannot re-derive - tier, display name, the raw `config.toml` bytes for a legacy slot, and the operator verb policy masks - then calls `on_shutdown`, withdraws the slot's effects through `withdraw_fn` (`src/plugin/wasm.zig:1292`), and deinitializes the instance. Withdrawal is deliberately after `on_shutdown` and before `deinit`, because shutdown may itself queue commands or spawn bots and a pre-shutdown withdraw would miss them.

A manifest-backed slot re-reads its declaration before going live: `rereadConfig` reloads `config.toml` (`src/plugin/wasm.zig:1355`) and `reconcileClaims` rebuilds its point claims and module `deny` mask from disk, refusing a claim whose hook is absent or whose point another live module holds (`src/plugin/wasm.zig:1390`). The reload path applies the same `require_declaration` rule as boot for manifest-backed modules, so a module swapped on disk to drop `_zdtd_requires` cannot load here and then be refused at the next restart (`src/plugin/wasm.zig:1390`). `refreshDenied` then recombines module and operator masks and `on_enable` runs on the new instance (`src/plugin/wasm.zig:1390`).

A reload that fails to parse or instantiate does not leave a hole in the slot table. `dropDisposedSlot` compacts later modules down, re-points each moved module's `rt_slot` and `plugin_slot` backlink, and shifts or releases override-point claims (`src/plugin/wasm.zig:1448`). `reload` then calls the owner's `shift_srcs_fn` (`src/server/game/wasm_host.zig:131`), which remaps the numeric srcs held by the command buffer, the bot manager and the applied glide flags so later withdrawal still addresses the right module (`src/server/game/wasm_host.zig:131`). The call lives in `reload`, not in the admin verb, so every caller of the reload cycle keeps attribution intact.

Effect withdrawal has three entry points. The periodic pass, `takeWithdrawn`, reports the 1-based slots of modules that disabled themselves since the last call and marks each once, leaving a src that does not fit the caller's array unmarked so the next pass still returns it (`src/plugin/wasm.zig:1509`); `withdrawDisabledPlugins` builds the fixed array and calls `withdrawPluginSrc` for each (`src/server/game/step.zig:687`, driven from the tick at `src/server/game/step.zig:418`). That function drops the src's pending commands, counts effects with no inverse in `plugin_effects_not_reverted` rather than pretending they were reverted (`src/server/game/step.zig:705`), broadcasts `NetPackageEntityRemove` for applied spawns before destroying them so a client that was told about the entity is told it is gone (`src/server/game/step.zig:713`), clears attributed glide flags (`src/server/game/step.zig:724`), and calls `BotManager.dropFrom` (`src/server/game/step.zig:729`). The third is the mid-drain gate: the pre-drain pass cannot see a module that goes disabled while an op is being applied, so the drain asks `op_src_withdrawn_fn` once per op (`src/ecs/world.zig:658`, wired at `src/ecs/world.zig:2081` and served by `opSrcWithdrawn`, `src/server/game/wasm_host.zig:155`).

Known residual, stated in the design doc rather than solved in code: `bot move`, `bot look` and `bot shoot` mutate a bot immediately at queue time inside `BotManager.handleCommand`, so a withdrawal cannot undo a hit already applied (`docs/PLUGIN_API.md:54`).

Two things are deliberately absent. There is no plugin-specific persistence: module state is live process memory, recreated from disk at boot and destroyed by `shutdown`, which deinitializes every slot in reverse order and clears the attribution tables (`src/plugin/wasm.zig:1727`). Nothing about a plugin is written to a world store. And no plugin crosses the wire: plugins cannot emit package bytes, invent wire types, or skip the join state machine (`docs/adr/0020-wasm-only-plugin-api.md:36`); the only wire traffic attributable to a plugin is ordinary sim output, such as the entity-remove broadcast a withdrawal sends.

## See also

- [Process loop and the 50 ms tick](tick.md)
- [Config loading and validation](config.md)
- [APM counters and section histograms](apm.md)
- [Plugin API (host/guest contract)](../PLUGIN_API.md)
- [ADR 0020: Wasm-only plugin API](../adr/0020-wasm-only-plugin-api.md)
