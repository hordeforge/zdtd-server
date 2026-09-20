# Client-to-server handlers

This subsystem owns the C2S dispatch table: routing a decoded package to a domain handler, validation at the trust boundary, and rate limits. A decoded `NetPackageFoo` enters through the phase gate, is matched by name against six domain handlers in a fixed order, and either mutates server state and broadcasts the resulting state or is dropped and counted. The boundary ends where a handler calls into `ecs`, `world`, or `wire`; package body layout is owned by `wire/stock_*.zig` and the package id map by `wire/packages.zig`, not here. `src/server/c2s/*` is part of the `server` package, whose root comment states it is "top of the stack. May import all other src packages" (src/server/root.zig:3), and every file under `src/server/c2s/` must be re-exported from `src/server/root.zig` or `zig build test` silently drops it (AGENTS.md layout note).

Sources: [`src/server/c2s/dispatch.zig`](../../src/server/c2s/dispatch.zig), [`src/server/c2s/join.zig`](../../src/server/c2s/join.zig), [`src/server/c2s/move.zig`](../../src/server/c2s/move.zig), [`src/server/c2s/blocks.zig`](../../src/server/c2s/blocks.zig), [`src/server/c2s/inv.zig`](../../src/server/c2s/inv.zig), [`src/server/c2s/quest.zig`](../../src/server/c2s/quest.zig), [`src/server/c2s/misc.zig`](../../src/server/c2s/misc.zig), [`src/server/game/net_handlers.zig`](../../src/server/game/net_handlers.zig), [`src/server/game/rate_limits.zig`](../../src/server/game/rate_limits.zig), [`src/server/phase_gate.zig`](../../src/server/phase_gate.zig), [`src/server/c2s_text.zig`](../../src/server/c2s_text.zig), [`src/server/game/guard.zig`](../../src/server/game/guard.zig), [`src/server/game/social.zig`](../../src/server/game/social.zig).

## Entry path

UDP payloads reach the handlers only through the tick thread's net poll: `pollNetOnce` delivers `Game.onData`, and a faulty payload increments `net_payload_errors` instead of propagating (src/server/game/net.zig:400, 426). `onData` first requires the challenge echo, then extracts every framed package from one payload and calls `handlePackage` per package in order (src/server/game/net_handlers.zig:107):

```zig
    var pkgs: [16]wire_frame.Package = undefined;
    const n = wire_frame.parseChannelPayload(stable, &pkgs);
```

A payload that fails to parse at all is counted `c2s_malformed` and dropped; an earlier retry that prepended a channel byte was removed because it widened the trust boundary on unauthenticated input (src/server/game/net_handlers.zig:131). Payloads that arrive before the challenge echo are buffered into `Client.preauth_buf` and replayed after authentication (src/server/game/net_handlers.zig:71, 85). Tests and loadgen enter the same path through `harness.attachJoinedClientAs` / `harness.injectFramed`, which call `onData` directly rather than opening a socket (src/server/game/harness.zig:36, 89).

`Game.handlePackage` is a one-line forwarder to this subsystem's dispatch entry (src/server/game.zig:2344).

## The handler contract

Dispatch is entered with the decoded package id and body, not a name. An id outside the negotiated map is counted on `c2s_malformed`, rate-limited-logged, and dropped, since there is no name to route (src/server/c2s/dispatch.zig:19):

```zig
pub fn handlePackage(self: *Game, c: *Client, peer: *ln_peer.Peer, id: u16, body: []const u8) !void {
    if (id >= packages.default_mappings.len) {
        // Metric so an unmapped-id flood moves c2s_malformed (and the webui
        // error panel) instead of only a rate-limited stderr line.
        self.harness.counters.inc(.c2s_malformed);
        const n = self.harness.counters.get(.c2s_malformed);
        if (n == 1 or n % 100 == 0) {
            var ts: [19]u8 = undefined;
            std.debug.print(
                "zdtd: {s} unmapped package local_id={d} package_id={d} body_len={d} n={d}\n",
                .{ clock.wallStamp(&ts), peer.local_id, id, body.len, n },
            );
        }
        return;
    }
    const name = packages.default_mappings[id];
```

