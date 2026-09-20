# ADR 0035: on_game_event verdict hook

- **Status:** accepted (amended: death/respawn sequences run native from
  `gameevents.xml`; see Decision)
- **Date:** 2026-08-27
- **Updated:** 2026-09-20 (record the native death/respawn runner that
  landed after this ADR; verdict + gate decisions unchanged)
- **Related:** ADR 0025 (GameEvent scoped interpreter - superseded for the
  execution-location decision), ADR 0033 (on_perk_spend verdict), ADR 0034
  (on_stat_changed observer), ADR 0020 (Wasm plugins), ADR 0030 (plugin
  spatiotemporal composability)

## Context

`NetPackageGameEventRequest` carries the client's (or party's) request to
run a named GameEvent. Stock `ProcessPackage` IL=211 validates the sender
against the target (the target entity must be the sender or a party
member, else the request is silently dropped) and then executes the event
through `GameEventManager.HandleAction`; a `NetPackageGameEventResponse`
is sent only when the action runs.

At the time of this ADR, zdtd answered the request with a stock-shaped
APPROVED ack (ResponseTypes 1, flags 192) but did not execute the event,
and did not apply the stock sender/party gate: every request was acked,
including cross-player targets. The surface looked dormant (Twitch off by
default), so the divergence was invisible on a stock client, but the
missing validation was a real trust hole and the "approved but unrun"
contract was dishonest if a modded client or an operator used the surface.

ADR 0025 (2026-08-10) decided a native, data-driven GameEvent dispatch
table (WORK_PLAN T32), scoped to blood-moon boss setup, challenge reward
redemption (T33), and quest `<action type=GameEvent>` elements. Later RE
re-scoped those consumers: challenges are client-tracked with no
server-required challenge wire (quests-challenges.md section 5, GAP
row WORKS 2026-08-21), quest GameEvent actions have zero stock uses, and
blood-moon hordes already run through the native director. The original
T32/T33 consumers are gone, and per AGENTS rule 29 discretionary event
behavior belongs in plugins, not native code - so those tasks are
superseded here and closed in WORK_PLAN. A later stock path forced a
narrow exception: death and respawn (`game_on_death_*` /
`game_on_respawn_*`) must run on the dedicated because the client only
forwards `NetPackageGameEventRequest` (`HandleActionClient` IL=416).

## Decision

Add an `on_game_event(player, event_name, target, var_count)` **verdict
hook** to the plugin boundary (both the in-process Zig host and the Wasm
guest surface), fired after the stock IL=211 sender/party validation:

- `<0` denies the event: no response is sent.
- `0` keeps today's behavior: the stock APPROVED ack is sent.
- `>0` keeps the ack as well; the first non-keep verdict wins across
  slots (same convention as `on_perk_spend`).

The native handler applies the stock gate (a target that is another
player must be a party member; non-player entities and unknown ids pass,
rejected targets get no response), walks the request body to the
variables count for the hook, and only then consults the verdict.

**Native execution carve-out (amendment):** after a keep verdict, the
server runs a parsed `gameevents.xml` sequence when the name is in the
supported death/respawn subset (`src/server/game/game_events.zig`,
`src/assets/gameevents.zig`). Unsupported sequences, unknown verbs, or a
missing table fail closed (run nothing; missing beats fake). No general
132-verb phase machine is built. Discretionary or custom GameEvent
behavior beyond that stock-required subset stays plugin-owned over
`zdtd.queue`. ADR 0025's scoping and fail-closed philosophy carry over;
execution location is native for the death/respawn carve-out and
plugin-gated for everything else.

## Consequences

- Makes: operator-gated/customized GameEvents expressible in plugins;
  closes the trust hole where any client could fire an event at any
  player and get an APPROVED ack; stock death/respawn stats come from
  `gameevents.xml` instead of hardcoded funnel values.
- Makes harder: the verdict hook is additive and cannot mutate sim state
  itself (verdicts only gate the response); native execution is bounded
  to the supported action classes in the carve-out.
- Costs: one more boundary hook to maintain; per-request O(plugins)
  dispatch with a null-check per slot (zero cost when no module exports
  the hook); a maintained supported-verb set in the gameevents loader.
