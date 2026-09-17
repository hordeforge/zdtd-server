# Zig language best-practices review snapshot - 2026-09-12

**Prompt:** `docs/prompts/zig-best-practices-review.md`
**Mode:** review only (session override: no source edits, no repo-wide gates)
**Scope:** `src/` whole tree (151,405 Zig lines, 150 files), structure / filenames /
naming / comptime / `@builtin` / zero-cost. Revision `3d408904`.
**Evidence method:** ripgrep + targeted `read`; every finding traced to a real call
site or line. No `make check` / `zig build` (session contract); no fixes applied.
**Non-overlap:** `@intFromFloat` (10 sites, deprecated in 0.16) is left to
`zig-0.16-changelog-review.md`; allocator/error/tick-memory idiom is left to
`zig-idiomatic-review.md`; macro placement/hardcode verdicts to their own prompts.

Repo line count: `rg -c`/`wc -l` over `find src -name '*.zig'` = 151,405 total;
`src/server/scenarios.zig` 17,399, `src/wire/packages.zig` 7,333,
`src/ecs/systems.zig` 7,125, `src/server/game.zig` 3,918.

## A. Folder structure and layering

| Check | Result | Evidence |
|---|---|---|
| Concern in owning package | PASS | bodies in `wire/stock_*.zig`; `world` has no wire import; metrics in `apm` |
| `world` -> `wire` imports | PASS (none) | `rg '@import' src/world \| grep wire` empty |
| Facades `*/root.zig` complete | PASS | 9 facades (`apm assets ecs litenet plugin server util wire world`); `wire/packages.zig` re-exports every `stock_*.zig` |
| Subfolder aggregation | PASS | `src/server/root.zig:29-80` imports all 44 `game/*` + 7 `c2s/*` with `_ = x;` |
| `main.zig` stays thin | PASS | 1,324 lines; `main()` at `src/main.zig:303` plus flag helpers; test block at 1,238; no package body (only test `buildPosAndRotBody` at `:1312`) |
| One shape -> one builder | PASS | no duplicate `build*Body` names across `wire/`; no `build*Body` defined outside `wire/` |
| System boundaries | PASS | `scripts/lint-architecture.sh` + `scripts/lint-cycles.sh` already enforce the edge set and the `src/server/` cycle exemption |
| No god-files | **FAIL** | see S1 |
| Package-vs-folder name collision | **FAIL (nit)** | see S2 |
| Sibling placement | **FAIL** | see S3 |

### S1 (P1, structure, report only) `src/server/game.zig` is not the documented facade