The phase gate then runs before any handler, and the six domains are tried in a fixed order. Each domain owns a name set, and a name matched by an earlier domain never reaches a later one:

```zig
    if (try c2s_join.handle(self, c, peer, name, body)) return;
    if (try c2s_move.handle(self, c, peer, name, body)) return;
    if (try c2s_inv.handle(self, c, peer, name, body)) return;
    if (try c2s_blocks.handle(self, c, peer, name, body)) return;
    if (try c2s_quest.handle(self, c, peer, name, body)) return;
    if (try c2s_misc.handle(self, c, peer, name, body)) return;
    self.harness.counters.inc(.c2s_unhandled);
```

(src/server/c2s/dispatch.zig:48). Every domain handler has the same signature and the same contract: return `true` when the name belongs to the domain, `false` to fall through (src/server/c2s/move.zig:23):

```zig
/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
```

A `true` return does not imply the package was applied. It means the domain claimed the name; the arm may have applied it, rejected it, relayed it, or deliberately dropped it as a documented no-op. The drop-on-illegal rule has three forms. An unmapped id drops at dispatch (dispatch.zig:20). A phase-illegal package drops after the gate. A handler-owned rejection drops that package or that entry while the rest of the payload continues: a `SetBlock` entry outside edit range is skipped with a `continue` and the sibling entries in the same batch still apply (src/server/c2s/blocks.zig:134). Nothing in the dispatch or phase drop itself disconnects the peer; the drops are counted, and the strongest counters also feed the guard policy through `Game.noteEvidence`, whose rungs can arm a separate delayed kick (src/server/game/guard.zig:69, 153).

## Phase gate

The phase is derived from two `Client` flags, and each phase has a static allowlist (src/server/phase_gate.zig:7). Before login only the login and disconnect packages are legal:

```zig
pub const Phase = enum(u8) {
    /// Challenge/auth done, PlayerLogin not accepted yet.
    connecting,
    /// Login accepted, join bundle not yet sent (enter/spawn SM).
    joined,
    /// Join bundle sent; world play C2S legal.
    playing,
};
```

The `joined` list is the join state machine's own package set plus the login re-entry, the world folder transfer, POI metadata, and disconnect (src/server/phase_gate.zig:32). Selection is a three-way switch in which `playing` admits every name and the earlier phases admit only their tables:

```zig
pub fn allowed(phase: Phase, name: []const u8) bool {
    return switch (phase) {
        .connecting => nameIn(connecting_allow, name),
        .joined => nameIn(joined_allow, name),
        .playing => true,
    };
}
```

(src/server/phase_gate.zig:58). A rejection increments `phase_rejects`, records an `.phase`/`.hard` evidence event, and logs on the first and every hundredth occurrence (src/server/c2s/dispatch.zig:28). This is deliberately a name allowlist, not a per-field check: a package that is legal in `playing` still gets every ownership and bounds test inside its handler.

## Domain map

