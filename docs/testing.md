# Testing and evidence

> **What this is:** the evidence tier policy for zdtd: which gates exist, what
> each one proves, and the rules that keep a green suite meaningful.
> **Related:** [AGENTS.md](../AGENTS.md) · [APM.md](APM.md) ·
> [CLIENT_PLAYTEST.md](CLIENT_PLAYTEST.md) · [STATUS.md](STATUS.md)

## The evidence rule

zdtd encodes and decodes with its own code, so a green round trip proves
self-consistency, not stock compatibility (`docs/INDEX.md:7`). A claim about
stock behaviour needs an IL anchor under
[the IL dumps](../../7dtd-engine-research/il/) or an observation
from the real client with EAC off (`docs/INDEX.md:8`). A field-order mistake
survives any test that asserts shape, length, or "not empty", because the same
wrong order is used on both sides. Only the stock `Read` or the disassembly
settles which order is stock.

Every gate below is judged against that rule. A green suite is a statement
about zdtd's internal coherence, never about the client.

## The gate ladder

| Gate | Command | Proves | Cannot prove |
|---|---|---|---|
| Unit and scenario tests | `zig build test` (`Makefile:88`) | Wire goldens, sim units, in-process join, spawn, chunk and inventory paths | Stock client `Read` survival, mesh, UI, scale |
| Lint | `make lint` (`Makefile:140`) | Static invariants: fmt, script syntax, import cycles and edges, package-id rules, plugin and webui freshness, docs honesty | Anything at runtime |
| Full local gate | `make check` (`Makefile:172`) | The above plus provenance coverage, XML audit, build, test, fuzz | Stock compatibility, throughput |
| Release | `make release` (`Makefile:115`), `make release-check` (`Makefile:165`) | A pinned, stripped operator artifact with a hash and buildinfo record | Gameplay correctness |
| Release smoke | `make smoke` (`Makefile:206`), `make smoke-modlet` (`Makefile:211`) | The shipped binary starts, parses `--version`/`--help`, is stripped, and one tick completes | Wire fidelity under a real client |
| Loadgen smoke | `scripts/auto_join.sh`, `scripts/smoke-navezgane.sh`, `scripts/ab-join-smoke.sh` | Join volume, map load, A/B stage parity against the stock dedi | Full client parse beyond the loadgen stages |
| Stock client | [CLIENT_PLAYTEST.md](CLIENT_PLAYTEST.md) | The client stayed alive and observable state matches | CPU scale |
| Performance | APM dump ([APM.md](APM.md)) | Tick cost against the 50 ms budget | Stock compatibility |

The unit gate builds `src/main.zig` as its root (`build.zig:82`), so a test only
runs when its file is reachable from a `root.zig` barrel. A file missing from
the barrel, or a barrel import without its matching `_ = name;`, silently drops
tests; `scripts/lint-architecture.sh:58` fails that case. The gate also builds
`mods/plugin_common.zig` as its own host test binary (`build.zig:121`), because
that guest helper is outside the server import graph.

`make lint` runs `zig fmt --check`, `bash -n` and `shellcheck` over `scripts/`,
the architecture edge and barrel check (`scripts/lint-architecture.sh:30`), the
cycle check, the wire check (`scripts/lint-wire.sh`), the plugin freshness
check (`scripts/lint-plugins.sh`), the webui and HTML checks, and
`tools/check_docs.py` (`Makefile:158`). It proves the tree is coherent; it runs
no game code.

`make check` (`Makefile:173`) chains release-check, lint, a Python syntax gate,
`tools/provenance_scan.py`, the `docs/provenance.html` freshness diff,
`make check-xml-audit` (`Makefile:202`), build, test and fuzz. The XML audit
proves stock data is read rather than hardcoded, and it skips with a notice when
no game dir is present (`Makefile:197`). When a warm cache
is suspect, run `make check-clean-build` (`Makefile:83`): a stale object can
hide a latent exe-only compile error from both `build` and `test`.

`make release` depends on release-check, so a version-drifted tree cannot
produce a binary (`scripts/check-release.sh:66`). `make repro` (`Makefile:218`)
rebuilds twice and requires byte-identical output; it is deliberately outside
`make check`.

