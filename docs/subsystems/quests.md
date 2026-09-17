# Quests and objectives

This subsystem owns quest state per player: which quests a player holds, how far each objective has advanced, the quest and objective packages on the wire, and the C2S operations that accept, advance, share and turn in quests. The boundary is the quest *definition* catalog on one side and the wire body layout on the other. Definitions are parsed from stock `Data/Config/quests.xml` by `assets/quests.zig` and stored as a `Catalog` value on the ECS world (`src/ecs/world.zig:400`), so the sim never imports the asset loader. Package framing, id resolution and body encoding belong to `wire/`; the journal and progress types belong to `ecs/`; validation, party fan-out and the bridge to the plugin verdicts belong to `server/`. Import direction is enforced: `ecs` may import `util` only and must not import `wire`, `server`, `world`, `assets`, `litenet` or `apm` (`src/ecs/root.zig:3`), `assets` may import `util` and pure `ecs` types for catalog to sim mapping (`src/assets/root.zig:3`), and `server` sits on top and may import anything (`src/server/root.zig:3`). Nothing about a quest is stock-compatible merely because zdtd encodes and decodes it: the wire tests below pin zdtd's own byte layout, and only a stock client `Read` proves the client accepts it. No mid-session server-to-client journal sync package is built as of this reading, so a quest accepted after join is not pushed to the client journal from here.

Sources: [`src/ecs/quest.zig`](../../src/ecs/quest.zig), [`src/ecs/components.zig`](../../src/ecs/components.zig), [`src/ecs/systems.zig`](../../src/ecs/systems.zig), [`src/ecs/world.zig`](../../src/ecs/world.zig), [`src/wire/stock_quest.zig`](../../src/wire/stock_quest.zig), [`src/wire/packages.zig`](../../src/wire/packages.zig), [`src/server/c2s/quest.zig`](../../src/server/c2s/quest.zig), [`src/server/game/quest.zig`](../../src/server/game/quest.zig), [`src/server/game/social.zig`](../../src/server/game/social.zig), [`src/assets/quests.zig`](../../src/assets/quests.zig), [`src/server/persist.zig`](../../src/server/persist.zig).

## Ownership and boundary

Four layers hold quest code. `ecs/quest.zig` owns the definition types (`QuestDef`, `PhaseSpec`, `FlatObjective`, `RewardSpec`, `QuestActionSpec`, `QuestEventSpec`), the tag helpers, the `QuestPolicy` tunables and the `Catalog` resource with its `byId` / `byName` / `listById` lookups. `ecs/components.zig` owns the per-player record (`QuestProgress`, `Journal`). `ecs/systems.zig` owns every mutation: accept, objective bumps, phase advance, failure, rally activation, POI lock, and the tick-time proximity checks. `assets/quests.zig` only turns XML into a `Catalog`; it never touches a player. The `server` package owns the trust boundary, the offers list, the party fan-out and the player-facing text gates.

The C2S half is one handler in the fixed dispatch order, after join, move, inv and blocks (`src/server/c2s/dispatch.zig:43`). Its contract is a name match with a boolean result, so an unmatched name falls through to the next domain (`src/server/c2s/quest.zig:28`):

```zig
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
```

The handler covers more than quests: it also carries parties, allies, waypoints, trader data and vending machines, because those packages arrive through the same stock exchange (`src/server/c2s/quest.zig:1`). The boundary ends where it calls `systems.*` or `packages.*`; it does not build a body layout by hand.

## Per-player state: QuestProgress and Journal

One record per accepted quest, with the fields that survive a restart plus the ones the sim tracks in memory. The header fields of the slot (src/ecs/components.zig:641):

```zig
pub const QuestProgress = struct {
    def_id: u16 = 0,
    /// Stock Quest.QuestCode (distinct from catalog def_id when possible).
    quest_code: i32 = 0,
    active: bool = false,
    completed: bool = false,
    ready_turn_in: bool = false,
    /// Failed by a ForcePhaseFinish objective left incomplete (stock
    /// Quest.CloseQuest(Failed)): the slot stays visible to the client as a
    /// failed quest and is never re-offered while present.
    failed: bool = false,
    progress: u16 = 0,
    /// 1-based phase matching stock quest objective phase attributes.
    phase: u8 = 1,
```

