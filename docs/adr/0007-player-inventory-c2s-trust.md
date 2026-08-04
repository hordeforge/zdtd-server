# ADR 0007: Player inventory C2S trust (interim exception to 0004)

- **Status:** accepted
- **Date:** 2026-08-04
- **Supersedes (partial):** none; **narrows** [0004](0004-server-authoritative-c2s.md) for player hold only

## Context

Stock clients push full toolbelt/bag/equip via `NetPackagePlayerInventory` and
bag via `NetPackageBag` (C→S). True server-authoritative inventory needs a
complete transactional model (craft consume, loot grant, TE transfer, dupe
guards, S2C correction) that is not fully wired for the stock UI path yet.

Early attempts to server-write inventory (e.g. admin `give` into ECS slots) were
clobbered by the next client PlayerInventory push. Join PDF still seeds from
server persist; after enter, the client's hold is what survives rejoin.

## Decision

1. **Player hold inventory is client-trusting for C2S apply** on
   `NetPackagePlayerInventory` and player `NetPackageBag`: parse, reverse map
   types into ECS, overwrite the local player's slots. Do **not** S2C-echo
   PlayerInventory (stock rejects that direction).
2. **Ownership still applies:** only the peer's own player slot; bag packages for
   other entity ids stay TE/loot paths.
3. **Admin `give`** is a loot-bag drop at the player (pickup uses the same C2S
   flow), not a silent ECS overwrite.
4. **ECS bag is a deliberate subset of stock bag size:**
   - Stock bag = 45 (`stock_inv.bag_slots`)
   - ECS bag = 32 (`components.inv_bag_count`, slots 10..41)
   - Apply truncates excess client bag indices; encode pads empty stock slots.
   Full 45 + stock equipment width is deferred until persist/UI need it.
5. **Target end state** remains ADR 0004: server owns inventory. Revisit when
   InvTx + craft + TE + loot grant paths can correct the client without wedge.

## Consequences

- Dupes / client-invented stacks are possible on the hold path until full
  authority lands; world/TE/HP gates still correct-mode.
- Persist (`players.zsv`) stores what the client last pushed (plus join PDF).
- Wallet sync may lift coin counts from inventory (client-authoritative stacks).
- Implementers must not assume AUTHORITY "sim owns inv" without reading this ADR.

## Alternatives considered

| Option | Notes |
|---|---|
| Reject PlayerInventory C2S | Breaks stock UI hold/sync |
| Server invent S2C PlayerInventory | Stock direction rejects; wedge risk |
| Expand ECS bag to 45 now | Correct model later; not needed for current playtest |
| Full InvTx-only model | Loadgen bots; vanilla client still uses PlayerInventory |