| Domain | Handler | Packages handled |
|---|---|---|
| join | `c2s/join.zig:34` | PlayerLogin, PlayerSpawnedInWorld, RequestToEnterGame, AuthConfirmation, SignDataRequest, WorldInitInfoRequest, DynamicClientArrive, RequestToSpawnPlayer, WorldFolder, POIMetadataRequest |
| move | `c2s/move.zig:24` | EntityPosAndRot, EntityRelPosAndRot, EntityTeleport, EntityAddVelocity, EntityAliveFlags, EntitySpeeds, EntityCollect |
| inv | `c2s/inv.zig:79` | PlayerInventory, HoldingItem, ItemDrop, ItemReload, Bag, TileEntity, InventoryTransactionRequest, InventoryDataRequest, DropItemsContainer |
| blocks | `c2s/blocks.zig:30` | SetBlock, SetBlockTexture, BlockTrigger, WaterSet, PickupBlock, ExplosionInitiate, ItemActionEffects, CloseAllWindows |
| quest | `c2s/quest.zig:28` | SharedQuest, PartyQuestChange, PartyActions, PartyData, QuestEvent, QuestObjectiveUpdate, QuestGotoPoint, QuestTreasurePoint, NPCQuestList, TraderData, PlayerVendingMachine, LandClaimRepair, AllyRequest, AllyResponse, Waypoint, EntityAwardKillServer, SharedPartyKill, AddRemoveBuff |
| misc | `c2s/misc.zig:48` | Chat, SimpleChat, GameMessage, SoundAtPosition, ParticleEffect, Audio, PlayerLaserSight, EntityRagdoll, EntityAnimationData, EntityAttach, EntityPhysics, EntityStealth, EntityStatChanged, EntityStatsBuff, DamageEntity, GameEventRequest, GameEventResponse, QuestEntitySpawn, RequestToSpawnEntity, ConsoleCmdServer, LockRequest, InventoryKeepOpen, MapPosition, PlayerData, PlayerDisconnect, PlayerEquipment, PlayerQuestPositions, PlayerStats, DiscordIdMappings, PlayerInventoryForAI, BossEvent, LobbyRegisterClient, EntityAddScoreServer, EntityAddExpServer, EntitySetSkillLevelServer, EditorAddVolumeFromClient, VehicleDataSync, VehicleSpawn, WireActions, WireToolActions, TurretSpawn |

Some `quest` and `misc` arms are pure delegation into `src/server/game/social.zig`: `PartyActions` to `handlePartyActions` (src/server/game/social.zig:165), `AllyRequest` to `handleAllyRequest` (src/server/game/social.zig:402), `AddRemoveBuff` to `handleAddRemoveBuff` (src/server/game/social.zig:13). Several `misc` names are accepted and dropped on purpose, each recorded as a divergence: `PlayerStats`, `DiscordIdMappings` (src/server/c2s/misc.zig:380), `BossEvent`, `EntityStatsBuff`, `PlayerInventoryForAI`, `LobbyRegisterClient` (src/server/c2s/misc.zig:495), the score and XP server adds (src/server/c2s/misc.zig:538), `PlayerQuestPositions` (src/server/c2s/misc.zig:498), and `RequestToSpawnEntity` (src/server/c2s/misc.zig:695). The reasons are authority, not omission: the client-reported blob would either duplicate a server ledger or let a client author state the sim owns.

## Validation at the trust boundary

Three generic helpers carry most of the policy. `rejectIfNotSender` drops a claimed entity id that is not the sender's and records an `.ownership`/`.strong` event (src/server/game/guard.zig:46). `rejectIfBeyondEditRange` compares the acting position against the target and drops past `max_edit_range`, default 96 blocks (src/server/game/guard.zig:13; src/server/game/types.zig:98). `quarantineDenies` refuses one surface, `damage`, `container`, or `block`, for a peer its guard policy quarantined (src/server/game/guard.zig:112).

Domain-specific ownership checks supplement those: `NetPackageEntityPosAndRot` rejects an entity id that is not the sender's (src/server/c2s/move.zig:30), `NetPackageEntityCollect` requires the claimed collector to be the sender (src/server/c2s/move.zig:65), `NetPackageItemReload` requires a live player entity that is the sender (src/server/c2s/inv.zig:96), and `NetPackageBag` refuses to write another player's inventory, then range-gates writes to any other inventory by id (src/server/c2s/inv.zig:338). Login performs the identity work: the name is sanitized, the platform identities are stored, the client's compatibility version is compared against `version.stock_wire_comp`, the slot cap and reserved/admin tiers are evaluated, plugin and Wasm login verdicts run, and the identity ban list and whitelist are checked (src/server/c2s/join.zig:80, 90, 121, 166, 190, 207).

