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

---

# Active program: perk and attribute progression (ADR 0023)

Decision and rationale: [ADR 0023](adr/0023-perk-attribute-system.md). Forcing
function: A34 (turret/trap kill XP) needed a per-player perk level and could
only get a flat floor instead. `progression.xml` scope: 59 perks, 324
`<level_requirements>` blocks, 517 `ProgressionLevel` requirement uses.

Ordering is strict: T24 before T25 before T26 before T27. Each stores or reads
state the next one needs.

## T24. Persist per-player attribute and perk levels

**Why:** nothing tracks a player's attribute or perk level today; the catalog
loads but no instance state exists. Every task after this one needs it.

**Change:** add an attribute-level array (one per `AttrDef`) and a perk-level
array (one per `PerkDef`) to player state, plus spent and available skill-point
counters. Persist through the existing player save path (`players.zsv` /
ZPV3) rather than a parallel file: this is player state exactly like level and
XP, which already live there. A fresh player gets all-zero levels; a save from
before this change loads as all-zero, not as an error.

Bring back a name-to-level lookup spanning both arrays
(`attrByName`/`perkByName` shape, removed as dead code before this program
gave them a caller): T25's evaluator has to resolve a `progression_name` that
can name either an attribute or a perk (`progression.xml` `ProgressionLevel`
requirements target both; measured, not assumed, see T25's grounding), so one
caller-facing lookup by name is the right shape, not two typed ones the
caller has to pick between.

**Files:** `src/ecs/components.zig` (or wherever player state structs live),
`src/server/persist.zig`, `src/assets/progression.zig` (array sizing against
the loaded catalog).

**Grounding:** none needed; this is zdtd-owned persistence layout, like the
existing ZPV3 fields.

**Done when:** a player's attribute and perk levels round-trip through a save
and restart at zero for a save written before this change.

**Proof:** a save/load test asserting round-trip for non-zero levels, and a
test loading a pre-change fixture save that asserts every level reads as zero
rather than erroring.

**Out of scope:** any way to change these levels yet. That is T27.

---

## T25. A requirement evaluator for `ProgressionLevel` and `PlayerLevel`

**Why:** ADR 0023 decision 2. The only decision this system has to make is
"can this attribute or perk go up one level."

**Change:** parse `<level_requirements level="N">` blocks per perk/attribute
(already partially reachable via the catalog loader) and evaluate
`ProgressionLevel` and `PlayerLevel` comparisons against the player's stored
levels (T24) and character level respectively, across all six comparison
operators the file uses (`GTE`, `GT`, `LTE`, `LT`, `EQ`, `Equals`; the last two
are the same comparison spelled two ways). `ProgressionLevel`'s
`progression_name` resolves through the unified lookup T24 added, since it can
name an attribute or a perk. A `<level_requirements>` block containing any
other requirement type, or a `progression_name` the lookup cannot resolve,
fails closed: the level-up is refused, not approved by ignoring what it does
not understand. Log which requirement type or name was unrecognized so a gap
is visible rather than silently wrong.

**Do not scope this down to `ProgressionLevel` alone.** Every attribute's
`<level_requirements>` block in the shipped file is gated on `PlayerLevel`
(51 of 324 blocks); an evaluator missing it can level a perk but can never
level an attribute, which is not a smaller v1, it is a broken one.

**Files:** `src/assets/progression.zig`.

**Grounding:** `progression.xml` `<level_requirements>` blocks, counted against
the shipped file rather than assumed: 324 blocks total, every `<requirement>`
inside them is `ProgressionLevel` (273) or `PlayerLevel` (51), no other name
appears there.

**Done when:** a level-up request is approved only when every requirement in
its block is satisfied under the operator it specifies, and refused (not
approved) when a block contains an unrecognized requirement type or target.

**Proof:** a table-driven test over a sample of the real `progression.xml`
blocks covering both requirement types, at least one non-GTE operator, a
`ProgressionLevel` targeting a perk name rather than an attribute, and one
block containing an unrecognized requirement type, asserting the evaluator's
verdict against each by hand-checking the source attribute.

**Out of scope:** any requirement type beyond `ProgressionLevel` and
`PlayerLevel`. If a later gap needs one, it is a scoped addition to this
evaluator, not a rewrite.

---

## T26. `resolveEffect`'s progression and buffs layers, upgrade the A34 floor

**Why:** ADR 0023 decision 3, refined by [ADR 0024](adr/0024-passive-effect-stack-layers.md):
A34 fixed one kill-XP call site with a flat `Rules` floor because no
per-player resolver existed. Stock's own `EffectManager.GetValue` computes
this class of number from an ordered stack of layers (item, equipment,
progression, buffs are the ones that apply server-side); this task builds the
function and its progression and buffs layers, not a perk-only reader that a
later gap would have to route around.

**Change:** `resolveEffect(entity, effect_name, tags, opts) f32`
(`opts.progression`, `opts.buffs`, `opts.item`, `opts.equipment`, each
`bool = false`) walks only the requested layers in stock's order and
aggregates each the way `buffs.zig`'s `passiveValue` already does
(`base_set`/`perc_set` overwrite, `base_add`/`perc_add` sum). The buffs layer
calls `buffs.passiveValue` directly rather than reimplementing the
aggregation; the progression layer walks the player's leveled perks'
`<passive_effect>` rows with the same rule. `item` and `equipment` are
implemented as no-op-returning-empty stubs in this task (real bodies land with
T28, armor mitigation), so the signature does not have to
change twice. Update A34's call site (`src/server/game/step.zig`) to call
`resolveEffect(killer, "ElectricalTrapXP", .{}, .{ .progression = true })` and
fall back to `Rules.progression.trap_kill_xp_frac` only when the player has no
levels in a perk that grants it.

**Files:** `src/assets/progression.zig` (or a new shared module if the
function needs to sit above both `progression.zig` and `buffs.zig`),
`src/server/game/step.zig`, `docs/reviews/HARDCODE_AUDIT.md` (A34 moves from
"fixed with a floor" to "fixed per-player").

**Grounding:** `progression.xml` `<passive_effect>` rows inside `<perk>`
blocks; the aggregation rule already proven correct in `assets/buffs.zig`;
the layer set and order in
`../../7dtd-research/docs/minevents.md` section 7.0.

**Done when:** a player with `perkAdvancedEngineering` at level 3 is credited
45% of a turret kill's XP (the stock value at that level), a player with no
levels in it still gets the `Rules` floor unchanged from A34, and the `item`/
`equipment` layer stubs exist with a signature T28 can fill without a
breaking change.

**Proof:** extend the A34 scenario (turret kill XP) with a case that sets the
player's perk level directly (bypassing T25's requirement gate, since this
test is about resolution, not eligibility) and asserts the stock fraction.

