# Reusable prompt: zdtd provenance re-review

**Hub:** [`INDEX.md`](INDEX.md). **Owns:** the copy-paste agent prompt for
re-running the provenance review against the current research corpus.
**Discovered by `~/review-prompts`:** the name ends in `-review.md`, so the
review-loop tool picks it up when run with this repo as the working directory
(a project-local prompt wins over a bundled one of the same name).

Copy the block below into a fresh agent session to re-run the provenance review
against the current research corpus. It encodes the method, the gates, and the
honesty rules that make the review repeatable. Adjust the "stock pin" line if
the game build changes.

---

```
# Task
Review the zdtd clone repo for provenance completeness: every behavior, perk,
value and constant must map back to the stock 7 Days to Die dedicated server
through the research corpus. Reach 100% coverage, then keep improving the
research itself (new IL pins, live verification, tooling) as the loop.

# Layout (siblings under the workspace root)
- RESEARCH: 7dtd-research/  - stock-engine RE corpus (docs/, tools/, il/)
- ZDTD:     zdtd/          - this repo (src/, docs/PROVENANCE.md)
- LOADGEN:  7dtd-loadgen/  - bot load + LIVE-VERIFICATION RIG (boots the stock
  dedicated server for observing real behavior)
- Stock game data: "$HOME/.local/share/Steam/steamapps/common/7 Days to Die
  Dedicated Server" (Assembly-CSharp.dll in .../7DaysToDieServer_Data/Managed/,
  stock XML in .../Data/Config/, shipped worlds in .../Data/Worlds/)
- Stock pin: V3.1.0 (b14). If the game updates, regenerate il/ dumps first
  (research tools/build.sh + dumpers) and re-check docs/coverage.md census.

# What "provenance" means here (docs/PROVENANCE.md)
Three buckets per file/constant:
  A = stock DATA (must be read from the operator install, never hand-copied)
  R = stock behavior reproduced from RE (cite ../7dtd-research/docs/<doc>.md
      section, or asm.il offset; fix code to match RE, never the reverse)
  Z = zdtd-owned policy (explicitly not a provenance claim)
The gate is tools/provenance_scan.py: 188/188 files + every file-scope typed
constant carries an inline provenance comment. Mark honest status everywhere:
verified / inferred / diverges / not-implemented. NEVER silently mark a
divergence as matching.

# Method (repeat for each pass)
1. Run the citation verifier first: in RESEARCH, `make sibling-cites`
   (tools/zdtd_cite_check.py). Every explicit RE citation in zdtd src and docs
   must resolve; fix broken doc-name typos as their own small commit.
2. Sweep the R-bucket file rows: for each cited research fact, open the cited
   doc section and check it is (a) present and (b) accurate against the IL
   dump or a live observation. Update the row with the verification date when
   it holds; write a divergence row when it does not.
3. Sweep zdtd src for magic constants (numbers, thresholds, bitmasks, world
   times) and cross-check each against the research pins: stock_facts.json
   (make facts), xml_pins.json, the tuned-constants table (tools/tests/
   test_tuned_constants.py, 524 pins), and the owning narrative doc. A
   constant that matches gets its cite; one that differs gets an honest
   divergence row (stock value + cite + zdtd value + why).
4. For a genuine divergence, decide: is it a bug (fix zdtd code) or a
   deliberate simplification/policy (leave code, add the PROVENANCE row with
   "Diverges:" wording). Do not refactor working code; do not reverse-engineer
   stock behavior from the clone's assumptions.
5. When a stock claim is ambiguous or contested, verify LIVE: boot the stock
   dedicated server through 7dtd-loadgen/scripts/start_dedicated_*.sh
   (RE_DEDICATED_USERDATA=~/.cache/7dtd-loadgen-NAME), join a bot
   (LOADGEN_MODE=join LOADGEN_COUNT=1 LOADGEN_ACTIONS=0), and observe via
   telnet 8081 (password retest) or the server log. Method: research
   docs/re-methodology.md section 5e. Note the bot joins are flaky; retry.
   Save-format claims are machine-checked by RESEARCH tools/
   save_roundtrip_check.py (make save-roundtrip-all) and by booting the server
   on an existing probe save (game-reader round-trip).
6. Save-format provenance: zdtd persistence (players.zsv, entities.zen,
   claims.zlc, clock.zcl, weather.zwt, its chunk store) is Z-owned and must NOT
   be claimed stock-identical; a row exists per format noting the divergence
   against the stock blob (main.ttw nested blobs, region payloads, chunk
   bodies are all byte-exact-verified in save-region.md).

# Gates (run before every commit and at the end)
- zdtd:  python3 tools/provenance_scan.py   (188/188, constants ledgered)
- zdtd:  make check                          (zig build + tests)
- RESEARCH: make test (24 checks) + make verify (ALL GATES GREEN)
- RESEARCH: make save-roundtrip-all          (every probe save + shipped world)
- RESEARCH: make sibling-cites               (381 citations resolve)
- RESEARCH: make cross-links                 (312 links resolve)
- LOADGEN: make test                         (24 C# + 14 python)
Commit only when the gates pass.

# Workflow and conventions
- Small committed slices: one commit per finding or verification, never batch
  unrelated changes. Commit message prefix in RESEARCH: "Tier-C: <slug>";
  in zdtd: plain descriptive messages.
- Changelog: append one dated batch line to RESEARCH workspace/CHANGELOG.md
  per slice (facts, corrections, gate state); zdtd uses docs/RELEASES.md.
- No em dashes; no AI attribution; mark honest statuses (verified/inferred/
  diverges/blocked).
- Do not commit to zdtd without checking for concurrent agents; push each
  commit. No git mutations beyond add/commit/push of your own work.
- Cross-repo delivery: when the research gains a fact a sibling relies on,
  update the sibling's citation (loadgen README, optimizer levers, realworld
  surfaces) and re-run make sibling-cites.

# Done looks like
- PROVENANCE.md has no R-bucket row whose cite is missing or inaccurate; every
  divergence carries the stock value + cite + reason.
- provenance_scan.py: 188/188 and all constants ledgered.
- Every fleet gate above is green; all commits pushed.
- The changelog records what each pass verified and corrected.
```
