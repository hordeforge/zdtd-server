# Architecture Decision Records (ADR)

Short, numbered decisions for zdtd. Format: context → decision → consequences.
Status is one of: **proposed**, **accepted**, **superseded**, **deprecated**.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | accepted |
| [0002](0002-native-soa-not-third-party-ecs.md) | Native SoA ECS, not third-party ECS core | accepted |
| [0003](0003-no-stock-mod-host.md) | No stock Harmony / IModApi host | accepted |
| [0004](0004-server-authoritative-c2s.md) | Server-authoritative C2S apply | accepted |
| [0005](0005-native-plugin-api.md) | Native plugin API (not stock mods) | proposed |
| [0006](0006-steal-from-mach.md) | Steal patterns from Mach (not the engine) | accepted |
| [0007](0007-player-inventory-c2s-trust.md) | Player inventory C2S trust (interim) | accepted |
| [0008](0008-serialize-once-interest.md) | Serialize-once interest fan-out | accepted |
| [0009](0009-dynamic-package-ids.md) | Dynamic package name → id maps | accepted |
| [0010](0010-data-config-zig-plugins.md) | Stock data + config + Zig systems; Wasm guest mods later | accepted |

Related long-form design: [PLUGIN_API.md](../PLUGIN_API.md), [ECS.md](../ECS.md),
[AUTHORITY.md](../AUTHORITY.md), [INVENTORY.md](../INVENTORY.md),
[HARDCODE_AUDIT.md](../HARDCODE_AUDIT.md), [ASSETS.md](../ASSETS.md),
[../TODO.md](../../TODO.md) (P3 ECS ideas, P4 authority; plugin = ADR 0005),
[INDEX.md](../INDEX.md).
