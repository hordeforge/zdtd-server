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
  per-frame check, so a bot cannot machine-gun every tick.
- **Target selection.** Nearest *alive* non-self candidate within vision wins
  (players, zombies and other bots are all targetable), mirroring the
  proximity-priority model of `BotFindEnemy`.
- **Strafe-orbit vs chase.** When an enemy is inside attack range the bot
  sidesteps on a perpendicular orbit (alternating by slot parity); outside that
  range it closes distance. This is the Q3 strafe-chase duality, but computed
  from the 2-D x/z plane only (7DTD has vertical movement but the bot brain
  aims and positions in the plane and lets the host clamp heights).
- **Wander when idle.** With no candidate in vision the bot drifts toward a
  stored wander point instead of standing dead still.

## What is deliberately NOT borrowed

- No pathfinding graph (the host owns movement caps and clamp; the brain only
  requests destination moves). Doom 3-style AAS/areas are out of scope.
- No line-of-sight raycast in the guest: the host pre-filters sense records by
  LOS, so the guest never does geometry.
- No separate skill-per-kill growth or XP. Skill is an operator-set floor, not
  a learned value.
