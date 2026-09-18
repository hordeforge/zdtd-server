# POI locks and claims

This subsystem owns two server-authoritative protections over world space: the quest POI lockout, which reserves a point of interest for its questers, and the land claim, which reserves a square around a placed keystone for its owner. The lockout table is `ecs/poi_lock.zig`, the server half of `QuestEventManager`'s `PrefabInstance.lockInstance` (`src/ecs/poi_lock.zig:1`). The claim is a server store: the record is `Game.LandClaim`, the helpers live in `server/game/world.zig`, and the quest-facing bridge is the `home_lockout` hook. `ecs` may import `util` only (`src/ecs/root.zig:3`), so the lockout asks the server through that hook instead of touching the claim store; `server` may import every package (`src/server/root.zig:3`). Neither blocks movement: the quest lock stops a second player arming the same rally marker, and the claim refuses foreign block edits and overlapping keystones.

Sources: [`src/ecs/poi_lock.zig`](../../src/ecs/poi_lock.zig), [`src/ecs/components.zig`](../../src/ecs/components.zig), [`src/ecs/systems.zig`](../../src/ecs/systems.zig), [`src/ecs/rules.zig`](../../src/ecs/rules.zig), [`src/server/game.zig`](../../src/server/game.zig), [`src/server/game/quest.zig`](../../src/server/game/quest.zig), [`src/server/game/world.zig`](../../src/server/game/world.zig), [`src/server/game/hooks.zig`](../../src/server/game/hooks.zig), [`src/server/game/locks.zig`](../../src/server/game/locks.zig), [`src/server/game/types.zig`](../../src/server/game/types.zig), [`src/server/c2s/quest.zig`](../../src/server/c2s/quest.zig), [`src/server/c2s/misc.zig`](../../src/server/c2s/misc.zig), [`src/server/persist.zig`](../../src/server/persist.zig), [`src/wire/packages.zig`](../../src/wire/packages.zig), [`src/wire/stock_quest.zig`](../../src/wire/stock_quest.zig).

## Ownership and boundary

The lockout lives in the sim because every quest path already runs there: accepting a quest stores a POI rectangle on the quest slot, an `UnlockPOI` quest action releases the holder, and a quest that ends releases it again (`src/ecs/systems.zig:1041`, `:835`, `:983`). The table is a fixed ECS array of 64 entries, each holding a rectangle, up to eight quester entity ids, the locked flag, the lockout deadline and the grace applied when the last quester leaves (`src/ecs/poi_lock.zig:23`, `:28`):

```zig
pub const Lock = struct {
    rect: c.PoiRect = .{},
    questers: [max_questers]i32 = [_]i32{0} ** max_questers,
    quester_n: u8 = 0,
    /// QuestLockInstance.IsLocked.
    locked: bool = false,
    /// QuestLockInstance.LockedOutUntil (0 while questers are inside).
    locked_out_until: u64 = 0,
    /// Grace applied on last-quester-out (copied from Table.grace_ticks at
    /// lock creation; `rules.world.poi_unlock_grace_ticks`).
    grace_ticks: u64 = 2000,
```

Both caps are zdtd bounds rather than stock rules, and the comment gives the reason: the table is grown from client packets, so a peer must not drive an unbounded allocation, while a shared quest party is small (`src/ecs/poi_lock.zig:21`, `:26`). The claim store mirrors that decision: at most 1024 rows, because a keystone is player-placed and the placement path must not grow the heap (`src/server/game/types.zig:26`, `src/server/game/world.zig:71`). The reason set is the stock enumeration (`src/ecs/poi_lock.zig:10`):

```zig
pub const LockReason = enum(u8) {
    none = 0,
    player_inside = 1,
    bedroll = 2,
    land_claim = 3,
    quest_lock = 4,
};
```

A lock is keyed by a rectangle that is prefab metadata, not a quest field: `PoiRect` mirrors the stock `PrefabInstance` bounding box, rides the quest PositionData POIPosition and POISize pair, and a zero XZ size means no POI resolved (`src/ecs/components.zig:622`). The server supplies rectangles through hooks: `poiRectAtWorld` floors the position, walks the prefab list, skips prefab parts, and returns the first bounding box containing the point (`src/server/game/hooks.zig:74`). The `Game` wires that hook, a nearest-POI variant and a quest-POI selector into the world at startup (`src/server/game.zig:1058`), and `World.poiAt` returns null when the hook is unset, so a POI-less test world has no lockout (`src/ecs/world.zig:1040`).

