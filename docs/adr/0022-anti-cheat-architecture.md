# 0022. Anti-cheat architecture

- **Status:** accepted
- **Date:** 2026-08-10
- **Related:** [0004](0004-server-authoritative-c2s.md) (server-authoritative C2S),
  [0007](0007-player-inventory-c2s-trust.md) (the interim inventory trust),
  [0020](0020-wasm-only-plugin-api.md) (Wasm-only plugins),
  [AUTHORITY.md](../AUTHORITY.md), and the sibling design corpus in
  `../../7dtd-server-guard/docs/`.

## Context

zdtd runs with EAC off against unmodified stock clients. There is no client
attestation available and there never will be: we cannot ship code to the
client, inspect its memory, or verify its binary. Every defence is server side.

Two mechanisms exist, and they are not equal:

1. **Authority.** The server owns the state, so the cheat is not detected, it is
   impossible. An owned invariant is a proof.
2. **Detection.** The server notices a pattern it cannot prevent. A detector is
   a guess with a confidence attached.

Three things already exist in tree:

- **Gates** on the C2S path (`phase_gate.zig`, `movement.zig`, the reach,
  ownership, bounds and stack clamps listed in AUTHORITY.md).
- **`evidence.zig`**: a fixed 64-event ring, `Detector` / `Severity` / `Surface`
  enums, no secrets, no IPs, no packet bodies.
- **`guard_policy.zig`**: a pure decision layer with an opt-in ladder,
  log-only then quarantine then kick, where kick additionally requires
  `correct` authority mode. It carries one structural guarantee worth naming:
  `.info` and `.soft` return `.none` **before any counter is touched**, so a
  weak signal cannot open a gate however often it fires.

