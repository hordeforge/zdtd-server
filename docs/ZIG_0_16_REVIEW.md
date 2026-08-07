# ZIG_0_16_REVIEW.md - Zig 0.16 changelog conformance findings

Audit of zdtd against the
[Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
(Language Changes / Standard Library / Build System sections).

| | |
|---|---|
| Date | 2026-08-07 |
| Scope | `src/` full tree scan for deprecated, renamed, removed, and 0.15-era APIs; residual-posix re-verification |
| Mode | Review only (no code changed) |
| Toolchain | Zig 0.16.0 (`/home/maci/.zvm/0.16.0`) |
| Prompt | `docs/prompts/zig-0.16-changelog-review.md` |
| Status | Findings documented; fixes pending (see Fix plan) |

## Summary

zdtd pins 0.16 and `make check` is green, so **removed** APIs are absent by
construction. The audit confirmed that and found **deprecated-but-present**
APIs only. The repository's I/O layer is already on the 0.16 model
(`std.Io` everywhere, `std.posix.system` only in the sanctioned residuals), so
the fix burden is small and semantics-preserving.

| Severity | Count | Findings |
|---|---|---|
| P1 (deprecated API on core path) | 2 | F1c `@intFromFloat` in wire parse, F2 `std.meta.Int` in interest |
| P2 (deprecated API on init/sim/test paths) | 2 | F1a `@intFromFloat` in apm percentile, F1b `@intFromFloat` in sleepers |
| P3 (test-path rename drift, comment wording) | 2 | F3 `std.mem.indexOf` in tests, F1d comment sweep |
| Clean audit | 0 | Removed-API rg returns nothing |
| Residual posix | 0 | Every `posix.*` call site matches `docs/STD_ABSTRACTIONS.md` |

## Ground truth

All four rows of the changelog's "Residual thin posix" question were
re-verified against the 0.16.0 std sources during this audit (see Residual
posix re-verification). The changelog's "posix and os.windows removals"
section is the policy anchor:

> Most `std.posix` and `std.os.windows` functions existed at an awkward
> medium-level abstraction and have thus been removed. You must now choose a
> direction: **Go higher: use `std.Io`** or **Go lower: use `std.posix.system`
> directly**. More removals are planned.

---

## F1. `@intFromFloat` is deprecated (changelog "Language Changes")

Changelog quote:

> `@floor`, `@ceil`, `@round`, `@trunc` now can be used to convert a
> floating-point value to an integer value. ... `@intFromFloat` is now
> redundant with `@trunc` and is therefore **deprecated**.

Still present in 0.16 (deprecated, not removed), so these compile. The
replacement is exact: `@intFromFloat` rounds toward zero, which is precisely
`@trunc`; and `@intFromFloat(@floor(v))` is `@floor(v)` with an integer result
type (same floor semantics, same NaN/out-of-range trap, one builtin fewer).
Wire/sim behavior must not change; the deliberate trap on non-finite or
out-of-range floats is wire safety (see F1d).

### F1a. `src/apm/metrics.zig:153` - percentile target (P2, init/read path)

```zig
const target: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(self.count)) * p / 100.0));
```

- `self.count` is `u64`; the inner `@floatFromInt(self.count)` is **correct**
  and stays (u64 does not fit f64's 53-bit significand, so no implicit
  coercion under the new small-int rule; `@floatFromInt` remains required).
- Fix: drop the `@intFromFloat` wrapper; `@ceil` forwards its result type:

```zig
const target: u64 = @ceil(@as(f64, @floatFromInt(self.count)) * p / 100.0);
```

- Semantics: `@ceil` then integer conversion, identical to before. The result
  is a whole number within `[0, count]`, always in `u64` range.
- Called from `Snapshot` reporting (apm dump / webui / admin), not the 50 ms
  tick; severity P2.

### F1b. `src/world/sleepers.zig:70-71, 78-80` - volume containment (P2, sim path)

Five identical sites across `containsXZ` and `contains`:

```zig
const xi: i32 = @intFromFloat(@floor(x));
const zi: i32 = @intFromFloat(@floor(z));
```

- Fix: the integer result type is already spelled at the declaration, so the
  conversion is implicit:

```zig
const xi: i32 = @floor(x);
const zi: i32 = @floor(z);
```

- Semantics: `floor` toward -inf, then float-to-int conversion, exactly as
  before. These run on sleeper-volume containment checks (spawn/despawn
  evaluation, tick path) but the values are volume bounds that passed the
  load-time parse, so the trap path is not the hot concern; severity P2.
- Note `@trunc` would be wrong here: truncation toward zero would flip
  negative coordinates (`-0.5 -> 0` instead of `-1`), changing containment
  near the negative axes. Keep `@floor`.

### F1c. `src/wire/packages.zig:2646` - explosion blockDamage parse (P1, wire)

```zig
if (bd > 0 and bd <= 65535) out.block_damage = @intFromFloat(bd);
```

- `out.block_damage` is `u16` (`packages.zig:2577`). The guard guarantees
  `bd in (0, 65535]`, so the conversion cannot trap and always fits.
- Fix:

```zig
if (bd > 0 and bd <= 65535) out.block_damage = @trunc(bd);
```

- Semantics: toward-zero truncation, identical to `@intFromFloat`. This is a
  C2S wire decode path; severity P1 (changelog-deprecated builtin on a wire
  path, low risk but touch priority over P2).

### F1d. Comment sweep (P3)

Two comments name the deprecated builtin. The code they describe already uses
`std.math.lossyCast` / rejects non-finite coordinates; only the wording should
catch up (the trap behavior itself is preserved by the new conversions):

- `src/wire/packages.zig:685`:
  `positions through \`@intFromFloat(@floor(v))\`, which traps on NaN/inf/huge`
  -> `positions through \`@floor(v)\` (integer result type), which traps on NaN/inf/huge`.
  The claim is unchanged: `world_coord_limit` + `readWorldF32` reject
  non-finite and out-of-range coordinates at the wire boundary, and the
  downstream conversion keeps trapping as a second line of defense.
- `src/wire/stock_entity.zig:232`:
  `// lossyCast: client-fed transforms may be NaN/inf/huge; @intFromFloat traps.`
  -> `...; float-to-int conversion traps.` (or name `@trunc` if the site is
  converted). The comment explains why `lossyCast(i32, ...)` on the
  `homePosition` write is safe: a non-finite client-fed value traps in the
  conversion, so the server cannot serialize garbage.

---

## F2. `std.meta.Int` is deprecated (changelog "Language Changes")

Changelog quote (`@Type` replacement section):

> `@Int` is perhaps the most useful new builtin ... usage is equivalent to the
> now-deprecated `std.meta.Int` helper.

`std.meta.Int` still exists (`std/meta.zig:755`) but the canonical 0.16 form
is the `@Int` builtin with identical arguments.

### F2a. `src/ecs/interest.zig:53` - observer bitmask type (P1)

```zig
pub fn ObserverMask(comptime lanes: comptime_int) type {
    return std.meta.Int(.unsigned, lanes);
}
```

- Fix (drop-in, same signature):

```zig
pub fn ObserverMask(comptime lanes: comptime_int) type {
    return @Int(.unsigned, lanes);
}
```

- Context: `ObserverMask` is the per-entity observer bit set
  (`trackedPlayers` equivalent), fanned out by the serialization-once
  interest path. The vectorized `observerMask` builds `@Vector(lanes, u32)`
  and `@bitCast`s to `ObserverMask(lanes)` (`interest.zig:75-85`); the type
  must stay `uN` with exactly `lanes` bits, which both forms guarantee.
  Severity P1: core interest path, trivially mechanical.

---

## F3. `std.mem.indexOf` renamed to `std.mem.find` (changelog "Standard Library")

Changelog quote:

> mem: introduce cut functions; rename "index of" to "find"

`indexOf` survives only as an explicit deprecation alias
(`std/mem.zig:1413-1414`: `/// Deprecated in favor of \`find\`. pub const
indexOf = find;`). New and touched code must use the `find*` family.

### F3a. `src/apm/report.zig:143-146, 158-160` - dump structure assertions (P3, tests)

Seven uses in two `test` blocks, all the same shape:

```zig
try std.testing.expect(std.mem.indexOf(u8, text, "zdtd-apm snapshot") != null);
```

- Fix: rename only:

```zig
try std.testing.expect(std.mem.find(u8, text, "zdtd-apm snapshot") != null);
```

- No behavior change: `find` is the same Boyer-Moore-Horspool /
  linear search (`find` delegates to `findPos`, `mem.zig:1419`). Severity P3
  (test-only, but the deprecated name is the kind of drift the 0.16 audit
  exists to eliminate).

---

## Clean audit: removed APIs (empty by construction)

The following were removed in 0.16 (per the release notes) and must not
appear. The audit rg returned **no hits** in `src/`:

```text
std.time.Instant / std.time.Timer / std.time.timestamp   (-> std.Io.Timestamp)
std.Thread.Pool / spawnWg                                (-> std.Io.Group.async)
ArrayHashMap / AutoArrayHashMap / StringArrayHashMap     (-> array_hash_map.*)
heap.ThreadSafeAllocator
fs.getAppDataDir
std.process.getCwd / getCwdAlloc                         (-> currentPath(io, ...))
GenericReader / AnyReader / FixedBufferStream            (-> std.Io.Reader/Writer)
std.io lower-case namespace
Thread.Mutex / Thread.Condition / Thread.ResetEvent      (-> Io.Mutex/Io.Condition/Io.Event)
{D} format specifier                                     (-> std.Io.Duration format)
builtin.subsystem
@Type( / @cImport
```

Confirmation that the migration happened on schedule: the tree already uses
`std.process.Init.Minimal` (`src/main.zig`), `std.Io.Threaded` /
`std.Io.net` (`litenet/udp_socket.zig`), `std.Io.Writer.fixed` (webui HTTP
path), unmanaged `ArrayList.empty` + allocator-arg methods, and package
dependencies live in the project-local `zig-pkg/` directory (0.16 fetch
behavior).

## Residual posix re-verification (all sanctioned)

Every `std.posix` / `posix.system` call site in `src/`, cross-checked against
`docs/STD_ABSTRACTIONS.md` and the 0.16 std sources. No drift; the residual
table in the doc is complete after the two rows added this audit session.

| Call | Site | Verified against std source |
|---|---|---|
| `posix.setsockopt` SO_REUSEADDR | `litenet/udp_socket.zig:44` | `IpAddress.bind` BindOptions has no reuse flag (`Io/net.zig:280-291`); `netBindIpPosix` sets no socket options by default (`Io/Threaded.zig:12192-12209`); the only REUSEADDR in std is the TCP `listen` path under `reuse_address` (`Io/Threaded.zig:11687`) |
| `posix.system.setsockopt` IPV6_V6ONLY | `litenet/udp_socket.zig:58` | `std.posix.setsockopt` maps EINVAL to `unreachable`; the errno probe is the sanctioned low direction. Side note: std's `ip6_only` flag is inverted vs its doc comment (sets V6ONLY=0 when true, `Io/Threaded.zig:12272-12275`); zdtd does not rely on it |
| `posix.poll` + `posix.system.accept4` | `util/tcp_listen.zig:69-85` | `Server.accept` maps EAGAIN to `errnoBug` (debug panic "programmer bug caused syscall error", `Io/Threaded.zig:12467`, `14054-14057`); `netListenIpPosix` never sets O_NONBLOCK (`Io/Threaded.zig:11674-11715`), so the listen fd blocks and std accept cannot be called on the sim thread |
| `posix.read` / `posix.system.write` / `posix.system.close` | `util/tcp_listen.zig:91,96,110` | Raw fds from `accept4`; no lightweight std.Io wrapper exists (per-connection `Io.Threaded` is the sigaction-installing cost). `writeAll`'s POLLOUT gate (`tcp_listen.zig:114-120`) has no std "write with timeout cap" equivalent |
| `posix.system.clock_gettime` / `nanosleep` | `util/clock.zig:51,67,100` | 0.16 moved time into `std.Io` (`Io.Clock.now`, `Io.sleep`); Threaded's posix `.now` is literally `posix.system.clock_gettime` plus conversion (`Io/Threaded.zig:11428-11445`). Every std time call needs an `Io`; `Io.Threaded.init` calls `getCpuCount()` and installs SIGIO/SIGPIPE handlers (`Io/Threaded.zig:1634,1652-1662`), so the Io-free vDSO leaf stays. `std.time.Instant` / `Thread.sleep` are gone; `Io.Threaded.init_single_threaded` exists (release-notes-documented "no Io handy" workaround) but is the single-thread fallback global |

All four changelog table rows ("Residual thin posix (acceptable)") are
confirmed accurate at both the options-struct and the implementation level.

## Fix plan (ordered, one theme per change)

| # | Theme | Files | Sev | PR size |
|---|---|---|---|---|
| 1 | `@Int` for the observer mask | `src/ecs/interest.zig:53` | P1 | 1 line |
| 2 | `@trunc` on the wire decode | `src/wire/packages.zig:2646` | P1 | 1 line |
| 3 | `@floor` int-result in sleepers | `src/world/sleepers.zig:70,71,78,79,80` | P2 | 5 lines |
| 4 | `@ceil` int-result in apm | `src/apm/metrics.zig:153` | P2 | 1 line |
| 5 | `find` in report tests | `src/apm/report.zig:143-146,158-160` | P3 | 7 lines |
| 6 | Comment sweep | `src/wire/packages.zig:685`, `src/wire/stock_entity.zig:232` | P3 | 2 lines |

Each change is rename-only with byte-identical semantics. Keep the deliberate
NaN/out-of-range trap (wire safety): do not wrap these in `catch` or clamp.

Do **not** touch in this pass:

- `util/clock.zig` (Io-free vDSO leaf, documented)
- `util/tcp_listen.zig` and `litenet/udp_socket.zig` residual posix
  (sanctioned, re-verified above)
- `@floatFromInt(self.count)` at `metrics.zig:153` (still required: u64 does
  not fit f64's significand, no implicit coercion applies)

## Verification

```bash
rg -n '@intFromFloat' src --type zig            # empty after fix
rg -n 'std\.meta\.Int' src --type zig           # empty after fix
rg -n 'std\.mem\.indexOf' src --type zig        # empty after fix
zig build test                                   # must stay green
make check
```

Removed-API re-audit (must stay empty forever):

```bash
rg -n 'std\.time\.(Instant|Timer)|Thread\.Pool|spawnWg|ArrayHashMap|getAppDataDir|GenericReader|AnyReader|FixedBufferStream|std\.io\.|Thread\.(Mutex|Condition|ResetEvent)|\{D\}' src --type zig
```