## Lock state and its transitions

Locking a live rectangle only adds a quester, so a shared party thickens one entry, and locking an expired one replaces it (`src/ecs/poi_lock.zig:95`). A zero-size rectangle is refused outright and never consumes a slot (`src/ecs/poi_lock.zig:96`). A full table for a different rectangle reclaims the first expired entry, because nothing else ever sweeps the table, and refuses the lock when nothing is reclaimable (`src/ecs/poi_lock.zig:104`):

```zig
        if (self.n >= max_locks) {
            // Table full for a *different* rect: reclaim the first expired
            // entry rather than refusing new locks forever once every slot
            // has been touched once (nothing else ever sweeps this table).
            // ...
            if (!reclaimed) return false;
        }
```

Removing a quester swaps the tail into the hole; when the last quester leaves a still-locked entry, the lock flips to unlocked and the deadline is stamped at the world time plus the grace, with a saturating add so the world time cannot wrap it into the past (`src/ecs/poi_lock.zig:54`). An entry is removable only when unlocked and the world time is strictly past the deadline, which is stock's `CheckQuestLock` (`src/ecs/poi_lock.zig:70`). The read path drops an expired entry and otherwise reports the deadline (`src/ecs/poi_lock.zig:140`). Lookup is a linear scan over the live prefix on a point-in-rectangle test (`src/ecs/poi_lock.zig:81`), using the stock `Rect.Contains` convention, minimum edge inclusive and maximum edge exclusive (`src/ecs/components.zig:635`, `src/ecs/poi_lock.zig:171`). Exits are per-entity: a quest that ends or a player entity that dies drops that entity's quester row from every lock (`src/ecs/systems.zig:983`, `src/ecs/world.zig:840`).

## The rally-marker lockout

The lockout is observed at one point, a client asking to arm a quest's rally marker, and it returns a reason plus the deadline for the client to display (`src/ecs/systems.zig:1219`). The order of the checks is the ownership rule: a quest lock refuses first with its deadline, then another player standing inside the rectangle refuses with `player_inside`, then the bed and claim reasons are asked of the server (`src/ecs/systems.zig:1231`). Party members are exempt from the player-inside reason, matching stock's `CheckForPOILockouts`, through the shared party-identity hook (`src/ecs/systems.zig:1241`). The requester is skipped by entity id, so a player inside their own marker's POI does not block themselves (`src/ecs/systems.zig:1239`). Bed and claim reasons need tracking the sim does not hold, so with `home_fn` unset they never fire rather than being guessed (`src/ecs/systems.zig:1247`).

The handler maps the reason to the reply event, refusing only the requester and broadcasting an activation because the shared marker is party state (`src/server/game/quest.zig:26`). The codes are the stock enum values, and only the quest-lock code carries the deadline as a `u64` tail (`src/wire/stock_quest.zig:421`, `:529`):

```zig
    rally_marker_activated = 2,
    rally_marker_locked = 3,
    rally_marker_player_locked = 4,
    rally_marker_bedroll_locked = 5,
    rally_marker_land_claim_locked = 6,
```

The handler is a trust boundary: the packet's entity id must be the sender's own entity, so a peer cannot raise a quest event for someone else (`src/server/game/quest.zig:19`). An unknown or already spent quest code produces no reply, so a marker never reports activated for a quest the server cannot track (`src/server/game/quest.zig:36`). A successful activation marks the quest, takes the lock and restores the POI's baked blocks, the dedication step stock performs on quest dedication (`src/server/game/quest.zig:37`). The one rule read here is the unlock grace, a `u32` in the world rules group with the stock 2000-tick default, copied onto the lock table at init (`src/ecs/rules.zig:535`, `src/server/game.zig:967`).

## Land claims and the sleeping bag

A claim row is one keystone position, its live owner entity, the offline accounting fields and a stable owner key for persistence (`src/server/game/types.zig:188`):

```zig
pub const LandClaim = struct {
    x: i32,
    y: i32,
    z: i32,
    owner_entity: i32,
    owner_online: bool = true,
    /// In-game day the owner was last seen online (expiry base when offline).
    owner_seen_day: u32 = 0,
    /// Stable owner key for persistence: the login name (entity ids are
    /// reassigned across restarts). Empty when the claim predates the field.
    owner_name: [32]u8 = .{0} ** 32,
    owner_name_len: u8 = 0,
```

