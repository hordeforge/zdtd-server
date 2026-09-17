# Join, phases and the peer state machine

This subsystem owns one connected peer's life from the LiteNet challenge to
playing, and the teardown when that life ends: the three-value phase model, the
pre-play C2S allowlist, the login/enter/spawn bundles, and every path that frees
a client slot. It does not own LiteNet framing and retransmission (`src/litenet/`),
the package bodies (`src/wire/`), the sim and world state the bundles read
(`src/ecs/`, `src/world/`), or the record formats (`src/server/persist.zig`). The
package comment in `src/server/root.zig` makes `server` the top of the dependency
stack, importing every other package with no edge back up (src/server/root.zig:1-7).

Two files share the word "join". `src/server/c2s/join.zig` is the state machine
(c2s/join.zig:1-7); `src/server/game/join.zig` holds the join-bundle encoders
(`sendDecoAroundSpawn`, `sendSignDataBatches`, `sendPlayerVitals`),
game/join.zig:1-5. `sendJoinBundle` itself lives in `src/server/game.zig`
(game.zig:2771), not in the file named after it, although
docs/ARCHITECTURE.md:371 attributes it to `game/join.zig`.

Sources: [`src/server/phase_gate.zig`](../../src/server/phase_gate.zig), [`src/server/c2s/join.zig`](../../src/server/c2s/join.zig), [`src/server/c2s/dispatch.zig`](../../src/server/c2s/dispatch.zig), [`src/server/game.zig`](../../src/server/game.zig), [`src/server/game/join.zig`](../../src/server/game/join.zig), [`src/server/game/types.zig`](../../src/server/game/types.zig), [`src/server/game/session_drop.zig`](../../src/server/game/session_drop.zig), [`src/server/game/tick.zig`](../../src/server/game/tick.zig), [`src/server/game/net.zig`](../../src/server/game/net.zig), [`src/server/game/net_handlers.zig`](../../src/server/game/net_handlers.zig), [`src/server/game/config_files.zig`](../../src/server/game/config_files.zig)

## Phase is derived, not stored

`Phase` has three values, computed on every C2S package from two `Client` flags
by `phaseOf`: `.playing` only when both are set (src/server/phase_gate.zig:17).
The type (src/server/phase_gate.zig:6):

```zig
/// Client join progress. Mapped from Client.joined / Client.entered.
pub const Phase = enum(u8) {
    /// Challenge/auth done, PlayerLogin not accepted yet.
    connecting,
    /// Login accepted, join bundle not yet sent (enter/spawn SM).
    joined,
    /// Join bundle sent; world play C2S legal.
    playing,
};
```

`joined` is set when PlayerLogin is accepted (c2s/join.zig:224) and again on the
two recovery paths, the `RequestToEnterGame` spawn fallback (c2s/join.zig:256)
and the `RequestToSpawnPlayer` handler (c2s/join.zig:551). `entered` is set once
per slot, at the top of `sendJoinBundle` and before any bundle body is written
(game.zig:2783). There is no Phase value for the challenge step: a peer that has
not echoed the challenge never reaches the gate, because `onData` returns before
dispatch until the echo validates (net_handlers.zig:49-89).

Two consequences matter when modifying this. The phase flips to `playing` while
the bundle is still being sent, so a package the client sends in that window is
already fully legal: the gate stops a peer that skips the state machine, it does
not make the join atomic. Death does not leave `playing` either: `entered` stays
true and the re-bundle takes the `else` arm at game.zig:3004.

## The gate and per-package legality

`dispatch.handlePackage` resolves the numeric id through
`packages.default_mappings`, computes the phase, and asks `phase_gate.allowed`
before any handler runs (dispatch.zig:20-39). The allowlists
(src/server/phase_gate.zig:23):

