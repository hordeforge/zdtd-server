# Stock config assets

zdtd can load real game **Data/Config** files (starting with quests) so the
sim catalog is not hard-coded.

## Paths

| Flag | Role |
|---|---|
| `--game-dir` | Install root; loads `$game/Data/Config/quests.xml` |
| `--map` | Stock world; also probes sibling `Data/Config/quests.xml` |
| `--config-dir` | Explicit `Data/Config` directory |
| `--quests` | Explicit `quests.xml` path (fixture or stock) |

Resolution order: `--quests` → `--config-dir` → `--game-dir` → derive from `--map`.

If nothing is found, the **builtin** three-quest catalog stays active.

```bash
GAME="$HOME/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server"
zdtd --game-dir "$GAME" --world-name Navezgane --world worlds/nav_save
# or offline fixture:
zdtd --quests assets/fixtures/quests.xml --world worlds/zdtd_default
```

Boot log includes `quests=… defs=N starter=…`.

## quests.xml → ECS catalog

Source: stock `Data/Config/quests.xml` (or fixture).

| Stock field | zdtd |
|---|---|
| `<quests starter_quest>` | `Catalog.starter_id` / `starter_name` (auto-accepted on join) |
| `<quest id="…">` | `QuestDef` with sequential numeric `id` for wire |
| `name_key` / id | `title` / `name` |
| `difficulty_tier` | kill target scaling for ClearSleepers |
| `completiontype=TurnIn` | `turn_in`: objectives set `ready_turn_in`; complete on trader open |
| `quest_list id="trader_jen_quests"` | `Catalog.lists` for trader offer tables |
| `<reward type="Exp">` | `reward_coin ≈ exp/20` (lightweight economy) |

### Primary objective mapping

Stock quests are multi-phase. We pick the **highest-score** playable objective:

| Stock objective | QuestKind |
|---|---|
| `ClearSleepers` | `kill_zombies` (count = 3 + tier×2 if unset) |
| `FetchFromContainer` / `FetchKeep` / treasure | `fetch_item` |
| `Goto id="trader"` / `InteractWithNPC` | `fetch_trader` |
| `RandomPOIGoto` / `Goto` / … | `goto_point` (hashed target coords) |
| Rally / StayWithin / Return scaffolding | ignored as primary |

Honest limits: no localization CSV,
no full reward choice UI. Turn-in and kill/goto/trader progress are playable
server-side hooks.

## Code

```text
src/assets/xml_util.zig   comment strip + attr/property helpers
src/assets/quests.zig     parser + tryLoad path resolution
src/ecs/quest.zig         Catalog resource types (builtin or stock)
src/ecs/systems.zig       questAccept / journal ops on player components
assets/fixtures/quests.xml offline subset for tests
```

## entityclasses / recipes / loot

| File | Module | Boot log |
|---|---|---|
| `entityclasses.xml` | `src/assets/entities.zig` | `entityclasses defs=N zombie=… hash=…` |
| `recipes.xml` | `src/assets/recipes.zig` | `recipes defs=N` |
| `loot.xml` | `src/assets/loot.zig` | `loot groups=N containers=N` |

Sleeper volumes (prefab XML under `Data/Prefabs`, not Config):
`src/world/sleepers.zig` → `sleeper volumes=N` on stock map load.

## Extending

Same pattern for `traders.xml`, `entitygroups.xml`, `vehicles.xml`: add
`src/assets/<name>.zig`, resolve under `Data/Config`, attach to ECS resources.