The sibling repo `7dtd-server-guard` is a design-complete, implementation-empty
project (about 2500 lines of specification, no C# yet) covering the same
problem for the **stock Mono dedicated server** as a Harmony mod. Its detector
catalog, policy ladder and threat model are directly useful here, but it is
solving a harder version of the problem than we have, and that difference
drives this decision.

### Why the sibling catalog cannot be ported as written

Server Guard is a mod bolted onto a server it does not own. It has to
reconstruct ledgers through Harmony patches and infer state it cannot see. That
is why so much of its catalog sits at `Strong`: `inventory.delta`,
`combat.damage`, `combat.reach`, `movement.displacement` are all "near
impossible but not proven" precisely because the stock server did not compute
the authoritative answer.

zdtd **is** the server. It computes the authoritative answer. For most of that
catalog the right port is not a detector at all: it is an invariant that makes
the request unrepresentable. Porting the detector instead would be building a
smoke alarm for a fire we can simply not light.

### Threat model

**Protected outcomes**, in the order they are worth defending:

1. Conservation: items, currency, ammunition, durability, health, stamina, XP.
   A duplication bug devalues every other player's time permanently.
2. World integrity: blocks, containers, claims, vehicles, turrets, entities.
3. Movement and combat fairness.
4. Identity and permission integrity across reconnects.
5. Availability under malformed or adversarial request volume.
6. Evidence good enough for an operator to reproduce a decision.

**Adversaries** we design against:

- A modified client sending validly encoded but impossible or unauthorized
  requests. This is the common case and the one authority defeats outright.
- A client manipulating movement, timing, cadence, reach, inventory or loot.
- A bot automating ordinary play while staying inside every individual limit.
- A player abusing a duplication, rollback, disconnect or transaction race.
- **A player weaponizing the anti-cheat itself**, inducing findings against a
  victim to get them corrected or kicked. Decision 7 exists for this adversary.
- A flood or join-churn source. Availability protection, never an accusation.

**Explicitly out of scope**, stated so nobody builds against an impossible bar:

- Client memory, process, input device or kernel inspection. EAC is off and the
  client is stock; there is nothing to inspect and no way to ask.
- Proving aimbot, ESP or wallhack from behavioural coincidence. Aim statistics
  can be recorded as `.soft`, and that is all they will ever justify. See
  decision 8 for what we can do instead.
- A malicious operator, a compromised host, or a plugin the operator installed
  deliberately. Code with server trust is not an adversary the server can
  defeat; it is the server.

**Trust boundaries.** Trusted: the zdtd process, the sim state it computes, its
clock, and explicit operator action. Untrusted: every client-supplied position,
rotation, claimed hit, stack, timing, name and reconnect state. Conditionally
trusted: a Wasm guest, which is bounded by fuel, memory and the caps in
decision 3 rather than by good behaviour.

## Decision

### 1. Authority first, detection second, always

For each entry in the sibling catalog the question is asked in this order:

1. Can zdtd **own** this state so the cheat is impossible? Then do that, and
   write no detector.
2. If not, can zdtd **validate** it against fully server-derived state at the
   point of application? Then it is a Hard gate, and it rejects.
3. Only if neither holds is it a detector, and it is `strong` at best.

A detector that exists because the owning work was skipped is technical debt
wearing a security badge.

### 2. Three layers, and only the middle one may be a guest

| Layer | Home | On failure | Guest allowed |
|---|---|---|---|
| **Gates** (phase, reach, ownership, bounds, decode, stack, claim) | native, in the C2S path | **fail closed**: reject the request | never |
| **Detectors** (heuristics, statistics, behaviour) | native or Wasm | a Wasm detector **fails open** (no signal); a native one is ordinary code and can be wrong in either direction | yes |
| **Policy** (ladder, gates, quarantine, kick) | native, `guard_policy.zig` | n/a | never |

**This table is the target, and one row is not true today.** The movement gate
in `observe` mode returns the unclamped client position
(`game/movement_helpers.zig`, the `authority_mode != .correct` early return), so
it records rather than rejects. That is the gap T19 closes, and it is called out
here rather than papered over: an ADR whose table quietly describes intent as
fact is worse than no table.

The gate layer must never be a plugin, and this is not a preference. A hook that
traps or exhausts fuel sets `disabled = true` and stops being called
(`src/plugin/wasm.zig`). For a rules plugin that fail-open behaviour is correct.
For a gate it means **starving the fuel budget disables the gate**, which hands
an attacker a bypass primitive. Gates are also on the hottest path in the
server, once per C2S package at 20 TPS times the player count, and every guest
call costs a copy across the boundary.

The detector layer is the opposite case. Fail open is harmless there ("no
signal" is not "no protection"), it is the code most worth iterating on without
a server rebuild, and it is exactly what should never be able to stall a tick.
So it is the natural and only home for guest anti-cheat code.

### 3. What a Wasm detector may and may not do

A detector guest receives a **read-only feed of already validated events** and
may emit `evidence.Event` values. That is the whole contract.

It may not: see raw packets, chat text, secrets, IP addresses or another
player's inventory; call a sim mutation; deny a request; kick, quarantine or
ban; or reach `guard_policy` at all. The event feed carries what the evidence
ring already carries, and the ring's own header states the exclusions.

**Severity is capped by the host, not declared by the guest.** A guest may emit
at most `.soft` by default. `.strong` requires the operator naming that module
in configuration. `.hard` is never available to a guest, because Hard means
"proven from complete authoritative server state" and a guest does not hold
that state.

**Why the cap does not follow from decision 4.** The ceiling rule below sets
severity by *input authority*, and a guest's feed is entirely server-derived
validated events, so by that rule alone a guest could mint `.hard`. It may not,
because trust has a second axis the ceiling rule does not cover:

- **Input authority** bounds what is *knowable* from the inputs.
- **Code trust** bounds what is *believable* about the verdict.

`.hard` means "proven". A proof is only as good as the code that computed it,
and guest code is untrusted by construction: that is the entire reason it runs
in a sandbox. Perfect inputs plus untrusted logic is not a proof. Both axes
apply, and severity takes the lower of the two.

**Exfiltration.** A guest has no filesystem, socket or thread, so the feed
cannot leave the process directly. It can, however, reach the `SimCommand`
queue, and a hostile module could in principle encode observed positions into
game state a confederate can see (a spawn pattern, for example). The bound is
the queue, not the feed: a detector module is granted the event feed **without**
the queue capability, so observation and mutation are never held by the same
module.

The net property: the worst a hostile or broken anti-cheat plugin can do is spam
its own ring and burn its own fuel.

### 4. Severity ceiling is set by input authority, not by ambition

Adopted from the sibling policy (its D-15), because it turns severity from a
judgement call into a checkable rule. Every detector input is classified twice:

- **Authority**: server-derived, or client-declared.
- **Role**: *observed* (the quantity being checked, which may legitimately be
  client-declared, since it is the subject of the check) or *decision* (state
  the verdict depends on).

**A detector may be `hard` only when every decision input is server-derived.**
One client-declared decision input caps it below `hard`. This is why
`inventory.stack` can be Hard (the claimed stack is observed, the item
definition that decides is ours) while `combat.reach` cannot (the attacker
origin is a client-declared decision input).

Each detector declares both classifications next to its definition, and the
ceiling is enforced by test rather than by review.

### 5. Severity vocabulary

zdtd keeps its four `evidence.Severity` levels. The mapping to the sibling's
three is recorded here so the catalog reads across:

| zdtd | Sibling | Strongest action it alone justifies |
|---|---|---|
| `hard` | `Hard` | reject or clamp the one transition, in `correct` mode |
| `strong` | `Strong` | nothing alone; counts toward a gate with a second **independent** detector |
| `soft` | `Weak` | record only, never enforces |
| `info` | (none) | record only, context and provenance |

### 6. Enforcement gates

Unchanged in shape from `guard_policy.zig`, with two additions from the sibling
policy:

- A kick needs **two independent** strong detectors, or a repeated hard protocol
  invariant with operator opt-in. Repeated findings from one root cause do not
  combine; that is one signal counted twice.

  **Not implemented today.** `guard_policy.evaluate` counts
  `@popCount(state.strong_mask) >= strong_distinct`, which is distinct detector
  *types*, not independent *root causes*. One server stall can raise both a
  movement and a throttle finding and satisfy a two-detector gate on a single
  cause. That is a live false-positive path in the existing code, and it is why
  T22 (suppression) must land before any enforcement rung is switched on for a
  movement detector, not after.
- Quarantine is preferred over kick when both are justified: it removes the
  harmful capability and keeps the player reviewable in place.

**No automatic permanent bans, ever.** Local temp-ban requires per-incident
operator approval. Platform bans are out of scope.

### 7. Attribution and suppression

Two rules that exist to stop the anti-cheat becoming a grief weapon:

- **A finding another player can induce never attributes to the victim.**
  Knockback, explosion and ragdoll impulses carry a damage-source owned by the
  attacker, and the resulting movement finding attributes to that owner.
  Container races resolve atomically at the server, so a second player's race
  grants the victim nothing and accrues nothing against them.
- **Soft scoring is suppressed during server stalls, join and spawn, teleport,
  death, chunk starvation and packet-loss bursts.** The raw finding is kept with
  the reason recorded, because that is the data tuning needs.

Without the first rule, a player who can shove someone off a roof can farm
movement findings against them. That is a worse outcome than the cheat.

### 8. Interest is an anti-cheat control, not only a bandwidth control

ESP and wallhacks read information the server already sent. The sibling project
lists "preventing information disclosure already sent by the stock game
protocol" as out of scope, and correctly: a mod cannot unsend what the stock
server decided to send.

zdtd decides. `interest.zig` already computes an observer mask per entity cell
against `interest_range` (160 blocks by default), so an entity outside that
radius is not replicated and therefore cannot be revealed by any client-side
tool. That makes the interest radius a security parameter, not just a
performance one.

Two consequences follow. Widening interest for convenience widens the ESP
surface, so the default stays as tight as playability allows and a change is
reviewed on both axes. And where stock sends state a player should not have,
matching it exactly is a choice, not an obligation: fidelity to the wire format
is required, fidelity to a stock information leak is not.

This is the one category where zdtd can do better than any mod on the stock
server, and it needs no detector at all.

### 9. The anti-cheat's own attack surface is in scope

Anything added here is new surface, and each piece is bounded on purpose:

| Surface | Bound |
|---|---|
| Guest detector feed | Read-only, no secrets or IPs, severity capped by the host, fuel and memory budgeted, a trap disables only that module |
| Evidence ring | Fixed 64 entries, no packet bodies, no chat text, no IPs; an operator dump is an explicit admin action and is audited |
| Policy configuration | Every enforcement rung defaults off and must be switched on explicitly; kick additionally requires `correct` mode |
| Review surface (webui, telnet) | Authenticated, rate limited, failed and successful sign-ins logged with a timestamp |

The feed is a **versioned ABI**. Widening it later is easy and narrowing it is
not, so the first cut ships the minimum a detector needs and grows by
deliberate revision.

## Consequences

### Positive

- The expensive half (gates) stays where it is provably safe, and the cheap,
  iterable half (detectors) becomes extensible without a rebuild.
- The sibling's design corpus is reusable as a catalog and a policy vocabulary
  rather than as an implementation.
- The ceiling rule makes "is this really Hard?" a mechanical question.
- A hostile plugin cannot escalate: no gate, no policy, no sim, capped severity.

### Negative / costs

- Two severity vocabularies exist across the two repos and have to be kept in
  sync by hand; the mapping table above is the only reconciliation.
- The event feed is a new versioned boundary, and widening it later is easier
  than narrowing it, so the first cut has to be stingy.
- Authority-first means the honest answer to many catalog entries is "close the
  ownership gap", which is slower and less demonstrable than shipping a
  detector.
- Per-detector configuration is more surface than one global mode.
- **The cost of a false positive is higher than the cost of a miss**, and the
  design accepts that trade deliberately. A wrongly kicked player leaves and
  tells other people; a missed cheater is caught by the next detector or by an
  operator. That asymmetry is why every rung defaults to log-only, why `.soft`
  can never open a gate, and why a kick needs two independent detectors. It also
  means this system will always let some cheating through, and saying so up
  front is better than an operator discovering it and losing trust in the
  evidence.

## Alternatives considered

| Option | Why not |
|---|---|
| Gates in Wasm too, for uniformity | Fuel exhaustion or a trap disables the module, so starving a gate bypasses it; plus a boundary copy per C2S package on the tick path |
| Port the Server Guard catalog directly | Most of its Strong detectors exist because the stock server does not own the state. zdtd does. Porting them would ship detection where ownership belongs |
| No guest anti-cheat at all | Heuristics are the part operators most want to tune per server, and the part that most benefits from not requiring a rebuild |
| Let a guest deny a request | That is a gate, and it inherits the fail-open problem in the exact place it is unacceptable |
| Reuse the sibling C# mod against zdtd | It targets the stock Mono dedi and its Harmony seams; zdtd shares neither the runtime nor the internals |
| Client-side detection | Impossible with EAC off and unmodified clients. Not a trade-off, a fact |

## Follow-up

Implementation is [WORK_PLAN.md](../WORK_PLAN.md) T18 through T22, ordered:
close the inventory ownership hole, make observe mode honest, classify the
existing detectors under the ceiling rule, then the guest event feed, then the
attribution and suppression rules.

T18 and T19 are ownership work and are worth more than every detector that
follows.