```zig
/// Packages legal before PlayerLogin is accepted (connecting). A peer that
/// never logs in must not be able to reach the enter/spawn handlers and get a
/// join bundle without an identity (AGENTS rule 18: gate matches the SM state).
const connecting_allow: []const []const u8 = &.{
    "NetPackagePlayerLogin",
    "NetPackagePlayerDisconnect",
};

/// Packages legal after login but before the join bundle (joined).
const joined_allow: []const []const u8 = &.{
    "NetPackagePlayerLogin", // re-login mid-session
    "NetPackageRequestToEnterGame",
    "NetPackageRequestToSpawnPlayer",
    "NetPackageAuthConfirmation",
    "NetPackageSignDataRequest",
    "NetPackageWorldInitInfoRequest",
    "NetPackageDynamicClientArrive",
    "NetPackagePOIMetadataRequest", // V3.2.0: the client asks during world creation (DynamicPrefabDecorator)
    // World-folder download (GameManager.worldInfoCo → RequestWorld): the
    // client asks after WorldInfo when local hashes miss; stock answers with
    // StartSendingPacketsToClient. Must be legal before the join bundle.
    "NetPackageWorldFolder",
    "NetPackagePlayerDisconnect",
};
```

| Phase | Legal C2S | Table |
|---|---|---|
| (before echo) | nothing reaches the gate | net_handlers.zig:49-89 |
| `connecting` | `PlayerLogin`, `PlayerDisconnect` | phase_gate.zig:26 |
| `joined` | login re-send, `RequestToEnterGame`, `RequestToSpawnPlayer`, `AuthConfirmation`, `SignDataRequest`, `WorldInitInfoRequest`, `DynamicClientArrive`, `POIMetadataRequest`, `WorldFolder`, `PlayerDisconnect` | phase_gate.zig:32 |
| `playing` | every mapped C2S name | phase_gate.zig:58 |

The `playing` arm is an unconditional `true` (phase_gate.zig:62), so the gate is
not a typo filter: typed handlers still do their own ownership and bounds checks
(docs/AUTHORITY.md). A denied package is dropped with the `phase_rejects` counter
and a `.phase` / `.hard` evidence record (dispatch.zig:29-34); there is no
disconnect arm here, although docs/STATE_MACHINES.md:50 lists "gate drop /
disconnect" as an exit from Entering. An id at or past `default_mappings.len` is
logged and dropped before the gate (dispatch.zig:20-24).

## Challenge, login and enter

1. `onConnected` allocates a client slot and sends the 17-byte challenge, whose
   16-byte nonce comes from the CSPRNG rather than a counter
   (net_handlers.zig:13-38, net.zig:465-480). The client echoes it; `onData`
   compares in constant time, sets `authed_challenge`, clears `challenge_ns`,
   sends `NetPackagePackageIds`, and replays a payload that raced the echo out of
   `preauth_buf` (net_handlers.zig:49-75).
2. `NetPackagePlayerLogin`, gated before any effect: version equality against
   `version.stock_wire_comp` (c2s/join.zig:77), the `PlayerSlotsAuthorizer` tier
   math (c2s/join.zig:99-113), plugin and Wasm denies (c2s/join.zig:144-155), the
   identity ban (c2s/join.zig:164-171), and the whitelist when configured
   (c2s/join.zig:179-205). On accept: `PlayerLoginAnswer` with the full GSI text
   (c2s/join.zig:207), an empty `AuthConfirmation` the client echoes
   (c2s/join.zig:215), the sim player spawn (c2s/join.zig:218), claim and turret
   re-mapping by login name (c2s/join.zig:222-223), and `tryRestorePlayer`
   (c2s/join.zig:230). A re-login while joined takes the early arm: answer plus
   `PlayerSpawnedInWorld`, no second enter (c2s/join.zig:47-59).
3. `NetPackageRequestToEnterGame` arms one critical deadline for the whole
   bundle (c2s/join.zig:251) and sends, in order: blocks id mapping,
   localization, the 42 config rows, `WorldInfo`, `ChunkClusterInfo`,
   `WorldSpawnPoints`, `WorldAreas`, `WorldTime`, `GameStats`, then the join deco
   burst (c2s/join.zig:262-286). `WorldInfo` goes out here and never in the spawn
   bundle, because a second one restarts the client's `createWorld` mid-session
   (c2s/join.zig:270-272).