The tail fields are `obj_progress: [max_quest_objectives]u16`, per flat-objective progress indexed by declaration order and used only by XML-parsed defs (`src/ecs/components.zig:659`); `rally_activated: bool` (`:662`); `poi: PoiRect`, the footprint the quest runs in (`:665`); `is_shared: bool`, latched when the owner's party is handed the quest (`:669`); and `giver_x` / `giver_y` / `giver_z`, the trader that offered it (`:673`). The record stores progress counts only: the required count and the phase list come from the catalog at read time, so an XML edit re-reads against existing slots.

Eight slots per player, never a heap allocation (`src/ecs/components.zig:588`). The journal itself is a flat array with two lookups (src/ecs/components.zig:678):

```zig
pub const Journal = struct {
    slots: [max_journal]QuestProgress = [_]QuestProgress{.{}} ** max_journal,

    pub fn findActive(self: *Journal, def_id: u16) ?*QuestProgress {
        for (&self.slots) |*s| {
            if (s.active and !s.completed and s.def_id == def_id) return s;
        }
        return null;
    }

    pub fn findFree(self: *Journal) ?*QuestProgress {
        for (&self.slots) |*s| {
            if (!s.active and !s.completed) return s;
        }
        for (&self.slots) |*s| {
            if (!s.active) return s;
        }
        return null;
    }
```

`findFree` prefers a slot that was never used over a completed one, so a completed quest's history is not recycled while a spare slot exists. Every system guards on the journal component mask before reading the record (`src/ecs/systems.zig:1007`, `:1076`, `:1099`), which keeps the SoA columns independent.

## Catalog and quest id resolution

The catalog is the only bridge from XML names to sim ids. Its header (src/ecs/quest.zig:461):

```zig
pub const Catalog = struct {
    defs: []const QuestDef = builtin_defs[0..],
    lists: []const QuestList = &.{},
    starter_id: u16 = 1,
    starter_name: []const u8 = "clear_the_noise",
    max_tier: u8 = 0,
    quests_per_tier: u8 = 0,
    /// `<quest_tier_reward tier="N">` quest ids, resolved to catalog def ids
    /// in document order (stock `QuestEventManager.questTierRewards`, fired
    /// by `HandleNewCompletedQuest` when a completion raises the faction
    /// tier). Missing quests resolve to 0 and never fire (fail closed).
    tier_rewards: []const u16 = &.{},
    source: CatalogSource = .builtin,
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source_path: []const u8 = "",
    /// Objective `type=` -> phase-kind mapping, config rows first (zdtd.toml /
    /// mode pack `[quests] objective_kinds`) then the builtin stock defaults.
    /// parseCatalog replaces the default with the merged table.
    objective_kinds: []const ObjectiveKindMap = builtin_objective_kinds[0..],
    /// Effective quest sim-policy tunables (ADR 0021): kill-count defaults,
    /// goto/stay radius fallbacks - merged from `[quests]` by main.zig.
    policy: QuestPolicy = .{},
```

Ids are sequential and assigned in XML document order, starting at 1 (`src/assets/quests.zig:886`, incremented at `:929`). `byId` assumes that order and checks slot `id - 1` first, then falls back to a scan for a gappy or modded catalog (`src/ecs/quest.zig:508`). `byName` scans the whole table and ignores unnamed defs (`src/ecs/quest.zig:520`). Offer lists resolve their `<quest id="..."/>` entries to those ids at parse time (`src/assets/quests.zig:967`), the starter is chosen by name from the `<quests starter_quest=...>` attribute (`src/assets/quests.zig:939`), and a tier-reward quest that does not resolve stays 0 so it never fires (`src/assets/quests.zig:1021`). With no XML the catalog falls back to three builtin defs and `starter_id` 1 (`src/ecs/quest.zig:545`). No numeric quest id crosses the wire: the offer entry and the journal carry the quest name string (`src/wire/stock_quest.zig:328`, `:218`), which is why the persistence format was widened to save the name next to the id (`src/server/persist.zig:560`).

