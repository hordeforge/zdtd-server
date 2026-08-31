# parachute

A fully self-contained mod (ADR 0037): a **parachute item** (wearable
clothing) that deploys when you jump out of a gyrocopter and fall fast. The
server **slows the fall itself**: while the glide flag is armed it clamps the
player's vertical delta to `sink_vy_mps` (default 2.5 blocks/s) and
broadcasts the clamped position, so the deceleration is server-side - no
client mod needed.

## What is in here (everything the mod needs)

| Piece | File | Role |
|---|---|---|
| Manifest | `manifest.toml` | name/version/icon/wasm/preset; opt-in via `[mods] enabled` |
| Item | `Config/items.xml` | XPath patch adding `parachute` (extends `shirtPlain`, tag `parachute`) |
| Glide exemption | `preset.toml` | `[rules.glide] sink_vy_mps = 2.5`, `item_tag = "parachute"` |
| Deploy tuning | `config.toml` | served to the guest via `zdtd.config` (threshold, debounce, announce) |
| Deploy logic | `parachute.zig` + `parachute.wasm` | sense v4 → deploy state machine → `glide` queue verb |
| Docs | `README.md` | this file |
| Icon | `icon.png` | manifest icon |

## Install

```toml
# zdtd.toml
[mods]
enabled = ["parachute"]
```

or flip `enabled = true` in `manifest.toml`. The mod folder is self-contained:
remove it (or the `enabled` entry) and everything it changed is gone (the
item patch, the authority keys, the guest).

## How it works

1. **Item**: the mod's `Config/items.xml` XPath patch adds `parachute` to
   `items.xml` when the manifest mod is enabled. Its directory joins the XML
   patch path after stock `Mods/` patches; the merged catalog ships to clients
   via `NetPackageConfigFile`. Wear it in any armor slot.
2. **Detection**: the guest reads the sense v4 snapshot each tick. A player is
   `wearing_glider` when an armor slot holds an item tagged `parachute`
   (`[rules.glide] item_tag`); the snapshot also carries the server-
   derived vertical velocity (`vy`).
3. **Deploy**: when a wearing player falls below `deploy_vy_threshold` for
   `deploy_delay_ticks` consecutive ticks, the guest queues
   `glide <net_id> 1` (ADR 0037 boundary). The movement envelope then clamps
   the vertical delta to `sink_vy_mps` instead of the stock cap, so the fall
   is slowed and the glide is not rejected as a Y-teleport.
4. **Clear**: on landing (`vy > -1`) or when the item is removed or the player
   leaves the view, the guest queues `glide <net_id> 0`. A disabled/reloaded
   module's applied glide flags are withdrawn by the host (paper 3.1).

## Config (`config.toml`)

| Key | Default | Meaning |
|---|---|---|
| `deploy_vy_threshold` | `-6.0` | vertical velocity (blocks/s) that arms deployment |
| `deploy_delay_ticks` | `10` | consecutive ticks below the threshold before deploy |
| `require_worn` | `true` | only deploy while the item is worn |
| `item_tag` | `parachute` | tag matched in the sense `wearing_glider` bit |
| `announce_on_deploy` | `true` | broadcast on the stock chat on deploy |
| `announce_text` | `deployed their parachute` | announce message |

## Limits (honest)

- **Server-side deceleration**: the server clamps the player's vertical delta
  while gliding and broadcasts the clamped position; observers see the slow
  fall and the player's own position is corrected to the glide path. The
  player's *local* physics and fall-damage calculation stay client-side (the
  server has no fall-damage mechanism in the stock wire), so a hard landing
  right after a short glide may still count a client-side fall hit - the
  chute is a fall *slow-down*, not a fall-damage cancel.
- **Item rendering**: a stock client needs the same `Config/items.xml`
  patch (client-side modlet install) to render the new item; without it the
  item exists server-side only. This is the standard modlet item path (PRD
  0003), not a behavior mod.

## Notes

- The glide clamp still bounds abuse: a teleport-scale jump is rejected even
  while gliding (ADR 0037 consequences).
- The glide flag expires after 5 s even if the guest forgets to clear it
  (`glide_window_ticks`), and a withdrawn module's flags are cleared.