4. `SignDataRequest` answers with batched `SignDataResponse`, the final batch a
   critical send because the client blocks worldInfo continuation on
   `isLastBatch` (game/join.zig:233-270); `POIMetadataRequest` answers with the
   compressed 3.2.0 metadata blob (c2s/join.zig:349-380); `WorldFolder` answers
   with one empty last part (c2s/join.zig:295-305).
5. `WorldInitInfoRequest` answers with an empty `WorldInitInfo` and sets
   `world_ready`, when the chunk streamer may start (c2s/join.zig:384-398).
   `DynamicClientArrive` is the fallback: with an entity it sends the join
   bundle, without one `WorldInitInfo` plus the spawn area (c2s/join.zig:403-439).
6. `RequestToSpawnPlayer` parses `chunkViewDim` (clamped to 8, c2s/join.zig:31)
   and the client's profile (c2s/join.zig:456), spawns or revives the sim player
   (c2s/join.zig:461-550), streams the spawn area before the bundle
   (c2s/join.zig:563), then calls `sendJoinBundle` (c2s/join.zig:570).

Two stock paths are deliberately unanswered: `DynamicClientArrive` after enter,
where stock reconciles a dynamic mesh, is a no-op (c2s/join.zig:404-408), and
drones have no zdtd surface in the spawn-confirm relay (c2s/join.zig:318).
`sendTraderSnapshot` is an empty stub with the reason inline (game/join.zig:273-280).
The handler answers ten names while the header enumerates seven (c2s/join.zig:1-7).

## The join bundle

`sendJoinBundle` branches once on `first_join`, the same expression that flips the
phase (game.zig:2782), into the first-join id bundle or the respawn re-bundle.
First join sends `NetPackagePlayerId` with the persistent player data (quests,
unlocked recipes, toolbelt and bag, counters, profile) as a critical send
(game.zig:2850-2876), then `NetPackagePersistentPlayerState` broadcast, the
compact item mapping, nav objects, empty holding and vitals (game.zig:2922-2944),
`PlayerSpawnedInWorld`(enterMultiplayer) latching `IsSpawned` early
(game.zig:2947-2957), entity and player spawn bursts, buff sync, riders, vehicle
waypoints, bag markers and ally snapshot (game.zig:2958-2989), the spawn-area
chunk burst (game.zig:2990-2993), and a second `PlayerSpawnedInWorld` after the
stream (game.zig:2994-3003). The re-bundle arm sends `Spawned`(died), a
teleport, holding, vitals and nav objects only (game.zig:3004-3023). Both arms
end with `WorldTime`, `GameStats`, blood-moon music when eligible, and `Weather`
only on a re-bundle (game.zig:3024-3039).

Must-deliver sends use `sendGameCritical` under a per-peer deadline armed by the
caller (c2s/join.zig:251, c2s/join.zig:416, c2s/join.zig:568) with a 1 s budget,
bounding the worst case stall of the single tick thread rather than one join
(types.zig:167-176). The synchronous spawn area is capped to the collision-mesh
core, outer rings draining at `chunk_adds_per_stream_tick` per tick
(types.zig:612-621); the whole C2S join handler runs in one `.join` APM section
(c2s/join.zig:39).

## Identifiers and config sync

Three id exchanges ride the join: `NetPackagePackageIds` right after the
challenge echo (net_handlers.zig:54); the blocks mapping before the config files,
because the client only runs `AssignIds` once a `ConfigFile` package has arrived
(game.zig:2470-2480) and it is skipped whole when no AssignIds dump loaded, so a
partial blob cannot renumber unnamed blocks (game.zig:2483-2492); and a
deliberately compact item mapping of the twelve ECS builtin ids that resolve to
stock types (game/join.zig:699-717). Config sync is the 42-row `s2c_names` table
(config_files.zig:31-39), deflated once per row into a process-global cache at
init (config_files.zig:46-75) and streamed as one `NetPackageConfigFile` per row
(config_files.zig:141-180); an absent patched XML still sends length `-1` so
`WaitForConfigsFromServer` completes (config_files.zig:166), where stock omits the
row (config_files.zig:6-8). None of this proves stock compatibility: a green zdtd
encode followed by zdtd decode shows the two halves agree with each other, not
that either matches stock.

