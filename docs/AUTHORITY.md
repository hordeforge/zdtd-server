# Server authority (P4 spine)

Short map of **who owns state** and the gates already on the C2S path.
ADR: [adr/0004-server-authoritative-c2s.md](adr/0004-server-authoritative-c2s.md).
Backlog depth: [TODO.md](../TODO.md) P4 section.

## Principle

Sim owns world blocks, TE contents, entity HP/alive, quests, locks, and time.
**Target** ownership of player inventory is the same; **today** the stock UI
path still trusts C2S hold/bag pushes (see below). C2S is a **request**:
validate → apply or reject → broadcast the **result**. Never apply client
**world** blobs blindly (AGENTS rule 15). Inventory: [ADR 0007](adr/0007-player-inventory-c2s-trust.md).

## Mode config

| Property | Values | Default |
|---|---|---|
| `ZdtdAuthorityMode` | `observe` \| `correct` | `correct` |

Parsed in `src/server/config.zig`, stored on `Game.authority_mode`
(`InitOptions.authority_mode`). Helper: `Game.authorityCorrects()`.

| Mode | Behavior |
|---|---|
| **correct** | Hard invariants reject/clamp (reach, phase, ownership, damage caps). Production default. |
| **observe** | Same Hard drops for join phase and reach today; reserved for soft signals (ledgers, evidence) that only count without changing gameplay. |

`permissive` is accepted as an alias of `observe`. No auto-kick / ban ladder yet
(Enforce is later P4).

## Gates already in process

| Gate | Where | Notes |
|---|---|---|
| **Join phase matrix** | `phase_gate.zig` via `handlePackage` | Phases: `connecting` / `joined` / `playing` (`joined`+`entered`). Pre-play: join-SM allowlist only; play C2S dropped + `phase_rejects`. Always Hard. |
| **Movement envelope** | `movement.zig` on PosAndRot / RelPosAndRot | Soft max 20 m/s horizontal over server dt. **correct**: clamp + soft S2C PosAndRot snap; **observe**: count `movement_rejects` only. Reset on spawn/teleport. |
| **C2S bounds** | SetBlock / Explosion / TE / DamageEntity | Reach ~96 blocks; damage strength cap 200; fatal damage vs NPC only. |
| **Ownership** | Bag / InvTx / player entity id | No cross-player inv writes; editor must be local player slot. |
| **Player inv (interim)** | PlayerInventory / player Bag C2S | **Client-trusting apply** into ECS (ADR 0007). No S2C PlayerInventory echo. Admin `give` = loot bag drop. |
| **Interest / no self-echo** | `replicate` / scenarios | Motion and entity updates go to observers; sender does not get own PosAndRot echo. Serialize-once: ADR 0008. |
| **Rate / lock** | join IP throttle; lock channels | ~500 ms join gap (loopback exempt); TE lock holder deny + stale release. |
| **Land claim** | SetBlock | Non-owner edits inside claim denied. |
| **PvP** | DamageEntity | `PlayerKillingMode` 0 drops player→player damage. |

## Pipeline (current)

```text
UDP → LiteNet → deframe
  → phase matrix (phase_gate; connecting|joined|playing)
  → typed parse (no blind blob apply)
  → Hard checks (reach, ownership, caps, movement envelope)
  → sim apply (ecs / world store)
  → interest replicate result
```

Inv cause ledger (first cut): `World.inv_ledger` fixed ring (`ecs/inv_ledger.zig`),
causes loot|craft|give|place|eat|drop|tx|unknown; apm `inv_ledger_events`.
Evidence JSONL and enforce ladder still open; no second world.

## Related

- [adr/0004-server-authoritative-c2s.md](adr/0004-server-authoritative-c2s.md) principle
- [adr/0007-player-inventory-c2s-trust.md](adr/0007-player-inventory-c2s-trust.md) inv interim
- [adr/0008-serialize-once-interest.md](adr/0008-serialize-once-interest.md) interest fan-out
- [INVENTORY.md](INVENTORY.md) slot layout and wire directions
- [GAME_OPTIONS.md](GAME_OPTIONS.md) for stock serverconfig knobs
- [PLUGIN_API.md](PLUGIN_API.md) hooks must not bypass these gates
- Sibling `7dtd-server-guard` is Harmony-on-stock only; outcomes reimplemented here
