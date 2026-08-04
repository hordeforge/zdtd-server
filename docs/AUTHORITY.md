# Server authority (P4 spine)

Short map of **who owns state** and the gates already on the C2S path.
ADR: [adr/0004-server-authoritative-c2s.md](adr/0004-server-authoritative-c2s.md).
Backlog depth: [TODO.md](../TODO.md) P4 section.

## Principle

Sim owns world blocks, inventory, TE contents, entity HP/alive, quests, locks,
and time. C2S is a **request**: validate → apply or reject → broadcast the
**result**. Never apply client world/inv blobs blindly (AGENTS rule 15).

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
| **Join phase** | `game.handlePackage` | Unjoined peers: only login/config packages; play C2S dropped. |
| **C2S bounds** | SetBlock / Explosion / TE / DamageEntity | Reach ~96 blocks; damage strength cap 200; fatal damage vs NPC only. |
| **Ownership** | Bag / InvTx / player entity id | No cross-player inv writes; editor must be local player slot. |
| **Interest / no self-echo** | `replicate` / scenarios | Motion and entity updates go to observers; sender does not get own PosAndRot echo. |
| **Rate / lock** | join IP throttle; lock channels | ~500 ms join gap (loopback exempt); TE lock holder deny + stale release. |
| **Land claim** | SetBlock | Non-owner edits inside claim denied. |
| **PvP** | DamageEntity | `PlayerKillingMode` 0 drops player→player damage. |

## Pipeline (current)

```text
UDP → LiteNet → deframe
  → join-phase allowlist
  → typed parse (no blind blob apply)
  → Hard checks (reach, ownership, caps)
  → sim apply (ecs / world store)
  → interest replicate result
```

Future P4 pieces (matrix counters, movement envelope, inv cause ledger,
evidence JSONL) plug into this path without a second world.

## Related

- [GAME_OPTIONS.md](GAME_OPTIONS.md) for stock serverconfig knobs
- [PLUGIN_API.md](PLUGIN_API.md) hooks must not bypass these gates
- Sibling `7dtd-server-guard` is Harmony-on-stock only; outcomes reimplemented here