## Objective progress and the phase graph

A phase is driven by one or more flat objectives. The objective record carries its own phase, required count, optionality and failure flag (src/ecs/quest.zig:357):

```zig
pub const FlatObjective = struct {
    /// Stock BaseObjective.Phase (1-based; 0 = always-active, checked in
    /// every phase).
    phase: u8 = 1,
    kind: PhaseKind = .auto,
    required: u16 = 1,
    optional: bool = false,
    force: bool = false,
    /// ClearSleepers objectives gate kills to the bound POI (stock
    /// ObjectiveClearSleepers counts the volume spawns as the target).
    poi_gated: bool = false,
};
```

All progress lands in one function, called by every producer. It adds the delta to each matching objective of the current phase plus always-active phase-0 objectives (src/ecs/systems.zig:881):

```zig
fn bumpPhase(w: *World, ps: Slot, s: *c.QuestProgress, d: quest.QuestDef, kind: quest.PhaseKind, n: u16) void {
    if (d.objectives.len > 0) {
        var advanced = false;
        for (d.objectives, 0..) |o, i| {
            if (o.kind != kind) continue;
            if (o.phase != s.phase and o.phase != 0) continue;
            if (i >= s.obj_progress.len) continue;
            // ClearSleepers (poi_gated kill): the target is the bound POI's
            // live sleeper population, not the def's policy floor (stock
            // ObjectiveClearSleepers counts the volume spawns; audit B25).
            // The Game hook sums the volumes in the rect; 0/unset keeps the
            // def required.
            var req: u16 = @max(1, o.required);
```

A phase advances only when every non-optional objective of that phase is complete (`src/ecs/systems.zig:940`). A remaining `force` objective fails the whole quest with `failQuest` instead (`src/ecs/systems.zig:917`, `:973`). Defs without a phase list keep a single `progress` counter compared against `target_count` (`src/ecs/systems.zig:930`, `:754`). Objective kinds the sim cannot drive resolve to `.auto` or, for `rally` without a POI rect, to scaffolding that auto-completes on entry rather than deadlocking the quest (`src/ecs/quest.zig:233`, `src/ecs/systems.zig:788`).

Producers are all server-side. Player kills credit through `questOnZombieKilled` (`src/ecs/systems.zig:1097`), container loot through `questOnFetchItem` (`:1161`), crafting through `questOnCraft` (`:1179`), opening a trader window through `questOnTraderOpen` (`:1122`), rally activation through `questOnRallyActivated` (`:1264`), and the tick proximity checks `questTickGoto` and `questTickStayWithin` fire from accepted movement (`:1329`, `:1283`). Completion is queued, not paid inline: `completeQuest` pushes `{ slot, def_id }` onto a fixed four-entry ring (`src/ecs/systems.zig:737`, ring sized at `src/ecs/world.zig:416`) and the tick-end drain pays coin, items, exp and tier rewards after the `on_quest_complete` plugin verdict (`src/server/game/step.zig:417`, `:430`). A fifth completion in one tick drops the oldest.

## C2S quest operations and their validation

Each accepted package is validated against the sender before it changes anything. Identity checks compare the body's entity id with the peer's own: `SharedQuest` refuses a `remove_quest` whose `shared_by_entity_id` is not the sender (`src/server/c2s/quest.zig:129`) and refuses `add_shared_member` / `remove_shared_member` whose `shared_with_entity_id` is not the sender (`:169`), `PartyQuestChange` checks `sender_entity` (`:187`), the treasure request checks `player_id` (`:249`), the waypoint relay checks `inviter_entity_id` (`:316`). Rate gates take a block token on the three packages that fan out or relay to other peers (`:70`, `:302`, `:370`, token bucket in `src/server/game/rate_limits.zig:33`). Trader operations also require reach: a list exchange or window open outside `inTradeReach` is dropped (`:464`, `:573`), because the accept marker would otherwise hand out quests from any trader on the map.