**Out of scope:** resolving any effect through the `item`/`equipment` layers.
That is T28's body, this task's stub.

---

## T27. C2S perk and attribute spend, behind the S2C push

**Why:** ADR 0023 decision 4. Landing the spend request before the server can
correctly echo state back would let a client believe a point was spent that
the server dropped.

**Change:** first, push attribute/perk state to the client via
`buildPlayerStatsBody` (already exists) whenever a level-up or a spend changes
it, matching the stock NED-dirty push pattern the codebase already uses
elsewhere (`broadcastPlayerStats`). Only then accept a C2S request to spend an
available skill point on an attribute or perk: validate against T25's
evaluator and the available-point balance, apply, persist (T24), and push the
result.

**Files:** `src/server/c2s/*` (new or existing handler for the spend package),
`src/server/game/player.zig`, `docs/GAP_ANALYSIS.md` (closes "Skill points
granted per level" and the client/server progression-sync rows).

**Grounding:** stock `EntitySetSkillLevelClient` / the C2S spend package name
and shape (RE from the protocol docs); `buildPlayerStatsBody` for the existing
push builder.

**Done when:** a client can spend an available point on an eligible perk and
see the result; an ineligible or over-budget request is rejected with no state
change.

**Proof:** a scenario spending a point on an eligible perk (state changes,
push sent) and one attempting an ineligible spend (state unchanged, no
points consumed).

**Out of scope:** respec, book-granted level skips, any requirement type T25
did not implement.

---

## T28. Resolve armor mitigation from items.xml instead of a flat 10%/piece

**Why:** [HARDCODE_AUDIT A35](reviews/HARDCODE_AUDIT.md). `armorMitigation`
credits every equipped armor item the same flat 10%, capped at 50%, regardless
of the item, its tier, or its quality, and does not distinguish physical from
elemental damage. Stock ships the real numbers as `PhysicalDamageResist` /
`ElementalDamageResist` passive_effect rows, 267 lines across the armor
catalog. Unlike the perk-gated findings in this file, this one needs no
per-player state: armor mitigation is intrinsic to the equipped item, so it is
independent of ADR 0023 and can land before or after it.

**Change:** fill the `item`/`equipment` layer bodies of T26's `resolveEffect`
(stubbed there so the signature does not change twice; see
[ADR 0024](adr/0024-passive-effect-stack-layers.md)) rather than writing a
second, parallel resolver. Resolve `PhysicalDamageResist` and
`ElementalDamageResist` per equipped armor item from its `tier` attribute
(interpolated `lo,hi` across tiers 1-6) and its quality (the `-.2,.2` jitter
row), sum across equipped pieces, and keep physical and elemental as separate
totals so a damage type an armor set does not resist is not reduced by it.
`Rules` gets no new floor here: this is Bucket A, stock ships the number, an
unarmored player is representable as zero without a fallback.

**Files:** `src/ecs/inventory.zig` (`armorMitigation` and its caller), the
`resolveEffect` module T26 introduces.

**Grounding:** `items.xml` armor catalog `PhysicalDamageResist` /
`ElementalDamageResist` passive_effect rows (267 lines); the `tier="1,6"`
interpolation shape already has precedent elsewhere in the assets loaders.

**Done when:** two players wearing different-tier armor of the same slot take
measurably different physical damage, and elemental damage ignores an
armor set that carries no `ElementalDamageResist` row.

**Proof:** a test over the real `items.xml` asserting the resolved
mitigation for a low-tier and a high-tier sample of the same armor line, and a
damage test asserting elemental damage is unaffected by a physical-only set.

**Out of scope:** perk-based resistance bonuses (attribute passives that
modify `PhysicalDamageResist`/`ElementalDamageResist` further); those are
ADR 0023 territory once the resolver exists, and this task should not block
on it.

---

## T29. Stealth, noise and smell

**Why:** `../../7dtd-research/docs/stealth-smell.md` documents a
server-authoritative per-tick system (ambient/held-light level, a noise-event
queue with geometric decay, a smell radius driven by carried items, blood and
wetness) that feeds sleeper-wake and zombie detection. `docs/GAP_ANALYSIS.md`
correctly scores it MISSING, but no active task closes it: nothing in
`src/` implements any of it. `rg -i "smell|PlayerStealth|NotifyNoise" src/`
returns exactly two hits, both bare wire package-name string constants
(`NetPackageEmitSmell`, `NetPackageEntityStealth` in `src/wire/packages.zig`)
with no simulation behind either.

**Change:** port the per-tick light/noise/smell computation server-side and
wire it into the two systems that already consume detection state: sleeper
wake (`src/world/sleepers.zig`) and zombie sense (`systems.senseDistSq` and
the AI task gates, `src/ecs/systems.zig`). Do not invent a formula where the
research doc does not give one; a component this consumer-facing (it changes
whether a zombie notices a player) needs the real decay curve, not a
plausible guess.

**Files:** new `src/ecs/stealth.zig` (or similar), `src/world/sleepers.zig`,
`src/ecs/systems.zig`, `src/wire/packages.zig` (the two package builders
already stubbed by name).

**Grounding:** `../../7dtd-research/docs/stealth-smell.md` in full; cross-check
against `entity-ai.md` for how sense checks currently gate on it in stock.

**Done when:** a crouched, unlit, quiet player is measurably harder for a
nearby zombie to detect than a standing, lit, loud one, and a sleeper volume's
wake roll reads the same noise/light state stock does.

**Proof:** a scenario asserting a low-noise low-light player does not wake a
sleeper volume within a radius that a loud one does.

**Out of scope:** client-side stealth UI/HUD feedback (the meter itself is
presentation); this task is the server-authoritative state and its effect on
AI, not the client display of it.

---

## T30. Drone companion AI (`EntityDrone`)

**Why:** `../../7dtd-research/docs/raycast-pathing.md` section 6b is the
authoritative source for the drone state machine (`vehicles-drones-turrets.md`
section 5 covers persistence/sync only, and defers the state machine itself
to `raycast-pathing.md`, per that doc's own scope note). Verified: the real
machine has **9** states, not 6, `Idle`/`Sentry`/`Follow`/`Heal`/`Attack`/
`Shutdown` plus `NoClip` (collision-free reposition) and `Teleport` (a
recovery hop when travel fails), with `None` as the unset sentinel. A port
grounded only on the 6-state list would have no stuck-recovery path: a drone
whose `Follow` travel fails would have nowhere to go. `docs/GAP_ANALYSIS.md`
only surfaces this as an item inside the EAI-task-coverage list ("the three
Drone tasks" absent) and lists `NetPackageDroneDataSync` /
`DroneParticleEffect` as unhandled C2S; there is no first-class row and no
active task.

**Change:** port all 9 states, not the 6-state subset. Alongside the existing
turret and vehicle systems (`systems.systemVehicles`, `systems.systemTurrets`
are the shape to follow: same tick-phase structure, same owner-attribution
pattern the turret kill-credit work already established). `Follow` mode needs
the owner's position each tick; `Attack`/`Sentry` mode needs the same
sense/target-acquisition shape zombie AI already has, reused rather than
rebuilt; `Teleport` is the state that makes the rest robust against a stuck
drone and should not be treated as optional polish.

**Files:** new `src/ecs/drone.zig` (or fold into `systems.zig` if small
enough once written), `src/ecs/schedule.zig` (a new phase entry, gated by
`Rules.systems` per ADR 0021 so a mode can turn it off), `src/wire/packages.zig`
(`NetPackageDroneDataSync` builder).

**Grounding:** `../../7dtd-research/docs/raycast-pathing.md` section 6b (the
state machine, including the state table and transition diagram) and
`../../7dtd-research/docs/vehicles-drones-turrets.md` section 5
(persistence/sync).

**Done when:** a placed drone follows its owner, engages a nearby hostile in
attack mode, and survives a server restart the way vehicles and turrets
already do (`persist.zig` `saveEntities`/`loadEntities`; extend, do not
duplicate).

**Proof:** a scenario spawning a drone, moving the owner, and asserting the
drone's position tracks; a second asserting it engages a spawned zombie
within sensor range.

**Out of scope:** the heal-beam's exact healing-rate tuning if the research
doc does not state one; use a `Rules` floor per ADR 0021 decision 5 rather
than inventing a stock-looking number.

---

## T31. Stop citing `game.zig` line numbers that do not exist

**Why:** the `game.zig` decomposition (this doc's own T-series history, and
several sessions of extraction into `src/server/game/*.zig` and
`src/server/c2s/*.zig`) left `docs/GAP_ANALYSIS.md` citing 130 distinct
`game.zig:NNNN` line numbers. `game.zig` is 2532 lines today; **100 of the
130** exceed that, meaning most `game.zig` anchors in the gap inventory point
past end-of-file. This is not a one-time cleanup: every further extraction
will strand more of them, including anchors written today.

**Change:** two parts.

1. **One sweep now:** re-anchor the citations that exceeded the file length,
   pointing each at the file and function that actually holds the logic
   today (several are already known from this pass: "Autosave and shutdown
   save" → `src/server/game/lifecycle.zig`; "questOnTraderOpen reached"
   → `src/server/c2s/quest.zig:219` / `src/server/c2s/misc.zig:469`, and
   `questOnTraderOpen` itself is `src/ecs/systems.zig:380`; "Vehicle, turret,
   power... persistence" → `src/server/persist.zig` `saveEntities`/
   `loadEntities`, `src/server/game/chunk_fill.zig` `scanChunkPower`).
2. **Stop the recurrence:** prefer citing a function name (optionally with
   the file the way the sweep above does) over a bare line number for any
   citation likely to survive fewer than a few months, which in this
   codebase has meant every `game.zig` citation so far. A `grep -n` for the
   function name resolves regardless of where the file's been split; a line
   number does not. Add a lint check if one is cheap: a citation matching
   `game\.zig:\d+` where the number exceeds the file's current line count is
   mechanically detectable and could join `scripts/lint-cycles.sh` /
   `scripts/lint-architecture.sh` in `make check`.

**Files:** `docs/GAP_ANALYSIS.md`, `scripts/` (if the lint is added).

**Grounding:** none needed; this is doc hygiene, verified against the current
tree (`wc -l src/server/game.zig`, cross-checked citation-by-citation).

**Done when:** no `game.zig:NNNN` citation in `GAP_ANALYSIS.md` exceeds the
file's current line count, and (if the lint lands) a citation that goes stale
in the future fails `make check` instead of silently misleading the next
reader.

**Proof:** a one-line check (`grep -oE "game\.zig:[0-9]+" docs/GAP_ANALYSIS.md`
against `wc -l src/server/game.zig`) reporting zero over-length citations. If
the lint is added, a test fixture with one deliberately stale citation
asserting the lint catches it.

**Out of scope:** re-verifying the *behavioral* claim next to each anchor,
only that the anchor points at code that exists. A wrong anchor next to a
correct claim (found twice in this pass) is still worth fixing on sight if
cheap, but re-auditing every claim is a separate, much larger task.

---

## T32. The GameEvent dispatch engine (scoped, per ADR 0025)

**Why:** [ADR 0025](adr/0025-gameevent-scoped-interpreter.md). The entire
`NetPackageGameEventRequest` handler is an echo (`src/server/c2s/misc.zig`
calls `buildGameEventResponse(body)` and sends the input back); there is no
sequence, phase, action, or requirement machinery anywhere in the tree.
Blood-moon boss triggers, challenge redemption (T33), and quest `<action
type=GameEvent>` elements all need this before they can do anything.

**Change:** build the dispatch table ADR 0025 decides: sequence → phases →
actions, parsed from `gameevents.xml`, walked in fixed order, every loop
action capped by a hard host-enforced iteration bound. Implement the verb set
the three named consumers actually need first (start with whichever of
blood-moon boss setup or a single quest GameEvent action is cheapest to prove
end-to-end); every other parsed verb fails closed (logged as unimplemented,
sequence halts) rather than silently no-opping. Requirement gating routes
through the same dispatch shape T25 builds for `progression.xml`, extended
only where `gameevents.xml` needs a requirement type T25 did not cover.

**Files:** new `src/ecs/game_event.zig` (or similar), `src/server/c2s/misc.zig`
(replace the echo with real dispatch), `src/ecs/aidirector.zig` (blood-moon
boss setup should feed through this rather than staying a separate path).

**Grounding:** `../../7dtd-research/docs/game-events.md` in full, especially
section 1 (architecture), section 4 (requirement gating), section 5 (decisions
and loops), section 8 (dedicated relevance: `IsServer`-gated, near-zero idle
cost with no running sequences).

**Done when:** a `gameevents.xml` sequence with a verb in the implemented set
runs end to end (phases advance, the action executes, the sequence
completes), and one with an unimplemented verb halts with a logged reason
rather than silently completing or hanging.

**Proof:** a scenario driving one full sequence through the implemented verb
set. A test asserting a loop action with an XML-authored huge iteration count
stops at the host cap rather than the tick budget. A test asserting an
unrecognized verb halts the sequence and logs, rather than skipping silently.

**Out of scope:** the other ~120+ verbs stock ships (see ADR 0025's cost
section); Twitch-triggered events (external service, already out of scope);
client-side HUD/boss-bar presentation of a running sequence.

---

## T33. Challenge system

**Why:** `../../7dtd-research/docs/quests-challenges.md` sections 6-9
document a full engine (`ChallengeStates`, staged objective groups,
daily/random rotation and tiering, 28 objective verbs, reward delivery through
a GameEvent `RewardEvent`). `GAP_ANALYSIS.md` scores "Challenges system |
MISSING" with no elaboration section (unlike quests, which has one) and no
active task. Source confirms zero implementation: the only `challenge`-named
things in the tree are an unrelated pre-auth handshake counter and a name
filter for `challengegroup_reward_*` quest strings; `ChallengeJournal` is
written as a permanently-empty stub (`src/wire/packages.zig`).

**Change:** depends on T32 (reward delivery runs through a GameEvent action).
Port `ChallengeStates`, the staged objective groups, and the rotation/tiering
model; wire the objective verbs that actually appear in the shipped challenge
catalog first, following the same fail-closed-on-unrecognized-verb rule as
T32 rather than implementing all 28 speculatively.

**Files:** new `src/ecs/challenge.zig` (or similar), `src/wire/packages.zig`
(`ChallengeJournal` stops being a permanent empty stub), `src/server/c2s/*`
(whichever C2S package requests/tracks challenge state).

**Grounding:** `../../7dtd-research/docs/quests-challenges.md` sections 6-9 in
full.

**Done when:** a player can complete a challenge's staged objectives and
receive its reward through T32's GameEvent path, and `ChallengeJournal`
reflects real state instead of an empty record.

**Proof:** a scenario driving a sample challenge through its stages to
completion and asserting the reward lands.

**Out of scope:** every objective verb the shipped catalog does not use.

---

## T34. Crafting XP: verified near-zero in shipped data, not the bug it looked like

**Status: re-scoped 2026-08-10 after checking the shipped `recipes.xml`
directly, rather than the research doc's prose alone.** The original framing
("crafting never awards XP, real gap") turned out to be half right: the code
gap is real, but implementing the formula as documented would not visibly
change anything, because the number stock would grant is already zero for
every recipe that states it.

**What's confirmed:** `../../7dtd-research/docs/crafting-recipes.md` section 2
documents `Progression.AddLevelExp(CraftExpGain / total, ...)`, where `total`
is a cumulative per-recipe craft counter (diminishing returns on repeated
crafts of the same recipe). `src/server/game/craft.zig`'s `tryCraft` (not
`tryCraftRecipe`, which does not exist under that name; the internal helper is
`fn tryCraftRecipe`) never calls `awardXp`, confirmed by reading the function.

**What changes the plan:** checked the shipped V3.1.0 `recipes.xml` directly.
639 `<recipe>` elements total; only **17** declare `craft_exp_gain`, and
**every one of the 17 is `0`**. The other 622 do not declare it at all. The
research doc's "derived from ingredient `CraftComponentExp` when absent"
clause describes an **editor-only export step**
("The editor export twin... sums each ingredient's `ItemClass.CraftComponentExp`")
— and `CraftComponentExp` has **zero occurrences** in the shipped `items.xml`,
confirming that derivation bakes a value into the file at content-authoring
time and does not run in the dedicated server's IL at all. Since the shipped
file was evidently not re-baked for the 622 undeclared recipes, what the
dedicated server actually grants for a craft of one of those is unresearched:
plausibly the raw unparsed-attribute default (`-1`, per the doc's own XML-parse
note) flows into `AddLevelExp` and gets clamped somewhere, but no clamp is
documented for the lower bound, and guessing here risks *subtracting* XP on
622 of 639 recipes, which would be a regression worse than granting nothing.

**Change:** parse `craft_exp_gain` (present on 17 recipes, always `0` in the
shipped file) and wire the plumbing (`AddLevelExp`-equivalent call,
per-recipe craft counter, diminishing-returns division) so it is *correct* for
whatever a modded or future recipe file declares — but do not invent a value
for the 622 recipes that declare nothing. Fail closed there (grant 0, matching
what the confirmed 17 already do), and log a note that these recipes have no
stock-declared crafting XP rather than silently normalizing them to the same
0 a reader can't distinguish from "unresearched."

**Files:** `src/assets/recipes.zig` (parse `craft_exp_gain`, default absent to
a sentinel distinct from an explicit `0`), `src/server/game/craft.zig`
(`tryCraftRecipe`, the per-recipe craft counter and the grant call).

**Grounding:** `../../7dtd-research/docs/crafting-recipes.md` section 2;
`Data/Config/recipes.xml` (all 639 elements, the `craft_exp_gain` distribution
above); `Data/Config/items.xml` (zero `CraftComponentExp` occurrences).

**Done when:** the 17 recipes that declare `craft_exp_gain` grant exactly what
they declare (0, today; correct behavior if a future/modded file sets a
non-zero value), and the 622 that don't declare it grant 0 without a fabricated
derivation.

**Proof:** a test over the real `recipes.xml` asserting the parsed value for a
sample of the 17 declaring recipes, and a scenario crafting an undeclared
recipe asserting XP is unchanged (not silently non-zero from a guessed
formula).

**Out of scope:** resolving the undeclared-recipe question definitively —
that needs an IL read of what `AddLevelExp` does with a negative or absent
input, which is a research task (file it against
`../../7dtd-research/docs/crafting-recipes.md` if picked up), not an
implementation guess. The ADR 0023/0024 perk-gated crafting bonuses are
likewise out of scope here.

---

## T35. Air-drop crates never get a compass marker

**Status: landed 2026-08-10.** `tickAirDrop` (`src/server/game/tick.zig`)
broadcasts `NetPackageNavObject` with the shipped `nav_object_classes.xml`
`supply_drop` class alongside the existing loot-bag spawn, entity_id tied to
the bag's net id. Covered by scenario "air drop pushes a supply_drop
NavObject marker". Residual: the marker has no removal companion
(`NetPackageEntityMapMarkerRemove`) when the crate is looted or expires, so
it outlives the loot; not implemented, noted rather than silently dropped.

**Why:** `../../7dtd-research/docs/map-objects.md` section 8: air-drop crates
are stock's one server-push nav marker (`AIDirectorAirDropComponent.RefreshCrates`
sends `NetPackageNavObject`); every other marker is client-derived.
`src/server/game/tick.zig`'s `tickAirDrop` spawns the loot bag and broadcasts
its spawn, but never calls the NavObject builder (`buildNavObjectAdd`, already
used elsewhere for quest markers). A stock client gets no compass ping for an
air drop it should see land.

**Change:** send `NetPackageNavObject` for the crate alongside the existing
loot-bag spawn broadcast in `tickAirDrop`, using the same builder
`sendQuestNavObjects` already calls.

**Files:** `src/server/game/tick.zig` (`tickAirDrop`).

**Grounding:** `../../7dtd-research/docs/map-objects.md` section 8.

**Done when:** an air-drop spawn sends a NavObject the client can render as a
compass marker.

**Proof:** a scenario triggering an air drop and asserting the capture
contains a `NetPackageNavObject` for the crate's position.

**Out of scope:** the marker's removal-on-loot timing if the research doc
does not state one precisely; fail closed (never send a stale marker) over
guessing a decay curve.

---

## T36. `BlockTrigger` has no server-side authority

**Why:** `../../7dtd-research/docs/block-shapes.md` section 7: stock's
`BlockTrigger`/`TriggerManager`/`PrefabTriggerData` is a real per-POI channel
system (latch state, AND/OR combine, `Block.OnTriggered` mutating switches,
doors, lights, hazards, batched as `BlockChangeInfo`).
`src/server/c2s/blocks.zig` handles `NetPackageBlockTrigger` by relaying the
raw client bytes to nearby peers with `broadcastNear` and nothing else, no
channel lookup, no latch, no server-applied mutation. `GAP_ANALYSIS.md`'s row
("PARTIAL, BlockTrigger C2S handled") is accurate at packet-relay granularity
but does not surface that a lever-to-door circuit is entirely client-simulated
today: any peer can claim any trigger fired, and the server never checks.

**Change:** parse `PrefabTriggerData` channel wiring at prefab load (the
loader already resolves other prefab TE data), track latch state
server-side, resolve AND/OR combine, and apply `Block.OnTriggered`'s
mutation authoritatively before relaying the result, instead of relaying the
unvalidated request.

**Files:** `src/server/c2s/blocks.zig`, `src/world/prefabs.zig` (trigger
wiring parse), a new component or table for channel/latch state.

**Grounding:** `../../7dtd-research/docs/block-shapes.md` section 7.

**Done when:** a trigger fire is validated against the prefab's actual
wiring and latch state before the server applies or relays it; an
out-of-wiring claim (a peer claiming a trigger id the POI does not have, or
firing a latched-closed switch) is rejected.

**Proof:** a scenario firing a real trigger from the loaded prefab's wiring
(applies) and one firing a fabricated trigger id (rejected, no state change,
no relay).

**Out of scope:** every `Block.OnTriggered` mutation type stock supports;
start with the switch/door pair the loaded POIs actually use, following the
same grow-by-real-gap pattern as T32.

---

## T37. Bedroll ownership does not survive a restart

**Status: landed 2026-08-10.** `players.zsv` bumped ZPV3 -> ZPV4: the
progression tail's buff list is followed by a bedroll presence byte, then
`bed_x/y/z:i32` when present. A version byte gates the field rather than "more
bytes remain in the file", which turned out to be ambiguous whenever another
record follows the current one in the file (the next record's own name_len
byte would misread as this record's presence byte) — caught by an existing
test (`players zpv3 restore skips a preceding record's progression tail`)
that broke under the first, byte-existence-gated version of this change and
forced the version-gated rewrite. A v2 or v3 file upgrades in place on the
next save: v2 records get the same empty-tail byte they always did, v3
records with a progression tail get a bed_present=0 byte appended. Covered by
two scenarios: round-trip through a restart, and a save with no bedroll tail
reading back `has_bed = false` rather than an error.

**Why:** `../../7dtd-research/docs/server-lifecycle.md` section 6.1: stock's
`PersistentPlayerData.Write` carries the bedroll position as a first-class
field alongside land-claim blocks and the backpack. `GAP_ANALYSIS.md` already
scores this accurately ("Bedroll / last logout pos | PARTIAL... bedroll
ownership MISSING"), but no task closes it. `bed_x`/`bed_y`/`bed_z`/`has_bed`
exist as in-memory-only fields (`src/server/game/types.zig`); `persist.zig`'s
ZPV3 record never reads or writes them.

**Change:** extend the ZPV3 tail with the bedroll fields, the same shape T24
extends it with attribute/perk levels. Land whichever of the two lands
first; the second should append to the same tail rather than each assuming
it owns the last field.

**Files:** `src/server/persist.zig` (`savePlayers`/`tryRestorePlayer`).

**Grounding:** `../../7dtd-research/docs/server-lifecycle.md` section 6.1.

**Done when:** a player's bedroll position and ownership round-trip through a
save and restart.

**Proof:** a save/load test asserting bedroll state survives a restart, and
a pre-change fixture save still loads (bedroll reads as unset, not an error).

**Out of scope:** bedroll respawn logic itself, if already correct
elsewhere; this task is only the persistence gap.