The owner key is the login name because entity ids are reassigned every session and cannot be saved; `registerClaim` captures it at placement time and updates the existing row when the same keystone is re-placed (`src/server/game/world.zig:49`, `:61`). Registration is gated before the block becomes a claim: `claimAllowed` counts the owner's existing claims against the configured count and refuses a position inside any existing dead-zone radius, and the placement path registers only when both pass while still allowing the block itself to be placed, since the client's own count check usually stops it first (`src/server/game/world.zig:33`, `src/server/c2s/blocks.zig:362`). The distance test uses 64-bit integers, so an extreme coordinate cannot overflow it, and the keystone's Y does not participate because the dead zone is a two-dimensional radius (`src/server/game/world.zig:34`, `:40`).

A claim expires only while its owner is offline, and the clock is the in-game day the owner was last seen online, so the check compares `owner_seen_day` rather than a wall-clock timeout (`src/server/game/world.zig:207`). Login marks the owner's claims online and restamps that day, disconnect marks them offline, and the daily rollover runs the expiry pass (`src/server/game.zig:2798`, `src/server/game/session_drop.zig:35`, `src/server/game/step.zig:225`). Dropping a row also removes its map marker from clients already online, which would otherwise keep the protection square on screen until the next join (`src/server/game/world.zig:93`). The online and offline modifiers scale the keystone's effective durability (`src/server/c2s/blocks.zig:224`). The claim area is repairable: the pass walks the protection square and heals every damaged non-air block through the normal SetBlock broadcast, at no material cost because zdtd has no tile-entity storage inventory (`src/server/game/world.zig:133`).

The sleeping bag is not a claim row. A placed bedroll is latched onto the client record as its respawn point, and the respawn path prefers it over the world spawn when present (`src/server/c2s/inv.zig:953`, `src/server/c2s/join.zig:478`). Both reach the sim through one hook returning two bits, bit 1 for a bedroll and bit 2 for a claim (`src/server/game/hooks.zig:664`). The bed leg measures the bed against the quest policy's bed lockout radius from the POI center, and the claim leg measures that center against half the configured claim size, so a zero radius disables the bed reason without touching the claim leg (`src/server/game/hooks.zig:677`, `:682`). With the hook unwired both reasons stay silent.

## Claim permissions and the option surface

A claim is a permission boundary as well as a marker. The world resolves the claim covering an XZ position with a halved-size absolute test, so the protected area is a square centred on the keystone (`src/server/game.zig:1989`). A block edit or place inside someone else's claim is dropped, on the terrain path, the main SetBlock path and the item placement path (`src/server/c2s/blocks.zig:90`, `:152`, `src/server/c2s/inv.zig:941`). The keystone is identified by name, not a pinned id: `landClaimBlockId` resolves the AssignIds entry `keystoneBlock`, and an unknown name fails closed to no claim behaviour (`src/server/game.zig:1984`).

Only the claim owner may repair it. The repair request carries a begin flag and a position; the position must resolve to a claim whose owner entity is the requester, and a request outside any claim or for someone else's is dropped and counted as an ownership rejection (`src/server/c2s/quest.zig:38`, `:47`). The reply is a `NetPackageLandClaimRepair` body with the begin flag cleared, which clears the client's repairing state (`src/server/c2s/quest.zig:58`).

The claim sizes and lifetimes are server options, not rule fields: the protected size, the two durability modifiers, the offline expiry in days, the per-owner count and the dead zone carry stock defaults 41, 4, 4, 3, 3 and 60 (`src/server/game/types.zig:330`). The same values ride the game-stats options body the client receives (`src/wire/packages.zig:3809`). Two have no behaviour behind them: the decay mode and the offline delay are configured, validated and advertised, but nothing consumes them, and the placement comment records the decay amounts as RE-blocked (`src/server/game/world.zig:31`). Container padlocks and lock picking are in the same position: `src/world/containers.zig` models no locked, password or allowed-user field, so the `TEFeatureLockable` and `TEFeatureLockPickable` modules recorded in [`../GAP_ANALYSIS.md`](../GAP_ANALYSIS.md) at line 3440 have no code path here.

## C2S paths and client release

Two lock vocabularies arrive from clients and are not the same table. The quest lockout is decided inside the quest event handler, which answers the rally-marker request with a reason rather than applying a lockout as a block, and it also serves the explicit `lock_poi` and `unlock_poi` events that take and release the POI for the sending entity (`src/server/game/quest.zig:22`, `:51`). The container channel lock is `NetPackageLockRequest`, handled with the interaction packages and validated before any channel is written (`src/server/c2s/misc.zig:1038`):

