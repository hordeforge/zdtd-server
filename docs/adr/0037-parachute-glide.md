# ADR 0037: parachute glide boundary (sense v4 + glide queue verb)

- **Status:** accepted
- **Date:** 2026-08-29
- **Related:** ADR 0020 (Wasm-only plugin API), ADR 0026 (bots as Wasm),
  ADR 0021 (config-driven), PRD 0003 (modlets), AGENTS rule 29 (prove the
  boundary cannot carry it)

## Context

A fully self-contained parachute mod (`mods/parachute/`) needs three things
the current plugin boundary cannot express:

1. **Deceleration** — the server has no player vertical physics
   (`src/server/movement.zig` is a horizontal + Y-delta anti-cheat envelope
   only; players are driven by client C2S positions). The server cannot
   natively slow a fall; deceleration must live in a paired client mod (the
   accepted RealEarth pattern). This ADR does not invent server-side player
   physics or server fall damage (stock has neither server-side).
2. **Worn state** — armor slots are sim authority (`inv_equip_start=55`,
   12 slots; `ItemDef.tags` parses the items.xml `Tags` property), but
   `zdtd.sense` v3 exposes only net_id/kind/alive/pos/hp/yaw/target.
3. **Anti-cheat exemption** — a gliding player falls at a sustained high vy;
   the movement envelope (`clampVertical`, `max_vertical_speed_mps`) would
   reject it as a Y-teleport unless the sim knows the player is gliding.
   `zdtd.queue` verbs are spawn/despawn/damage/say/bot — nothing can flag a
   glide.

Per AGENTS rule 29, the boundary cannot carry this, so the affordances are
added to the boundary (ADR-worthy), not implemented as native behavior.

## Decision

Extend the plugin boundary minimally, keeping sim authority native:

1. **`zdtd.sense` v4** (magic `ZBS4`): per-player records grow by 8 bytes
   (32 → 40) with `vy` (i32, blocks/s, derived server-side from the C2S Y
   history) and `wearing_glider` (u8): the player's armor slots contain an
   item whose `Tags` include the config `[authority] glider_item_tag`
   (default `parachute`). v3 guests stop working (magic bump = fail loud,
   never a silent layout misinterpretation).
2. **`zdtd.queue` verb `glide <net_id> <0|1>`**: sets/clears a per-player
   glide flag (`Player.glide_until_tick`). Attributed per plugin src like the
   other verbs; a withdrawn/disabled module's pending glide ops are cleared
   before the drain (paper 3.1 discipline).
3. **Movement envelope exemption**: while the player's glide flag is set, the
   vertical rejection cap widens to `[authority] glide_vy_cap_mps` (default
   -100 blocks/s; stock envelope otherwise). Horizontal envelope unchanged.
   Fail closed: flag unset → stock envelope.
4. **Deceleration stays client-side** by design (paired client mod); the
   server ships the item data, worn-state authority, the exemption, and
   optional coordination. No server fall-damage leg is invented.

## Consequences

- A mod can now observe player vertical motion and worn state, and legally
  flag a glide — the parachute mod is expressible over the boundary.
- sense v4 is a breaking layout change for existing guests (only the shipped
  core plugins + fps_bot/mcp consume sense; all are rebuilt in-repo).
- `glide` is a trust-bearing verb (a malicious module could exempt itself
  from vertical checks); bounded by the same plugin trust model as
  `spawn`/`damage` (ADR 0020: modules are operator-installed, sandboxed,
  budgeted, withdrawable). The widened cap still bounds abuse (a
  teleport-scale jump is rejected even while gliding).
- Cost if revisited: replacing the client-side deceleration with a server
  physics sim would be a large, separate ADR (server-authoritative player
  motion is out of scope for the stock-wire clone).
