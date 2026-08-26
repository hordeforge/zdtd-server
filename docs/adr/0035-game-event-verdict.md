# ADR 0035: on_game_event verdict hook

- **Status:** accepted
- **Date:** 2026-08-27
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

zdtd answers the request with a stock-shaped APPROVED ack
(ResponseTypes 1, flags 192) but does not execute the event, and does not
apply the stock sender/party gate: every request is acked, including
cross-player targets. The surface is dormant (zero stock data uses
GameEvent actions; Twitch events are off by default), so the divergence
is invisible on a stock client, but the missing validation is a real
trust hole and the "approved but unrun" contract is dishonest if a
modded client or an operator uses the surface.

ADR 0025 (2026-08-10) decided a native, data-driven GameEvent dispatch
table (WORK_PLAN T32), scoped to blood-moon boss setup, challenge reward
redemption (T33), and quest `<action type=GameEvent>` elements. Later RE
re-scoped those consumers: challenges are client-tracked with no
server-required challenge wire (quests-challenges.md section 5, GAP
row WORKS 2026-08-21), quest GameEvent actions have zero stock uses, and
blood-moon hordes already run through the native director. The dispatch
table's consumers are gone, and per AGENTS rule 29 discretionary event
behavior belongs in plugins, not native code - so T32/T33 are superseded
here and closed in WORK_PLAN.

## Decision

Add an `on_game_event(player, event_name, target, var_count)` **verdict
hook** to the plugin boundary (both the in-process Zig host and the Wasm
guest surface), fired after the stock IL=211 sender/party validation:

- `<0` denies the event: no response is sent.
- `0` keeps today's behavior: the stock APPROVED ack is sent.
- `>0` keeps the ack as well; the first non-keep verdict wins across
  slots (same convention as `on_perk_spend`).

The native handler now applies the stock gate (a target that is another
player must be a party member; non-player entities and unknown ids pass,
rejected targets get no response), walks the request body to the
variables count for the hook, and only then consults the verdict. The
GameEvent execution engine stays out of scope: if an operator wants real
event execution, a plugin implements it over the boundary (`zdtd.queue`
verbs for spawns, messages, and the like). No native phase machine is
faked (missing beats fake). ADR 0025's scoping and fail-closed philosophy
carries over; only its execution location moves, from native core to the
plugin boundary.

## Consequences

- Makes: operator-gated/customized GameEvents expressible in plugins;
  closes the trust hole where any client could fire an event at any
  player and get an APPROVED ack.
- Makes harder: nothing native; the hook is additive and cannot mutate
  sim state itself (verdicts only gate the response).
- Costs: one more boundary hook to maintain; per-request O(plugins)
  dispatch with a null-check per slot (zero cost when no module exports
  the hook). ADR 0025's native dispatch table is not built, so a
  `gameevents.xml`-authored sequence still needs a plugin to run it.
