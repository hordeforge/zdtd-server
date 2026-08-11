# 0025. GameEvent sequence engine: a scoped interpreter, not the full verb set

- **Status:** accepted
- **Date:** 2026-08-10
- **Related:** [ADR 0010](0010-data-config-zig-plugins.md) (no script VM in
  core), [ADR 0023](0023-perk-attribute-system.md) (the same
  scoped-evaluator, fail-closed-on-unknown shape, applied to a smaller
  surface), [docs/GAP_ANALYSIS.md](../GAP_ANALYSIS.md) (Quest `<action>`
  elements, Challenges system, Game events rows).

## Context

`../../../7dtd-research/docs/game-events.md` documents `GameEvent.*`: 187 types,
1141 method bodies, "the most explicitly state-machine-shaped system in the
assembly" per the research doc's own words. It is a tree of interpreters
(sequence → phases → actions, with decisions and loops as actions that hold
their own phase machines), driving XML-defined action sequences against
players and the world. It is what quests' `<action type=GameEvent>` elements
invoke, what challenge reward redemption runs through, and what fires
blood-moon boss encounters.

zdtd's current implementation of the C2S/S2C surface is a pure echo:
`src/server/c2s/misc.zig` handles `NetPackageGameEventRequest` by calling
`buildGameEventResponse` and sending back exactly what came in, with no
sequence, no phase machine, no action dispatch anywhere in the tree. The
`GAP_ANALYSIS.md` row for this ("Game events (GameEventRequest/Response) |
PARTIAL (ack path)") undersells that: there is no engine at all underneath
the ack.

The forcing question this ADR answers: given 1141 method bodies of stock
surface and ADR 0010's standing rule against a script VM in the tick-path
core, how much of this gets built, and in what shape?

## Decision

### 1. A dispatch table, not an interpreter for all 132 action verbs

Build `GameEventManager` as a **data-driven dispatch table**: a sequence is a
fixed-size list of phases, a phase a fixed-size list of actions, an action a
`{verb: enum, requirement: ?Requirement, params: ...}` record parsed from
`gameevents.xml`. The dispatcher walks this table exactly the way
`ecs/schedule.zig`'s system table and `guard_policy.zig`'s ladder already walk
theirs: a fixed, enumerable set of things that can happen, in a fixed order,
with no way to synthesize a new verb at runtime. This is the same category as
the join state machine and the phase gates, not a general-purpose VM: nothing
here can execute code the server did not ship.

### 2. Scope the verb set to what a real consumer needs, grown by gap, not by catalog completeness

v1 implements only the action verbs the three actual server consumers need:
blood-moon boss setup/spawn (already partially live in `aidirector.zig`'s
horde logic, which this should feed rather than duplicate), challenge reward
redemption ([WORK_PLAN T33](../WORK_PLAN.md)), and the quest `<action
type=GameEvent>` elements `GAP_ANALYSIS.md` already documents as unhandled.
An action verb outside that set is parsed (so the sequence structure is known)
but its execution **fails closed**: logged as unimplemented, sequence halts
rather than guesses. This is ADR 0023 decision 2's shape (scope the evaluator
to what gates a real decision, fail closed on the rest), applied here to a
much larger stock vocabulary for exactly the same reason: implementing 132
verbs against zero confirmed server consumers is speculative work, the thing
[ADR 0024](0024-passive-effect-stack-layers.md) explicitly declined to do for
`EffectManager.GetValue`'s client-only layers.

### 3. Requirements and decisions reuse ADR 0023's evaluator shape, not a second one

`game-events.md` section 4 (requirement gating) and section 5 (decisions:
branching, not loops with unbounded iteration) describe a requirement
vocabulary that overlaps what T25 already builds for `progression.xml`
(`ProgressionLevel`, comparison operators). Route through the same
requirement-dispatch shape rather than a second requirement parser; extend it
where `gameevents.xml` needs a requirement type `progression.xml` did not use,
following the same fail-closed default.

### 4. Loops are bounded by construction, never by trusting the data

Stock's loop actions are real (section 5), and an XML-authored loop with no
compile-time bound is exactly the kind of thing that turns a dispatch table
into a de facto VM if the bound is not enforced by the host. Every loop action
gets a hard iteration cap enforced by the interpreter, not by the assumption
that `gameevents.xml` is well-formed. This is the same posture ADR 0020 takes
toward Wasm guest fuel: bound the untrusted structure, do not trust it to
bound itself.

### 5. Client-only and external verbs are not ported, and are named as such

Per the research doc's own section 8: XUi widget/HUD verbs and the
`TwitchAction` family (external service, already out of scope per
`residuals.md` and the earlier audit pass on Twitch) are not implemented. A
verb in this category that appears in a real sequence still parses and still
fails closed on execution, same as an unimplemented-for-now verb; the
difference is these are never expected to move into the implemented set.

## Consequences

### Positive

- Blood-moon boss triggers, challenge redemption, and quest GameEvent actions
  share one engine instead of three ad-hoc paths, the same win ADR 0024 banked
  for passive-effect reads.
- The fail-closed-on-unrecognized-verb rule means an author-facing
  `gameevents.xml` edit that uses an unported verb is visible as "did not
  run," not a silent no-op indistinguishable from success.
- Loop bounding is decided once, here, rather than becoming a per-action
  afterthought the first time someone ports a loop verb.

### Negative / costs

- v1 covers a small fraction of stock's 132 verbs. Content authored against
  the full stock catalog (a ported or custom `gameevents.xml`) will visibly
  fail closed on most of it until grown.
- The dispatch table still needs real design work per verb category (section
  6's "action zoo" spans buff, spawn, teleport, block, and more): this ADR
  decides the shape, not the verb-by-verb implementation, which is
  [WORK_PLAN T32](../WORK_PLAN.md)'s job.

## Alternatives considered

| Option | Why not |
|---|---|
| Full port of all 187 types / 1141 bodies | Speculative against zero confirmed need for ~90% of it; the workstation-tool-cache mistake ADR 0024 avoided, at ten times the scale |
| No GameEvent engine; keep the echo-only ack | Leaves blood-moon bosses, challenge rewards, and quest GameEvent actions permanently unreachable; three real consumers with no path forward |
| A general Lua/scripting layer reading `gameevents.xml` as a script | Exactly what ADR 0010 rejects for the core; also wrong tool, since the actions are a bounded verb set, not arbitrary logic |
| Unbounded loop actions, trust the XML | The XML is operator-editable content, not compiled input; an unbounded loop is a hang waiting for a typo, not a hypothetical |

## Follow-up

Implementation is [WORK_PLAN.md](../WORK_PLAN.md) T32 (the dispatch engine
and its first verb set) and T33 (the challenge system, which is built on it
and does not duplicate it).