```zig
    if (std.mem.eql(u8, name, "NetPackageLockRequest")) {
        if (packages.parseLockRequest(body)) |req| {
            // Deny acquiring a container lock while quarantined; always let
            // an unlock through so a quarantined peer cannot pin a channel.
            if (req.locking and self.quarantineDenies(c, .container)) return true;
```

A channel lock is a lease, so the path refuses by default. The server clamps the requested channel into its table and reaps a stale holder whose keep-open stamp aged out (`src/server/c2s/misc.zig:1043`, `:1045`). It refuses a peer that already holds any channel, force-unlocking what that peer holds and granting nothing, which is stock's gate 1 (`src/server/c2s/misc.zig:1059`). A null or over-long target list is denied explicitly so the client's pending request resolves instead of hanging, a dead or closed trader is refused before any channel is written, and a target locked elsewhere or a channel held by another peer is refused as `locked` (`src/server/c2s/misc.zig:1068`, `:1109`, `:1119`). An unlock is accepted only from the holder or when the channel is free, and it runs the tile-entity close consequences (`src/server/c2s/misc.zig:1200`). A keep-open refresh carries no state and only restamps the timer (`src/server/game/locks.zig:100`).

Release exists so a departing player cannot pin a channel. Clearing server state alone would leave other clients showing the container as locked, so the disconnect path force-unlocks every channel the peer held and tells the remaining clients (`src/server/game/locks.zig:124`, `src/server/game/session_drop.zig:34`). That body uses `locking = false`, routing the client to its unlock-response branch (`src/wire/packages.zig:3448`).

A denial is always a reply. The plain denial is a `NetPackageLockResponse` with `locking` echoed, `success` false and a reason string, and the handler supplies `locked`, `closed`, `null target` and `too many targets` for the four refusal classes (`src/wire/packages.zig:3420`, `src/server/c2s/misc.zig:1069`):

```zig
pub fn buildLockResponseDeny(buf: []u8, req: LockRequestHead, err_msg: []const u8) ![]u8 {
    return buildLockResponse(buf, req, false, err_msg);
}
```

An unlock the requester may not perform answers with `success = false` and an empty error message, the stock shape for nothing locked (`src/wire/packages.zig:3531`). A malformed request body is logged and dropped whole, so a truncated span cannot leave a half-written channel (`src/server/c2s/misc.zig:1217`). The parser bound is wider than the handler rule: it walks up to 64 targets because the deny echoes the request's list, while the handler refuses above the stock ceiling of five (`src/wire/packages.zig:3374`, `:3391`).

## Persistence

Quest POI locks are not persisted: the table lives on the sim world, so a restart begins with no locks because there are no active questers to hold them. Container channel locks are session state on `Game`, cleared on disconnect and never written. Land claims are the one durable part, saved to `{world_dir}/claims.zlc` with a four-byte magic `ZCLC`, a `u16` count, then one 49-byte record per claim: the three coordinates, the owner name length, the 32-byte owner name and the last-seen day (`src/server/persist.zig:1932`):

```zig
pub fn saveClaims(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/claims.zlc", .{self.world.world_dir});
    // ...
```

The owner entity is deliberately not stored, because it is reassigned across restarts; a restored claim has no live owner until its player logs in, and the name keys the re-map (`src/server/persist.zig:1991`, `src/server/game.zig:2065`). The preserved last-seen day keeps the offline expiry math honest across a restart, so a claim cannot be kept alive by a server that was down (`src/server/persist.zig:1957`). Loading fails closed: a bad magic or an out-of-range count is an error rather than a partial restore, a short record is `error.Truncated`, and a missing file is a fresh world (`src/server/persist.zig:1970`, `:1972`, `:1977`). Claims are also dropped when their owner is wiped, and the file is rewritten immediately so the login name does not survive on disk after an administrative erasure (`src/server/admin_console.zig:1458`).

## See also

- [`quests.md`](quests.md): the quest lifecycle that takes, holds and releases the POI lock.
- [`ecs.md`](ecs.md): the world resource the lock table lives on and the POI rectangles it stores.
- [`c2s.md`](c2s.md): the dispatch order and reject counters the lock handlers run behind.
- [`persistence.md`](persistence.md): the save set `claims.zlc` belongs to.
- [`admin.md`](admin.md): the `wipeplayer` path that drops claims and allies by name.
