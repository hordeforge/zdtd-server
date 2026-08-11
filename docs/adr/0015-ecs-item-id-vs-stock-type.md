# ADR 0015: ECS item_id vs stock absolute type (mapping, not dual space)

- **Status:** accepted
- **Date:** 2026-08-05
- **Related:** [0010](0010-data-config-zig-plugins.md), [0007](0007-player-inventory-c2s-trust.md),
  [../INVENTORY.md](../wire/INVENTORY.md), [../ASSETS.md](../ASSETS.md)

## Context

Stock wire uses **absolute** `ItemValue.type` (blocks below
`ItemsStartHere`, items at `ItemsStartHere + relative`). Sim storage
(`InvSlot.item_id: u16`) needs a dense, stable key for SoA columns, craft, eat,
and offline tests without requiring a full AssignIds dump on every unit path.

ADR 0010 forbids inventing a **parallel production id space** that diverges from
what the client resolves. Hand-maintained `item_id` tables that silently map to
wrong stock types cause dupe/ghost stacks and join PDF desync.

## Decision

1. **Production authority** is stock names + AssignIds / `items.xml` order via
   `ItemTable` (`ecsIdByName`, `stockTypeFor`, reverse map on C2S). Numeric wire
   types are never hard-coded as permanent outside fixtures.
2. **ECS `item_id` is a local handle**, not a second catalog of game content:
   - With game-dir loaded: reverse map stock absolute type ↔ ECS id through the
     loaded table; stack/eat/armor props come from XML after name resolve.
   - Without game-dir (unit/offline): tiny `builtin_defs` + `builtinStockName`
     exist only so tests and no-asset runs still encode parseable v9 stacks
     (`ItemsStartHere + id` fallback). Production paths must not prefer
     builtins when the dump/table is present (warn on leakage).
3. **Persist stores ECS ids** in ZPV3 (and legacy ZPV2) / ZCT1 slots. After
   restart, rejoin PDF remaps through the current table; wrong dump version can
   orphan stacks (accept fail-closed over inventing type ids).
4. **Wire encode/decode** always goes through stock absolute types on the wire
   (`stock_inv`); ECS never sends bare builtin ids as absolute types without
   the ItemsStartHere / catalog path.

## Consequences

- One conceptual catalog (stock names); ECS ids are indices into the loaded
  table (or offline builtins), not a permanent cross-version product id.
- Offline tests stay green without Steam installs; production with `--game-dir`
  must load AssignIds + items.xml.
- Expanding ECS bag/equip width (ADR 0007) does not require a new item id space.

## Alternatives considered

| Option | Notes |
|---|---|
| Store stock absolute `i32` type in every slot | Larger SoA; still need reverse for props; worse offline |
| Sequential XML declaration order as wire id | Diverges from AssignIds; forbidden by ASSETS/AGENTS |
| No builtins; skip all inv tests without dump | Too heavy for unit CI |
| Hand-copied full item table in Zig | Bucket A hardcode; rejected ADR 0010 |