## The peer record

Session state is one `Client` value per slot, allocated by `clientFor`
(net.zig:433-484) and reset with `clients[slot] = .{}`. The flags that drive the
phase and the streamers (src/server/game/types.zig:604):

```zig
    authed_challenge: bool = false,
    joined: bool = false,
    /// True after sendJoinBundle (WorldInfo/PlayerId). Gate tick broadcasts until then.
    entered: bool = false,
    /// Client's ChunkCache exists (it sent WorldInitInfoRequest, which
    /// worldInfoCo only does after createWorld). Chunks sent from here on
    /// are kept, so the tick streamer can start well before the spawn.
    world_ready: bool = false,
```

The nonce sits in `challenge`, with `challenge_ns` as the auth-state start
(types.zig:622-626). `preauth_buf` holds a payload that raced the echo, replayed
after auth (types.zig:672-673), and `join_reject` holds a deferred `KickReason`
sent only once PackageIds has been exchanged (types.zig:679).

Other join-scoped fields are cleared for free by the `.{}` reset:
`known_entities` (types.zig:665), `guard` policy state (types.zig:718-720), the
platform identities `PersistentPlayerData` and the ally store key on
(types.zig:724-731), and the chosen `profile` (types.zig:733-740). `view_radius`
comes from the client's `chunkViewDim` at `RequestToSpawnPlayer`, else the server
default (c2s/join.zig:441-450).

## Drop, reap and timeouts

A session ends three ways. `NetPackagePlayerDisconnect` saves the player record
and calls `dropClientSlot` with reason "quit", accepting only the sender's own
entity id (c2s/misc.zig:356-368). The tick reaper has three arms
(tick.zig:1526-1588): a peer whose transport is already dead, a peer past the
10 s auth-state cap that never echoed the challenge although its socket stays
warm, and a peer silent past `peer_stale_ms` (types.zig:136). Armed guard-policy
kicks drop through `dropClientSlot` on a later tick (tick.zig:1592-1601). Reaper
and guard sweep run once per tick right after the net poll (step.zig:81-82).

`dropClientSlot` is the one teardown path (session_drop.zig:11). It notifies
plugins, saves the player record before anything else because the ZPV write reads
the in-memory record it is about to lose (session_drop.zig:16-29), marks the
transport peer dead, unseats riders, releases locks and claims, removes the party
member and broadcasts the removal, sends `remove_quest` for the player's shared
quests, fans out `NetPackageEntityRemove`, destroys the sim entity, clears any
turret still naming the slot, then resets the value (session_drop.zig:30-94).

The three reap arms in `reapStalePeers` do not call it: they reset the slot in
place after `clearLocksForPeer` (tick.zig:1547, tick.zig:1568, tick.zig:1584), so
that path skips the party, claim, shared-quest and `EntityRemove` teardown. The
dead-peer arm of `clientFor` does call `dropClientSlot`, with a comment naming
the ghost-player bug the inline reset used to leave behind (net.zig:449-453).

What survives a restart is the player record, not the session. `savePlayers`
writes `players.zsv` (ZPV16, merge-write so offline records are carried over:
persist.zig:1, persist.zig:573) and `tryRestorePlayer` reads it back into the
`Client` at login (persist.zig:1067, called at c2s/join.zig:230 and
c2s/join.zig:257). Claims and turret ownership are keyed by login name and
re-mapped to the new entity id (c2s/join.zig:222-223), and vending rentals are
matched by platform id when `PersistentPlayerState` is built
(game.zig:2911-2921). Shutdown flushes players first, then the world, then the
remaining stores in reverse construction order (lifecycle.zig:9-44,
lifecycle.zig:49-77).

## See also

- [Architecture, section 5: join flow](../ARCHITECTURE.md#5-join-flow)
- [State machines, section 1: join / client session SM](../STATE_MACHINES.md#1-join--client-session-sm)
- [Server authority](../AUTHORITY.md)
- [Wire package catalog](../wire/PACKAGES.md)