Acceptance comes from the trader list, not from a dedicated accept package. A `remove_quest` entry names the index the client took, the handler walks the trader's filtered offer list, skips entries that are not stock client names or do not match the requested tier, skips quests already active, and accepts the matching index (`src/server/c2s/quest.zig:486`). The tier is clamped to `max_quest_tier` from the XML root before the cast (`:472`), and the accepting trader's transform is written into the slot as the quest giver so the client's return-to-giver marker points at the real NPC (`:499`). Acceptance itself is gated in the sim: the catalog must contain the def, the `on_quest_accept` plugin verdict must not deny, the quest must not already be active or failed, and a free slot must exist (`src/ecs/systems.zig:1008`, `:1013`, `:1017`). A successful accept is shared with the party through `acceptQuestFor` (`src/server/game/social.zig:310`), which latches `is_shared` and gives each member a copy carrying the owner's quest code and POI (`src/server/game/social.zig:342`).

Objective events from the client mirror client-side progress into the server journal (src/server/c2s/quest.zig:394):

```zig
        if (packages.parseQuestObjectiveUpdate(body)) |u| {
            switch (u.event_type) {
                .block_activated => _ = systems.questObjectiveEvent(&self.sim, c.slot, u.quest_code, .block_activate),
                .treasure_complete => _ = systems.questObjectiveEvent(&self.sim, c.slot, u.quest_code, .fetch_item),
                .treasure_radius_break => questTreasureRadiusBreak(self, c.slot, u.quest_code),
            }
```

Progress reports the server already derives are validated and dropped rather than applied twice: the goto-point report, because proximity is checked each tick (`src/server/c2s/quest.zig:213`), the kill-award and shared-party-kill reports, because kills are credited at the death path (`:336`, `:351`), `AllyResponse` and `PartyData` (`:294`, `:209`). `NetPackageQuestTreasurePoint` is the exception: it is a request, and the handler answers it with a dig site anchored on the quest's bound POI and the terrain height there (`:227`, `:258`), because zdtd has no buried-container search. The fallback quest-giver marker height of 70 is a plausible ground height, explicitly not stock data (`src/server/c2s/quest.zig:25`).

## What crosses the wire

The journal is written as stock `Quest.Write` records, versioned 8, inside `QuestJournal.Write` version 5 (`src/wire/stock_quest.zig:10`, `:12`). States are the stock enum (src/wire/stock_quest.zig:39):

```zig
pub const QuestState = enum(u8) {
    not_started = 0,
    in_progress = 1,
    ready_turn_in = 2,
    completed = 3,
    failed = 4,
};
```

The snapshot struct the sim fills per active slot (src/wire/stock_quest.zig:82):

```zig
pub const StockQuestWrite = struct {
    id: []const u8,
    quest_version: u8 = 1,
    state: QuestState = .in_progress,
    shared_owner_id: i32 = -1,
    quest_giver_id: i32 = -1,
    tracked: bool = true,
    current_phase: u8 = 1,
    quest_code: i32 = 0,
    objective_count: u8 = 0,
    /// CurrentValue for objective index 0 (legacy).
    first_objective_value: u8 = 0,
```

Per-objective values follow the flat objective order and, for XML defs, the per-objective progress in the slot (`src/server/game/quest.zig:126`). Objectives sit behind a `u16` size marker that the client validates; a kind mismatch desyncs the whole list and the client clears every objective (`src/wire/stock_quest.zig:178`). Only stock client quest names are emitted (`src/server/game/quest.zig:80`, gate at `src/server/game.zig:3127`). The single emit site for a full journal is the `PlayerId` body, written on join and on respawn (`src/wire/packages.zig:654`); no `writeQuestJournal` call exists outside that builder and the wire tests. A quest accepted mid-session reaches the client through the rebuilt `NetPackageNPCQuestList` that no longer offers it (`src/server/c2s/quest.zig:515`), not through a journal update. Map markers for active quests are pushed separately as nav objects on the enter and spawn bundles (`src/server/game/join.zig:414`, called at `src/server/game.zig:2938` and `:3021`).

