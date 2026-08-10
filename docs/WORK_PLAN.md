# Work plan (current)

Archived detailed task history: [`archive/WORK_PLAN_2026-08-09.md`](archive/WORK_PLAN_2026-08-09.md).

Active planning is now tracked in the living docs:

- [`STATUS.md`](STATUS.md) — what works now (hub; wins on conflict).
- [`GAP_ANALYSIS.md`](GAP_ANALYSIS.md) — gap inventory with RE anchors; see §3 priority band for "what to build next".
- [`../TODO.md`](../TODO.md) — open items + backlog below the fold.
- [`RE_GAP_CLOSURE.md`](RE_GAP_CLOSURE.md) — per-gap RE spec map (stock docs → gap ID).
- [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — phased milestones (banner is authoritative; detail sections are historical work packages).

For handoff-ready task shape and house rules, see the archived plan's "How to work a task" § — same grounding/proof/commit expectations apply.

---

# Active program: anti-cheat (ADR 0022)

Decision and rationale: [ADR 0022](adr/0022-anti-cheat-architecture.md). Read it
before starting any task below; the layer split and the severity ceiling rule
are the constraints every task works under.

Ordering is deliberate. **T18 and T19 are ownership work and are worth more than
every detector after them.** A detector that exists because the owning work was
skipped is technical debt wearing a security badge.

Shared context for all five tasks:

- zdtd runs EAC off against stock clients. No client attestation exists.
- Existing surface: `src/server/game/guard.zig`, `src/server/guard_policy.zig`,
  `src/server/evidence.zig`, `src/server/phase_gate.zig`,
  `src/server/movement.zig`, and the gate table in
  [AUTHORITY.md](AUTHORITY.md).
- Catalog and policy vocabulary to draw on, design-only and unimplemented:
  `../../7dtd-server-guard/docs/DETECTORS.md`, `POLICY.md`, `THREAT_MODEL.md`.

---

## T18. Own the player inventory

**Why:** [ADR 0007](adr/0007-player-inventory-c2s-trust.md) records the interim
decision that player inventory is client-trusting: the stock UI path applies C2S
hold and bag pushes into ECS with no server echo. AUTHORITY.md says the same.
That is item duplication and spawn-anything, and no detector closes it honestly,
because the server never computed what the inventory should have been. This is
the single largest cheat surface in the server and it outranks the whole
detector program.

**Change:** make the server the authority for player inventory. Every C2S
inventory request becomes a request against a server-held inventory: validate
the transition against what the server believes the player holds, apply or
reject, then echo the result. The double-entry shape in the sibling
`inventory.delta` spec is the model: every positive item delta needs an
authorized cause.

Expect to keep an explicit, documented allowance for the cases stock's UI
genuinely drives, but each one named and bounded rather than a blanket trust.

**Grounding:** ADR 0007 records why the trust exists and what it costs.
`inventory.delta`, `inventory.stack`, `inventory.replay` and
`inventory.container_race` in
`../../7dtd-server-guard/docs/DETECTORS.md` describe the invariants; in zdtd
most become gates rather than detectors, since the server owns the ledger.

**Done when:** a C2S push that claims an item the server did not grant is
rejected, not applied; ADR 0007 is superseded or amended to record the new
state; and AUTHORITY.md's "client-trusting apply" row is gone.

**Proof:** a scenario that pushes an unbacked item and asserts the server
inventory is unchanged and the client is corrected. A replay test that applies
the same transaction id twice and asserts one effect. A container-race test
where two peers move the same slot and exactly one wins.

**Files:** `src/server/c2s/inv.zig` (the request path), `src/ecs/inventory.zig`
(the ledger), `src/server/game/replicate.zig` (the echo),
`src/server/persist.zig` (what survives a restart), `docs/AUTHORITY.md`,
`docs/adr/0007-player-inventory-c2s-trust.md`.

**Sizing and staging:** this is the largest task in the program and should not
land as one commit. Stage it:

1. **Shadow ledger.** Keep applying the client push, but also compute what the
   server believes and record a `.soft` finding on divergence. Ships no
   behaviour change and immediately measures how wrong the current path is.
2. **Reject the impossible.** Turn the divergences that are provably impossible
   (unbacked item, over-stack, replayed transaction id) into rejections.
3. **Own it.** The server ledger becomes authoritative and the echo is the
   correction.

Stage 1 is the one to land first: it produces the evidence needed to size 2 and
3, and it is safe to run in production while doing so.

**Exit criterion for stage 1**, so "measure" is bounded: every divergence class
seen over a full play session is either explained (a legitimate stock UI path we
must keep allowing, named and written down) or classified as impossible. Stage 2
starts when the unexplained set is empty, not when the divergence count is low.

**Out of scope:** trader pricing, craft queue authority. Separate ownership
gaps, file them.

---

## T19. Make observe mode honest about movement

**Why:** AUTHORITY.md documents that in `observe` mode the movement envelope
counts `movement_rejects` **but still applies the client position**, with no
clamp and no S2C snap. An operator reading "observe" reasonably expects
"watching, protected"; what they get is "watching, unprotected". Either the
clamp runs in both modes or the mode stops being described as a security
posture.

**Change:** pick one and make the docs and the code agree. The recommendation is
to clamp in both modes and let `observe` mean "do not kick", not "do not
protect", since the clamp is a Hard invariant on a server-owned quantity and
Hard invariants are exactly what `correct` is defined to enforce. If the clamp
stays off in observe, rename the mode and say plainly in AUTHORITY.md that
positions are applied unvalidated.

**Grounding:** the mode table and the movement row in
[AUTHORITY.md](AUTHORITY.md); `src/server/movement.zig`.

**Done when:** the movement row in AUTHORITY.md describes what the code does in
both modes, with no gap between them that a reader has to infer.

**Proof:** a test per mode asserting the applied position for an
over-envelope update.

**Out of scope:** the wider envelope model (acceleration, noclip, flight). T21
classifies those.

---

## T20. Classify every detector under the severity ceiling rule

**Why:** ADR 0022 decision 4 makes severity a checkable property rather than a
judgement: a detector may be `hard` only when every **decision** input is
server-derived. The existing detectors in `evidence.zig` (`phase`, `ownership`,
`bounds`, `movement`, `decode`, `throttle`, `flood`, `farming`) were assigned
severities by hand and have never been checked against that rule.

**Change:** for each detector, record its inputs classified twice, by authority
(server-derived or client-declared) and by role (observed or decision), next to
the detector definition. Then assert the ceiling: any detector with a
client-declared decision input cannot be `hard`. Fix any that violate it, in the
direction of lowering the severity, never by relabelling an input.

`farming` is the model for the honest end of this: it is already documented as
heuristic and record-only by construction, so tuning it cannot cause a kick.

**Grounding:** ADR 0022 decision 4; the authority/role definitions in
`../../7dtd-server-guard/docs/POLICY.md` under "Severity".

**Done when:** every detector carries both classifications and a test enforces
the ceiling mechanically.

**Proof:** a comptime or unit test over the detector table asserting no `hard`
detector has a client-declared decision input. A test that a detector whose
input classification is downgraded fails the build if its severity is not
lowered with it.

**Out of scope:** adding detectors. This is classification of what exists. If
the classification shows a detector is weaker than its current severity claims,
lower the severity in this task and note it; do not also try to strengthen the
detector to earn the old label.

---

## T21. Ship the guest detector feed

**Why:** ADR 0022 decision 3. Heuristics are the part operators most want to
tune per server and the part that should never be able to stall a tick, which
makes the detector layer the one place a guest belongs.

**Change:** add an `on_evidence` (or equivalently named) Wasm hook that receives
a read-only feed of already-validated events and may emit `evidence.Event`
values and nothing else. Enforce the host-side cap: a guest emits at most
`.soft` by default, `.strong` only for a module the operator names in
configuration, and `.hard` never. The feed carries what the ring carries: no
raw packets, no chat text, no secrets, no IPs, no other player's inventory.

Reuse the existing budget and failure semantics unchanged: a trap or
`OutOfFuel` disables that module and the others keep running, which is correct
here because a dead detector means no signal rather than a bypassed gate.

**Grounding:** [ADR 0020](adr/0020-wasm-only-plugin-api.md) for the hook and
budget contract; `src/plugin/wasm.zig` for the disable-on-trap behaviour;
`src/server/evidence.zig` for the event shape and its exclusions.

**Done when:** a sample `.wasm` detector observes a synthetic event and emits a
finding that reaches the ring, and a module attempting to emit above its cap has
the severity clamped by the host rather than being trusted.

**Proof:** a scenario driving the hook end to end. A test that a guest-emitted
`.hard` arrives as at most the configured cap. A test that a trapping detector
is disabled while a second detector keeps receiving events. A test that the feed
contains no field the evidence ring excludes.

**ABI note:** the feed is versioned from the first commit (ADR 0022 decision 9).
Ship the minimum a detector needs. Widening it later is a revision; narrowing it
breaks every module already written against it.

**Out of scope:** any guest ability to deny, kick, quarantine or mutate. That is
the gate and policy layer, and ADR 0022 keeps guests out of both.

---

## T22. Attribution and suppression

**Why:** ADR 0022 decision 7. Without these two rules the anti-cheat becomes a
grief weapon: a player who can shove someone off a roof farms movement findings
against them, which is a worse outcome than the cheat being caught.

**Change:**

- **Attribution.** Every server-processed impulse (knockback, explosion,
  ragdoll) already resolves through a damage source owned by the attacker. Carry
  that owner onto the resulting finding, so a movement finding caused by another
  player's impulse attributes to the initiator. A finding another player can
  induce must never accrue against the victim.
- **Suppression.** Suppress soft scoring during server stalls, join and spawn,
  teleport, death, chunk starvation and packet-loss bursts. Keep the raw finding
  with the reason recorded: that is the data tuning needs, and dropping it
  silently makes the false-positive rate unmeasurable.

**Grounding:** the attribution mechanism and the suppression list in
`../../7dtd-server-guard/docs/POLICY.md` under "Enforcement gates" and
"Confidence and combination".

**Done when:** a finding induced by a second player attributes to that player,
and a finding raised during a suppression context is recorded with its reason
and excluded from scoring.

**Proof:** a scenario where peer A knocks peer B over the movement envelope and
the finding attributes to A. A test that a finding during a stall is recorded
with `suppressedReason` set and does not advance any policy counter.

**Also in scope, found during ADR review:** the kick gate counts distinct
detector *types* (`@popCount(state.strong_mask) >= strong_distinct`), not
independent *root causes*. A single server stall can raise both a movement and a
throttle finding and satisfy a two-detector gate on one cause. Suppression fixes
the common case; if it does not fully close it, record the residual in
AUTHORITY.md rather than leaving the gate reading stronger than it is.

**Out of scope:** confidence decay curves. Land attribution and suppression
first; decay is tuning on top of them.

---

## T23. Measure the false-positive rate before any enforcement rung

**Why:** every rung in `guard_policy.zig` defaults off and has to be switched on
by an operator. Nothing currently tells that operator what switching it on would
have done. ADR 0022 records the asymmetry that makes this matter: a wrongly
kicked player leaves and tells people, a missed cheater is caught later. An
enforcement rung enabled without a measured false-positive rate is a guess with
consequences.

**Change:** make the dry run produce a reviewable diff rather than a counter.
For a configured window, record what each rung **would** have done, to whom, and
on which evidence, so an operator can read the list before enabling anything.
Pair it with a stated exit criterion per detector family: the rung is eligible
only after N observation hours with zero unexplained findings.

`guard_dry_run` already exists as a flag; this task makes its output worth
reading.

**Files:** `src/server/guard_policy.zig`, `src/server/evidence.zig`,
`src/server/admin_console.zig` (a `guarddryrun` style listing),
`docs/AUTHORITY.md`.

**Grounding:** the dry-run diff requirement and per-family exit criteria in
`../../7dtd-server-guard/docs/POLICY.md` under "Enforcement gates".

**Done when:** an operator can list, for a window, every action a rung would
have taken and the evidence behind it, without enabling the rung.

**Proof:** a scenario that trips a rung in dry run and asserts the listing names
the action, the slot and the evidence ids, and that no player state changed.

**Also in scope:** a runtime off switch. `Game.guard` is a plain mutable field,
so a rung can be disabled without a restart, but no admin verb does it today:
an operator whose detector misfires at 3 AM has to restart the server to stop
it. Anti-cheat is the subsystem where that matters most, because the failure
mode is kicking paying players. Add the verb next to `guardstats`.

**Out of scope:** automatic promotion of a rung once criteria are met. A human
switches it on.

---

## Sequencing

- **First, and worth the most:** T18, then T19. Both are ownership, not
  detection. Until they land, a detector program is guarding a door that is
  already open.
- **Then:** T20, which is cheap and makes the existing severities honest.
- **Then, in either order:** T21 (guest feed) and T22 (attribution and
  suppression). T22 should land before any enforcement rung is switched on for
  a movement detector.
- **Before any operator enables an enforcement rung:** T23. It gates the whole
  program's blast radius and is independent of T21.

T21 is cheaper once T18 to T20 are done and close to worthless before them, but
it is not small: a versioned ABI, host-side severity clamping, per-module
capability config and fixtures are each real work. Do not schedule it as a
finisher.

**Anti-goal for the whole program:** shipping a kick. Nothing here needs to
enforce anything to be worth building. A server that owns its inventory, refuses
impossible requests, and hands an operator readable evidence has solved most of
the problem; the enforcement ladder is the last and smallest part, and the one
most likely to cause harm if rushed.
