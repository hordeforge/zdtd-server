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
   only; players are driven by client C2S positions). This ADR makes the
   server slow the fall by clamping the C2S vertical delta while the glide
   flag is armed and broadcasting the clamped position (the stock
   authority-correction path) - no client mod needed. It does not invent
   server-side player physics or server fall damage (stock has neither
   server-side); fall damage stays client-owned.
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
   item whose `Tags` include the config `[rules.glide] item_tag`
   (default `parachute`). v3 guests stop working (magic bump = fail loud,
   never a silent layout misinterpretation).
2. **`zdtd.queue` verb `glide <net_id> <0|1>`**: sets/clears a per-player
   glide flag (`Player.glide_until_tick`). Attributed per plugin src like the
   other verbs; a withdrawn/disabled module's pending glide ops are cleared
   before the drain (paper 3.1 discipline).
3. **Server-side deceleration (sink)**: while the player's glide flag is
   set, the C2S vertical delta is **clamped** to `[rules.glide]
   sink_vy_mps` (default 2.5 blocks/s) instead of rejected; the clamped
   position is broadcast back to the player and observers (the stock
   authority-correction path), so the fall is slowed server-side - no client
   mod needed. Horizontal envelope unchanged. Fail closed: flag unset →
   stock envelope. A teleport-scale jump is still rejected even gliding.
4. **No server fall-damage leg is invented**: the client owns local physics
   and fall-damage calculation (stock wire), so the chute is a fall
   slow-down, not a damage cancel; a hard landing right after a short glide
   may still count a client-side fall hit. The mod ships the item data and
   the worn-state authority.

## Consequences

- A mod can now observe player vertical motion and worn state, and legally
  flag a glide — the parachute mod is expressible over the boundary, and
  deceleration is server-side (position clamp + broadcast).
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