The loadgen scripts are invoked directly; only `smoke-modlet` has a Makefile
target. `scripts/smoke-navezgane.sh:77` fails the run when the stock DTM did not
load, and `scripts/smoke-navezgane.sh:89` then requires every bot join to pass.
`scripts/ab-join-smoke.sh:1` runs the same
loadgen against the stock dedi and zdtd on one game dir and prints both stage
lines, which is the closest thing to a client-side A/B that runs unattended.

## The scenario harness

`src/server/scenarios.zig` drives shipped handlers in process, not mocks
(`src/server/scenarios.zig:2`). `harness.attachJoinedClientAs`
(`src/server/game/harness.zig:36`) walks a real join: connect, challenge echo,
`NetPackagePlayerLogin`, `NetPackageRequestToEnterGame`,
`NetPackageRequestToSpawnPlayer`, all through `Game.onData`. `injectFramed`
(`src/server/game/harness.zig:89`) sends any later package, and `replicateNow`
(`src/server/game/harness.zig:94`) runs the interest pass.

Representative coverage: join bundle completeness
(`src/server/scenarios.zig:6509`), paced spawn-area streaming
(`src/server/scenarios.zig:8295`), deco beyond the join window
(`src/server/scenarios.zig:2778`), inventory move/drop/place/equip
(`src/server/scenarios.zig:4998`), stock inventory transactions
(`src/server/scenarios.zig:13473`), and persist across a restart
(`src/server/scenarios.zig:2687`). Extend this file when a change crosses
systems; do not duplicate the harness (`AGENTS.md:286`).

## Prove the guard fails

A check guards only if the regression turns it red. Two mechanisms enforce that.

`src/fuzz.zig` runs coverage-guided targets over every untrusted parser boundary
(`src/fuzz.zig:1`) through `make fuzz` (`Makefile:91`).

`tools/wire_order_mutants.py` swaps each adjacent pair of same-width writes in a
positional builder, runs the suite, and reports survivors
(`tools/wire_order_mutants.py:12`). A survivor is a test gap, not a code bug:
two adjacent writes of the same type and constant emit identical bytes, so the
suite passes either way. It is not part of `make check` (one suite run per
mutant, hours), refuses to start on a dirty tree, edits `src/wire/` in place,
and must not run beside an editor or another build
(`tools/wire_order_mutants.py:20`).

## Rules that keep the suite meaningful

- Tests never write into the repository (`AGENTS.md:289`). Use
  `std.testing.tmpDir` and pass the path in.
- A scenario that needs a world owns it and removes it first
  (`src/server/scenarios.zig:77`). Leaked state fails the second `make check`
  (`AGENTS.md:290`).
- Prefer the real implementation. Mock only the expensive or nondeterministic
  boundary: the virtual clock (`src/util/clock.zig:25`, used at
  `src/server/scenarios.zig:194`), the RNG, or the socket. The harness gives a
  peer a fabricated address instead of opening one
  (`src/server/game/harness.zig:46`).
- Instrument new hot-path cost with `apm` sections or counters rather than
  guessing (`AGENTS.md:245`).
- Every new `src/` file needs a `docs/PROVENANCE.md` row, or
  `tools/provenance_scan.py` fails `make check`.

## Where performance judgement comes from

The performance record is a zdtd APM dump, never a `7dtd-server-apm` session
(`AGENTS.md:52`, `docs/APM.md:8`). A bounded `--ticks N` or `--once` run prints
the text dump on exit, an unbounded run emits one `{"type":"zdtd_apm",...}` line
per minute on stdout, and admin `apm` prints the same counters on demand
(`docs/APM.md:137`). Compare builds by running both with the same `--ticks`
value and the same loadgen profile (`docs/APM.md:256`).

## See also

- [AGENTS.md](../AGENTS.md) the standing rules these gates enforce
- [docs/AGENTS.md](AGENTS.md) where each fact lives and the doc gates
- [APM.md](APM.md) counters, sections, and dump formats
- [CLIENT_PLAYTEST.md](CLIENT_PLAYTEST.md) the stock-client oracle
- [STATUS.md](STATUS.md) what currently passes
