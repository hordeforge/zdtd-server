# Architecture Decision Records (ADR)

Short, numbered decisions for zdtd. Format: context → decision → consequences.
Status is one of: **proposed**, **accepted**, **superseded**, **deprecated**.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | accepted |
| [0002](0002-native-soa-not-third-party-ecs.md) | Native SoA ECS, not third-party ECS core | accepted |
| [0003](0003-no-stock-mod-host.md) | No stock Harmony / IModApi host | accepted |
| [0004](0004-server-authoritative-c2s.md) | Server-authoritative C2S apply | accepted |
| [0005](0005-native-plugin-api.md) | Native plugin API (not stock mods) | superseded by 0020 |
| [0006](0006-steal-from-mach.md) | Steal patterns from Mach (not the engine) | accepted |
| [0007](0007-player-inventory-c2s-trust.md) | Player inventory C2S trust (interim) | accepted |
| [0008](0008-serialize-once-interest.md) | Serialize-once interest fan-out | accepted |
| [0009](0009-dynamic-package-ids.md) | Dynamic package name → id maps | accepted |
| [0010](0010-data-config-zig-plugins.md) | Stock data + config + Zig systems; Wasm guest mods later | accepted (plugin/dynlib part superseded by 0020) |
| [0011](0011-custom-zch-world-overlay.md) | Custom ZCH world overlay (not stock region saves) | accepted |
| [0012](0012-single-threaded-tick.md) | Single-threaded 20 TPS tick + bounded parallel helpers | accepted |
| [0013](0013-clean-room-litenet.md) | Clean-room LiteNet stack (no stock LiteNetLib runtime) | accepted |
| [0014](0014-missing-beats-fake.md) | Missing beats fake (stock wire/content fidelity) | accepted |
| [0015](0015-ecs-item-id-vs-stock-type.md) | ECS item_id vs stock absolute type (mapping, not dual space) | accepted |
| [0016](0016-fixedsizecc-false-stream-cgo.md) | fixedSizeCC=false + stream radius for CGO / terrain | accepted |
| [0017](0017-player-identity-login-name.md) | Player persist identity is login name | accepted |
| [0018](0018-webui-ops-dashboard.md) | Operator WebUI WU0–WU2 shape | accepted |
| [0019](0019-validation-triad.md) | Validation triad: loadgen + stock client + zdtd apm | accepted |
| [0020](0020-wasm-only-plugin-api.md) | Wasm-only plugin API | accepted |
| [0021](0021-config-driven-game-modes.md) | Config-driven game modes: reflected binder, `Rules` struct, hooks for logic | accepted (extends 0010) |
| [0022](0022-anti-cheat-architecture.md) | Anti-cheat: authority first; native gates, Wasm detectors, native policy | accepted |

Related long-form design: [PLUGIN_API.md](../PLUGIN_API.md), [ECS_SYSTEMS.md](../ECS_SYSTEMS.md),
[AUTHORITY.md](../AUTHORITY.md), [INVENTORY.md](../wire/INVENTORY.md),
[HARDCODE_AUDIT.md](../reviews/HARDCODE_AUDIT.md), [ASSETS.md](../ASSETS.md),
[WIRE_CHUNK.md](../wire/WIRE_CHUNK.md), [MAPS.md](../MAPS.md),
[WEBUI.md](../WEBUI.md), [STD_ABSTRACTIONS.md](../STD_ABSTRACTIONS.md),
[../TODO.md](../../TODO.md) (P3 ECS ideas, P4 authority; plugin = ADR 0020),
[INDEX.md](../INDEX.md).