`AGENTS.md` Layout says `src/server/game.zig` is "join SM; delegating facade - most
paths in game/*, c2s/*". Reality at `3d408904`: 3,918 lines, `pub const Game` at
`:347`, 203 struct fields, 330 `pub fn`, 49 private `fn`, 73 top-level `pub`. Of the
330 methods, 226 are one-line `return game_xxx.fn(self, ...)` forwarders (215 match
`return game_[a-z_]+\.`, 20 `return @import(...)`, e.g. `:3761`, `:3773-3774`,
`:2120`, `:2121-2123`). So the file is simultaneously the `Game` struct owner *and* a
235-line forwarding layer *and* the home of real logic that has not been extracted
(`buildLoginGsiText` `:2095-2118`, `clampKnownStacks` `:1120`, `pollMcp` `:1445`,
`appendUnlockedRecipes` `:1576`). The 44 `game/*` helpers each import back via
`@import("../game.zig")`, the sanctioned `Game <-> game/*` cycle
(`scripts/lint-cycles.sh:3-5`). Report only: a split needs sign-off, and the
delegation is load-bearing for `&Game.pumpAcks`-style fn pointers
(`src/server/game/net_handlers.zig:24`), so every forwarder must be checked before
deletion.

### S2 (P3, report only) `src/server/game.zig` and `src/server/game/`

A file and a directory share the basename `game` in the same directory. Imports are
unambiguous (`game.zig` vs `game/net.zig`) and the layout table documents both, but
the pairing is what let S1 grow: the struct home reads as "the game module" while 44
real domains sit under it.

### S3 (P2, structure, report only) `src/server/replicate_te.zig` placement

Top-level `src/server/replicate_te.zig` holds TE replication while its peers live in
`src/server/game/`: `game/replicate.zig`, `game/replicate_health.zig`,
`game/trader_wire.zig`, `game/sleepers.zig`. Its own header
(`replicate_te.zig:1-13`) argues for `*Game` free functions, which the `game/*`
files also use. `src/server/root.zig:27` re-exports it as one more top-level
`server.*`, so the split is invisible at the facade. Not a cycle, not a boundary
break; a cohesion/placement drift.

### S4 (P3, note) split ingress dispatch

`src/server/game/net_handlers.zig:1` owns `onConnected`/`onData`/`dispatchGamePayload`
while `src/server/c2s/dispatch.zig:1` owns `handlePackage`; `game.zig:2085-2091` and
`:2120` forward to both. Two dispatch surfaces, one C2S fanout. Fine today; note it
before adding a third.

## B. Filenames

| Check | Result | Evidence |
|---|---|---|
| `snake_case.zig` under `src/` | PASS | `find src -name '*.zig' \| grep -vE '/[a-z0-9_]+\.zig$'` empty |
| `stock_*.zig` for wire bodies | PASS | 12 `stock_*.zig` bodies (`stock_buff/chunk/deco/entity/inv/nameid/party/quest/sign/te/xp`) + `platform_user.zig`, `binary.zig`, `frame.zig`, `te_types.zig` |
| Facades exactly `root.zig` | PASS | nine `root.zig`, no `mod.zig`/`index.zig` |
| No scattered `*_test.zig` | PASS | none; harness is `src/server/scenarios.zig` + `src/server/game/tests.zig` |
| Filename matches primary decl | PASS with one exception | `game.zig` holds `Game` but is 226/330 forwarders (S1) |
| Fixtures under `assets/fixtures/` | PASS | no fixture blobs sit next to source |
| Non-snake outside `src/` | PASS | `worlds/ mods/ plugins/ presets/` have no spaces/uppercase in names; the only hits are an untracked `.claude/worktrees/` copy |

## C. Naming and capitalization

| Location | Current form | Canonical form | Sev |
|---|---|---|---|
| `src/protocol.zig:53` | `pub fn y_pow(self) u8` | `pub fn yPow(self) u8` | P2 |
| `src/protocol.zig:57` | `pub fn c_max_height(self) u32` | `pub fn cMaxHeight(self) u32` | P2 |
| `src/protocol.zig:64` | `pub fn plane_cells(self) u32` | `pub fn planeCells(self) u32` | P2 |
| `src/wire/packages.zig:1721`, `src/wire/stock_deco.zig:652` | `makeChunkKey` (fn/alias) | `makeChunkKey` is idiomatic camelCase, but the module mixes it with `usize`-typed `chunk_body_size`/`chunk_stock_envelope_overhead`; leave the name, note the module style mix | P3 |
| `src/util/io_fs.zig:250,271,288`, `src/plugin/wasm.zig:2296` | `p_buf`, `p_plain` | `path_buf`, `plain` | P3 (test-only) |
| `src/plugin/manifest.zig:49` | `pub fn parse(s) ?QueueVerb` | `pub fn parseVerb(s) ?QueueVerb` (verb+object) | P3 |
| `src/plugin/manifest.zig:171` | `pub fn parse(s) ?OverridePoint` | `pub fn parsePoint(s) ?OverridePoint` | P3 |

Naming table conformance, everything else checked:

- Functions camelCase: PASS except the three `WireProfile` accessors above. Every
  other snake_case `pub fn` hit in `src/` is one of those three (`rg 'pub fn
  [a-z0-9]+_[a-z]' src` = exactly `protocol.zig:53,57,64`). `isStock`/`validate`
  in the same struct (`protocol.zig:70,74`) show the intended casing.
- Variables/fields `snake_case`: PASS (203 `Game` fields, `game/*` params).
- Types PascalCase: PASS (`rg '^pub const [a-z][A-Za-z0-9_]* = (struct|enum|union)'`
  empty).
- Constants `snake_case`: PASS (`rg '^pub const [A-Z]... = <value>'` returns only
  type aliases, error sets and fn-type aliases, which are types, not constants).
- Stock type/package names: PASS (`NetPackagePlayerId`, `stock_te`, `PackageName`).
- Flags named for what they do; no `world_enabled`/`is_not_*`/`has_no_*`: PASS
  (`rg 'world_enabled|is_not_|has_no_|no_' src` empty).
- No hungarian `m_`/`g_`: PASS. `p_*` only at the four test-local sites above.
- Acronyms: PASS (`IpAddress` `util/tcp_listen.zig:12`, `Udp` at stock strings).
- `pub` only for intended API: PASS in aggregate (the 235 forwarders are reachable
  by definition; the three `pub`-without-external-callsite hits found by script are
  self-recursive or nested types: `appendUnlockedRecipes`, `clampKnownStacks`,
  `pollMcp`, `CommandLevel`).
- Booleans positive: PASS on the checked names.

## D. Comptime discipline

| Location | Current form | Classification | Sev |
|---|---|---|---|
| `src/ecs/components.zig:590-596`, `src/wire/stock_inv.zig:38-42` | `@compileError` grading ECS widths against stock widths | good: layout invariant fails at compile time | - |
| `src/wire/packages.zig:277-281` | `@setEvalBranchQuota` + duplicate-name `@compileError` over `default_mappings` | good: closed-set uniqueness at compile time | - |
| `src/assets/sandbox_presets.zig:72`, `src/world/biomes.zig:49` | `@setEvalBranchQuota` | good: bounded comptime parse, documented | - |
| `src/util/toml_bind.zig:108-164,225-245` | `inline for (std.meta.fields(T))` reflection binder | good: one binder, ADR 0021; init-time not tick | - |
| `src/ecs/rules.zig:1110-1111` | `std.meta.fields(A/B)` overlay diff | good | - |
| `src/server/preset.zig:445-446` | nested `inline for` over `Rules` groups | good: init-time, banded | - |
| `src/plugin/manifest.zig:46,50,94,167,172` | `std.meta.tags(...)` + index into `names[i]` | **drift**: non-canonical 0.16 form, and a parallel name table | P2 (C4) |
| `src/apm/tracy.zig:43,51,56` | `pub inline fn zone/end/frameMark` | good: 1-3 line hot helpers, compiled out when `active=false` | - |
| `inline for` count 52, `inline fn` 3 | bounded, mostly <= 16 fields | no large unroll found | - |

`@compileLog` unused; no `comptime` that re-parses XML per build; no `comptime` file
I/O. `@tagName` is already used at 19 sites, so the C4 fix has house precedent.

## E. `@builtin` audit (canonical hits listed once, drift in the table)

Canonical, leave: `@memcpy`/`@memset` used broadly; `@bitCast` 0.16-correct;
`@intFromEnum`/`@enumFromInt`, `@intFromBool`, `@min`/`@max`, `@field`/`@hasField`;
`@splat`/`@Vector` in `wire/stock_chunk.zig`; `@branchHint` absent but not required;
no `@cImport`; no `@setRuntimeSafety` anywhere; no `std.crypto.random` on the sim
path (`src/util/rng.zig:4` states the rule).

| Location | Current form | Canonical form | Sev |
|---|---|---|---|
| `src/plugin/manifest.zig:46,167` | `std.meta.tags(T).len` | `@typeInfo(T).@"enum".fields.len` | P2 |
| `src/plugin/manifest.zig:50,172` | `inline for (std.meta.tags(T), 0..) \|t, i\| ... names[i]` | `inline for (@typeInfo(T).@"enum".fields) \|f\| { const t = @field(T, f.name); ... @tagName(t) }` | P2 |
| `src/wire/stock_chunk.zig` (29 `@truncate`) | vector lane narrowing `@truncate(vec)` | justified: SIMD byte packing, each lowers to a shuffle/pack | - |
| `src/wire/binary.zig:178-183` | `@truncate((v & 0x7F) \| 0x80)` with a comment naming the lossy intent | canonical per the prompt ("named const or comment") | - |
| `src/wire/frame.zig:388-393` | `@truncate(i)` folds a usize counter, comment at `:388-390` | justified test filler | - |
| `src/wire/packages.zig:1725,1731` | `@truncate(key)` / `@truncate(key >> 16)` on i64 -> i32 | justified by the `extractX`/`extractZ` sign-extension comments; these are *decoders*, so a `@truncate` here is the documented stock semantics, not a bounds bug | - |
| `src/wire/stock_deco.zig:382-384` | `@truncate(p >> 32/16/0)` to u16 then `@intCast` | justified: unpacking 3 packed 16-bit signed coords, after `@intCast` | - |
| `src/wire/stock_nameid.zig:72,74` | 7-bit varint byte emit | justified | - |
| `src/ecs/*`, `src/world/noise.zig`, `src/litenet/*` `@truncate` | hash/PRNG byte folding | justified, cold or hashing | - |
| 60 `@ptrCast` sites | mostly `@ptrCast(@alignCast(ctx.?))` in C-callback thunks (`game.zig` 18, `game/hooks.zig` 29, `plugin/wasm.zig` 11) | sanctioned `*anyopaque` ctx pattern; each already carries the alignCast | P3 (add nothing) |
| `src/world/noise.zig` (7) | `@truncate` in hash | justified | - |

## F. Zero-cost abstractions

| Location | Finding | Sev |
|---|---|---|
| `src/ecs/aidirector.zig:316-363` | 7 optional `*const fn` hooks. This is the sanctioned C-ABI seam (fixtures supply classes at init), not a runtime-polymorphism table that comptime should replace; dispatch happens on a cold spawn path, not per tick. Classified canonical. | - |
| `src/plugin/api.zig:44-71`, `plugin/host.zig:35` | static plugin vtable, null-checked hooks, documented "zero cost beyond a null check" | - |
| `src/plugin/manifest.zig:47,169` | parallel `names` tables next to the enum (zero-cost + single-source-of-truth smell) | P2 (C4) |
| `src/server/game.zig` 235 forwarders | a runtime call per forwarder for pure delegation that could be a direct import; measurable, but the O2 fix is a decision, not a patch | P2 (S1) |
| `src/util/toml_bind.zig` `HashMap` in `assets/*` | init/load maps, not tick | - |
| No `@call(.always_inline)`, no `std.meta.Int`/`std.meta.Tuple` | PASS | - |

## G. API surface and documentation

- File-level `//!`: PASS, 0 of 150 files missing a first-line `//!`.
- Wire-field RE citations next to writes: PASS (`stock_deco.zig:647`, `trainer`
  cites, `frame.zig:388`).
- Named caps over magic numbers on wire/tick paths: broadly PASS
  (`chunk_body_size`, `chunk_stock_envelope_overhead` at `packages.zig:1716,1718`);
  the remaining literals are scratch-buffer offsets, which are layout, not caps:
  `game.zig:2606,2672,2698`, `game/tick.zig:906` (see U1).
- One obvious way: PASS for encoders and FS helpers (`util/io_fs.zig`).

## Ordered fix plan (renames first, structure last)

Because this run is review-only, no patch was applied. In the order a fixing agent
should take them:

1. `src/plugin/manifest.zig:46,50,94,167,172` - drop `std.meta.tags`, drop the
   `QueueVerb.names` parallel table, parse via `@tagName` (C4).
2. `src/protocol.zig:53,57,64` + 6 call sites (`:75,76,107,115-117,124-126`,
   `src/world/store.zig:1297`-style locals are unrelated) - camelCase the three
   `WireProfile` accessors (C1).
3. `src/plugin/manifest.zig:49,171` + call sites (`manifest.zig:81,285`,
   `plugin/wasm.zig:1082,1249`) - `parse` -> `parseVerb` / `parsePoint` (P3,
   cheapest to do while already in the file).
4. `src/server/replicate_te.zig` -> `src/server/game/replicate_te.zig` (S3) plus the
   `src/server/root.zig:27` + `game.zig` call-site updates. Needs sign-off: it moves
   a file and touches imports.
5. `src/server/game.zig` forwarder thinning (S1): delete the 226 one-line
   forwarders, update callers to `game_xxx.fn(g, ...)`, keep only the forwarders
   whose address is taken (`Game.pumpAcks` `net_handlers.zig:24`) and the five
   nested `pub const` types. Expect roughly -450 lines from `game.zig`. Needs
   sign-off and a green `zig build test`; do it as its own change, never mixed with
   the renames above.

## Unverified / out of reach in this run

- No compile or test execution: `zig build`/`make check` were excluded by the
  session contract. Renames 1-3 are textually verified against every call site
  (`rg`), but not compiler-verified.
- Line counts for `game.zig` after the S1 thinning are estimates from the forwarder
  count (226 x ~2 lines), not a measured diff.
- `src/util/toml_bind.zig` `inline for` over `Rules` group overlays was read but not
  measured for compile-time cost (no `-ftime-report` run).
- `.claude/worktrees/wf_fdd94748-d8f-7/` is an untracked worktree copy of `src/`;
  its files were excluded from counts and findings.