Bounds and caps are named module constants, never inline numbers: the claimed explosion radius is capped at the largest stock `ExplosionData` radius (src/server/c2s/blocks.zig:24), the spawn `chunkViewDim` at the view-distance-8 mesh core (src/server/c2s/join.zig:31), the claimed damage at `max_claimed_damage` (src/server/game/types.zig:93), and a claimed `fatal` is honored only against NPC kinds by substituting a fixed kill amount (src/server/c2s/misc.zig:36). Client-supplied inventory is clamped to the catalog stack size after every apply, and attached mods are scrubbed when they exceed the item's mod-slot curve or fail the mod's installability gate (src/server/c2s/inv.zig:45, 137). Text is a separate trust boundary: `sanitizePlayerName` strips C0, DEL, invalid UTF-8, and bidi overrides without splitting a codepoint (src/server/c2s_text.zig:20), `chatMsgOk` bounds a chat body to 256 bytes of valid UTF-8 with no controls (src/server/c2s_text.zig:75), and the player F1 console accepts only the verbs in `player_console_allowlist` (src/server/c2s_text.zig:89).

Malformed input fails closed per package: the counter increments and the handler returns without applying anything, for example a `NetPackageTileEntity` payload that matches no known TE format is dropped (src/server/c2s/inv.zig:768) and a non-empty inventory stack that does not resolve to a catalog item fails the whole transaction rather than clearing the slot (src/server/c2s/inv.zig:821).

## Rate limits

Four gates exist, all keyed on per-client state in the `Client` struct rather than on a shared table (src/server/game/types.zig:710):

```zig
    /// Cost-class token buckets (refill on accept path).
    inv_tokens: u8 = 0,
    inv_refill_ns: u64 = 0,
    block_tokens: u8 = 0,
    block_refill_ns: u64 = 0,
    /// Combat ledger: last DamageEntity mono ns + short burst count.
    last_damage_ns: u64 = 0,
    damage_burst: u8 = 0,
```

The inventory bucket gates every package that mutates inventory or fans a relay out to peers: `PlayerInventory`, `HoldingItem`, `ItemDrop`, `Bag`, `TileEntity`, `InventoryTransactionRequest`, `InventoryDataRequest`, `ItemReload` (src/server/c2s/inv.zig:86, 105, 244, 272, 328, 407, 772, 1004), plus `PlayerEquipment` and `GameMessage` (src/server/c2s/misc.zig:118, 518). The block bucket gates world mutation and cosmetic relays: `SetBlock`, `SetBlockTexture`, `BlockTrigger`, `WaterSet`, `PickupBlock`, `WireActions`, `WireToolActions`, `EntityAnimationData`, `TurretSpawn` (src/server/c2s/blocks.zig:42, 56, 114, 431, 525; src/server/c2s/misc.zig:1249, 1260, 1291, 1335), plus `ExplosionInitiate` (src/server/c2s/blocks.zig:601), `ItemActionEffects` (src/server/c2s/blocks.zig:767), and the quest-domain relays `SharedQuest`, `Waypoint`, `AddRemoveBuff`, `LandClaimRepair` (src/server/c2s/quest.zig:34, 70, 302, 370). The chat gap gates `Chat` and `SimpleChat` (src/server/c2s/misc.zig:50). The damage burst gates `DamageEntity` (src/server/c2s/misc.zig:716).

The bucket itself is a byte counter with a wrapping monotonic deadline, so an idle client cannot bank a burst larger than the cap and a clock wrap cannot refill it (src/server/game/rate_limits.zig:11):

```zig
fn takeTokenAt(now: u64, tokens: *u8, refill_ns: *u64, cap: u8, refill_period_ns: u64) bool {
    if (refill_ns.* == 0) {
        refill_ns.* = now;
        tokens.* = cap;
    }
    while (tokens.* < cap and now -% refill_ns.* >= refill_period_ns) {
        tokens.* += 1;
        refill_ns.* +%= refill_period_ns;
    }
    if (tokens.* == 0) return false;
    tokens.* -= 1;
    return true;
}
```

Caps and periods are configuration fields on `Game`, bound from `zdtd.toml [sim]`, with these defaults (src/server/game/types.zig:115):