The `NetPackageQuestObjectiveUpdate` shape is i32 sender, i32 quest code, u8 event, then an optional Vector3i block position; the parser accepts a 9-byte body without the position so the zdtd-native fixtures stay parseable, and rejects an event byte outside the three stock values (src/wire/packages.zig:5627, `:5652`). `NetPackageQuestEvent` carries an entity id, a position, an event byte, an empty tag string and a quest code, with per-event tails for the variants the server acts on; the builder refuses the list-tail variants the server never originates rather than emitting a partial body (src/wire/stock_quest.zig:418, `:519`, `:534`). `NetPackageSharedQuest` is one `SharedQuestData` blob, parsed for the fields the server acts on and forwarded unchanged to the named entity (`src/wire/stock_quest.zig:385`, `src/server/c2s/quest.zig:95`). The wire tests here are round trips of zdtd's own encoder against zdtd's own parser plus size assertions (`src/wire/stock_quest.zig:260`, `:712`, `:767`); they prove self-consistency and pin the layout, not stock acceptance.

## Tick path, persistence and known gaps

Per accepted movement the two proximity checks run for that peer (`src/server/c2s/move.zig:43`, `:54`). Kill credit runs at the death path, not from a client report (`src/server/game/step.zig:296`), and party mates get the same credit when they hold the same quest (`src/server/game/player.zig:292`). Loot credits fetch phases (`src/server/c2s/inv.zig:559`), crafting credits craft phases (`src/server/game/craft.zig:481`), and opening a trader window advances interact phases and completes a ready quest (`src/server/c2s/misc.zig:1128`, `src/server/c2s/quest.zig:589`). On spawn the join path grants the starter quest when a slot is free and writes the journal snapshot for the PDF (`src/server/game.zig:2799`, `:2814`).

The journal persists inside each player record as `def_id`, `quest_code`, flag bits, `progress`, `phase`, then the quest name and the POI rect from v5 on (`src/server/persist.zig:550`). Restore rebuilds the flags and counters (`src/server/persist.zig:1184`) and resolves the quest by name first, so a `quests.xml` edit does not rebind a saved quest to a different def (`src/server/persist.zig:1215`); a name longer than the format allows drops the entry rather than truncating it (`:1206`).

Honest gaps. Mid-session server-to-client journal synchronization is not implemented; `docs/GAP_ANALYSIS.md` §4 records it as RE-blocked, and no builder for such a package exists in `wire/`. Bedroll and land-claim POI lockouts fire only when the `home_fn` hook is wired, so headless worlds never report those refusal reasons (`src/ecs/systems.zig:1242`). A rally phase without a bound POI rect is scaffolding and auto-skips rather than waiting for a marker (`src/ecs/systems.zig:788`). The treasure dig site is derived from the POI center and terrain height, not from a buried-container search (`src/server/c2s/quest.zig:258`). ClearSleepers uses the live sleeper count only through the `quest_sleeper_count_fn` hook, otherwise the definition's required count (`src/ecs/systems.zig:894`). Objective types absent from the catalog's mapping table degrade to `.auto` and auto-complete, which advances the phase without simulating the objective (`src/ecs/quest.zig:219`). The quest-giver marker fallback height is a zdtd value, not stock data (`src/server/c2s/quest.zig:25`).

## See also

- [`c2s.md`](c2s.md): the dispatch order, phase gate and reject counters this handler plugs into.
- [`assets.md`](assets.md): how `quests.xml` reaches the catalog and what the loader does with modlet patches.
- [`ecs.md`](ecs.md): the SoA world and component-mask conventions the journal lives in.
- [`persistence.md`](persistence.md): the player record format that carries the journal across restarts.
- [`../STATE_MACHINES.md`](../STATE_MACHINES.md): the quest lifecycle diagram and the POI lockout sub-machine.
