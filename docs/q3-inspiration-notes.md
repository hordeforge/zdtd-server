# Q3 / Doom 3 bot inspiration notes

The bot brain in `mods/zdtd_bot/zdtd_bot.c` distills *concepts* from the
open-source id Tech fps bot code. This file records which ideas are borrowed
and how they are adapted for a 7DTD wire model. It is a local pointer; the
detailed reverse-engineering write-up of the stock reference behaviour that our
own 7dtd-clanker mod describes lives in the sibling project:
[`../7dtd-clanker/docs/q3-inspiration-notes.md`](../7dtd-clanker/docs/q3-inspiration-notes.md).

Ground rule: id Tech's `botlib`/`BotAimAtEnemy`, `BotCheckAttack`,
`BotChangeViewAngles`, and `bot_character` skill blocks are GPL code we reuse as
*reference*, never copied verbatim. The zdtd brain is a clean-room, distilled
re-derivation expressed in freestanding Wasm C over the host sense/act
boundary (ADR 0026).

## Distilled behaviours

- **Skill tiers (0..4).** Like `bot_character` skill settings, the guest keeps a
  per-roster skill that scales vision range, reaction time and move/attack
  cadence. The host lists skill in `bot status`; the operator sets it with
  `bot skill <0-4>`.
- **Reaction gate.** A target is not engaged until a short reaction delay
  elapses after first sight (Q3's `BotCheckAttack`-style readiness gate). The
  delay scales inversely with skill.
- **Fire throttle.** Holding fire is gated by a burst cadence rather than a
  per-frame check, so a bot cannot machine-gun every tick. Each fire window
  queues a 2-3 shot burst volley (higher skill, more shots), every shot with
  its own hit and headshot roll — mirroring clanker `Weapon.BurstMin/BurstMax`.
- **Target selection.** Nearest *alive* non-self candidate within vision wins,
  but players are preferred over zombies/other bots at equal distance
  (cross-pollinated from clanker `BotBrain.FindTarget`: player score `* 0.82`,
  other bot `* 0.9`), mirroring the proximity-priority model of `BotFindEnemy`.
- **Strafe-orbit vs chase.** When an enemy is inside attack range the bot
  sidesteps on a perpendicular orbit (alternating by slot parity); outside that
  range it closes distance. This is the Q3 strafe-chase duality, but computed
  from the 2-D x/z plane only (7DTD has vertical movement but the bot brain
  aims and positions in the plane and lets the host clamp heights). Higher-skill
  bots flip strafe direction on a deterministic cadence instead of fixed parity.
- **Skill-scaled aim error.** Each engagement a bot rolls a fixed angular error
  from a deterministic per-slot LCG (`skill_aimerr`: ~0.28 rad at skill 0 down
  to ~0.06 rad at skill 4), held for the engagement so aim settles rather than
  jitters.
- **Lead-fire (target prediction).** The guest estimates target velocity from
  its own sense history and aims at a predicted position a time-of-flight
  ahead (`BULLET_SPEED`). A stationary target always yields lead 0, degrading
  gracefully to direct fire.
- **Lost-sight combat memory.** The host only exposes LOS-visible entities, so
  a target behind cover vanishes from the snapshot. The bot retains `BOT_MEMORY_TICKS`
  (5 s) of the last-known position and pursues it, then flushes to patrol.
- **Dodge-on-hit.** The guest watches its own hp across sense passes; a drop
  means it was hit, so the bot breaks into a short evasive dodge (backpedal,
  then a hard strafe on a randomized direction) whose moves bypass command
  gating — mirroring clanker `Bot.OnDamaged` (which reads the damage event via
  a patch; the wasm guest infers it from its own hp).
- **Skill/distance hit accuracy.** A shot only lands when a deterministic roll
  beats `skill_hit_chance(skill, dist)`, cross-pollinated from clanker
  `TryShootBurst` (spread scaled down by difficulty), so low-skill bots miss. A
  second skill-scaled roll flags a headshot (`skill_headshot`), and the host
  applies the 2x `bot_headshot_multiplier` — mirroring clanker
  `HeadshotChance`/`HeadshotMultiplier`.
- **Backpedal + low-hp retreat.** Bots back away when an enemy is inside
  `BACKPEDAL_RANGE` (clanker `BotBrain.Backpedal`); low-health, low-skill bots
  retreat and hold fire (`HP_RETREAT_FRAC`, clanker `BotCharacter.WantsToRetreat`).
- **Wander when idle.** With no candidate in vision (and no combat memory) the
  bot drifts toward a stored wander point instead of standing dead still, and
  faces its travel direction.
- **Command gating / dedup.** `bot move`/`bot look` only re-emit when the value
  changed beyond a deadband (or none sent yet), cooperating with the host's
  stream/move caps (AD 20, AZ 20).

All of the above is deterministic: no wall-clock noise, only a per-slot LCG
seeded from the net id and slot index (AZ 22).

## What is deliberately NOT borrowed

- No pathfinding graph (the host owns movement caps and clamp; the brain only
  requests destination moves). Doom 3-style AAS/areas are out of scope.
- No line-of-sight raycast in the guest: the host pre-filters sense records by
  LOS, so the guest never does geometry.
- No separate skill-per-kill growth or XP. Skill is an operator-set floor, not
  a learned value.