```zig
pub const default_min_chat_gap_ns: u64 = 200_000_000;
pub const default_inv_bucket_cap: u8 = 40;
pub const default_inv_refill_ns: u64 = 50_000_000; // +1 token / 50 ms
pub const default_block_bucket_cap: u8 = 30;
pub const default_block_refill_ns: u64 = 33_000_000; // +1 / ~33 ms
pub const default_min_damage_gap_ns: u64 = 80_000_000;
pub const default_damage_burst_max: u8 = 4;
```

A throttled package is not a hard failure: the handler returns `true` so the name stays claimed, and increments `c2s_throttle` (src/server/c2s/inv.zig:86). The damage gate has a different shape: inside the minimum gap only `damage_burst_max` claims pass, and the gate is counted as throttle rather than ownership (src/server/game/rate_limits.zig:37). The bucket arithmetic is covered by unit tests for drain, refill ceiling, and the clock wrap (src/server/game/rate_limits.zig:58, 73, 96).

## State effects, replication, and persistence

A handler that accepts a change writes it into the sim or world store first, then broadcasts the resulting state: blocks and TE writes go through `world.setBlockRawWorld` / `world.setBlockWorld` and `broadcastNear` (src/server/c2s/blocks.zig:377; src/server/c2s/inv.zig:949, 959), while relay packages are re-encoded from parsed fields or trimmed to the parsed wire length so a peer cannot append bytes that fan out (src/server/c2s/move.zig:201, 230, 274). `AliveFlags` and `Speeds` are explicitly re-encoded rather than relayed for that reason (src/server/c2s/move.zig:196, 227). Relays that stock sends to everyone but the sender use `broadcastExcept`, and the raw-body helpers in misc enforce the same exclusion (src/server/c2s/misc.zig:1415).

Per-tick work is minimal by construction: the handlers run inside net poll on the tick thread, the maintenance plane's budget for this path is `net_poll <= 5 ms` (docs/ARCHITECTURE.md:87), and the path must not allocate (docs/ARCHITECTURE.md:255). The join handler is wrapped in one apm section so synchronous join work is measurable separately from the paced chunk drain (src/server/c2s/join.zig:39).

Persistence is deferred rather than synchronous except on quit. `NetPackagePlayerData` applies the client's inventory head but only sets `players_dirty`, so the file write happens on the periodic save (src/server/c2s/misc.zig:353; src/server/game/step.zig:541). `NetPackagePlayerDisconnect` saves players and drops the slot immediately so a quit is never lost to the autosave interval (src/server/c2s/misc.zig:366). Container, sign, workstation, and vending writes land in the world-level stores that own their own save files: a sign body is stored for later chunk-stream replay (src/server/c2s/inv.zig:512), a storage TE creates or updates a container record (src/server/c2s/inv.zig:540), and a workstation TE applies into the workstation store the craft tick advances (src/server/c2s/inv.zig:597).

Stock fidelity note: the dispatch table, the bodies it parses, and the bodies it emits are zdtd code checked against the research dumps and the loadgen goldens, not against a live stock server in this reading. A green zdtd-to-zdtd round trip proves self-consistency only. Known divergences from stock behaviour on this path (trigger broadcasts without a trigger-volume sim, accepted-and-dropped client state blobs, redirect of kill and XP credit to the server paths) are listed in `docs/DIVERGENCES.md` and inline at the arms that carry them (src/server/c2s/blocks.zig:31; src/server/c2s/misc.zig:370).

## See also

- [join.md](join.md) - the seven-package join state machine this table routes into
- [movement.md](movement.md) - position, teleport, and the movement envelope
- [inventory.md](inventory.md) - inventory, bag, and tile-entity write paths
- [quests.md](quests.md) - shared quests, objectives, and trader exchange
- [tick.md](tick.md) - where net poll, sim, and replicate sit in the 50 ms budget
- [../AUTHORITY.md](../AUTHORITY.md) - who owns sim state and which gates enforce it
- [../ARCHITECTURE.md](../ARCHITECTURE.md) - layering, join flow, and the no-heap invariant
