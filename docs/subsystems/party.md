# Party and allies

This subsystem owns the two social groupings a stock client knows: the transient party of human players keyed by runtime entity id, and the persistent ally relationship keyed by platform identity. The party engine is `ecs/party.zig`, which states its own boundary in the header: it is pure state over entity ids, with no `Game` import and no clock, because both stock packages that carry a party are entity-id keyed and the group is thrown away on disband exactly as stock's `PartyManager` does (`src/ecs/party.zig:1`). The ally store is `server/ally.zig`, which states the mirror rule for identity: pure state over `PlatformUserIdentifierAbs`, no `Game` import, and only the persist helpers touch I/O (`src/server/ally.zig:1`). The wire bodies are `wire/stock_party.zig` plus the two ally packages in `wire/packages.zig`, and the identity codec they share is `wire/platform_user.zig`. The C2S routing is the quest-domain handler, and the fan-out, snapshot, snapshot-on-join and ally transition live in `server/game/social.zig`. Import direction is enforced: `ecs` may import `util` only (`src/ecs/root.zig:3`), `wire` may import `util`, `assets`, `ecs` shapes and `world` domain types (`src/wire/root.zig:3`), and `server` may import every package (`src/server/root.zig:3`). A party survives nothing: it is per-session state with no save file. An ally relationship survives a restart in `{world_dir}/allies.zal`, a zdtd-owned format because stock keeps allies in its persistent player list instead (`src/server/ally.zig:20`).

Sources: [`src/ecs/party.zig`](../../src/ecs/party.zig), [`src/server/ally.zig`](../../src/server/ally.zig), [`src/wire/stock_party.zig`](../../src/wire/stock_party.zig), [`src/wire/packages.zig`](../../src/wire/packages.zig), [`src/wire/platform_user.zig`](../../src/wire/platform_user.zig), [`src/server/game/social.zig`](../../src/server/game/social.zig), [`src/server/c2s/quest.zig`](../../src/server/c2s/quest.zig), [`src/server/game/session_drop.zig`](../../src/server/game/session_drop.zig), [`src/server/persist.zig`](../../src/server/persist.zig), [`src/server/admin_console.zig`](../../src/server/admin_console.zig).

## Party state

A party is a fixed eight-slot member list with a leader index and a voice lobby id (`src/ecs/party.zig:24`):

```zig
pub const Party = struct {
    id: i32 = -1,
    members: [max_party_members]i32 = .{-1} ** max_party_members,
    n: u8 = 0,
    leader_index: u8 = 0,
    /// VoiceLobbyId (SetVoiceLobby). zdtd owns no voice lobby; kept for the
    /// wire round-trip (NetPackagePartyData serializes it).
    voice_lobby: [64]u8 = undefined,
    voice_len: u8 = 0,
```

The eight-member cap is stock `Party.AddPlayer` and `IsFull`, not a zdtd bound, and the manager holds at most eight concurrent parties because the player cap bounds the meaningful set (`src/ecs/party.zig:17`, `:19`). Slots are allocated from a `used` bitmap and freed on disband, with a monotonic party id starting at 1 like `PartyManager.nextPartyID` (`src/ecs/party.zig:64`). Every lookup is a linear scan over the live parties: `partyById` mirrors `PartyManager.GetParty`, and `partyByMember` is the `EntityPlayer.Party` question the C2S handlers ask (`src/ecs/party.zig:100`, `:108`). A party of one is never kept: the removal that leaves a single member disbands the party and reports the last survivor as the changed entity, because stock's last member auto-leaves (`src/ecs/party.zig:155`). Leader bookkeeping is index-based and covers all three cases in one pass: the leader leaving resets the index to zero, a member leaving below the leader shifts it down, and a removal that reports a disband returns no members at all (`src/ecs/party.zig:167`). A party membership is never written to disk, and the manager holds no clock, so a restart simply starts with no parties.

## Invite, accept, change-lead, leave

The accept path is stock's two-step create: when the inviter already has a party the accepted player joins it, otherwise a new party is allocated and the inviter is added first so that it has a leader at index zero (`src/ecs/party.zig:129`):

```zig
    pub fn acceptInvite(self: *Manager, inviter: i32, accepted: i32) ?*Party {
        if (inviter < 0 or accepted < 0 or inviter == accepted) return null;
        if (self.partyByMember(accepted) != null) return null; // already grouped
        const p = self.partyByMember(inviter) orelse (self.allocParty(self.next_party_id) orelse return null);
        // A fresh party's first AddPlayer is the inviter (leader index 0).
        if (p.n == 0) {
            self.next_party_id += 1;
            if (!self.addPlayer(p.id, inviter)) return null;
        }
```

`addPlayer` refuses a duplicate member and a full party after the cap check, and a negative entity id is refused so an unspawned client cannot occupy a slot (`src/ecs/party.zig:120`). `setLeader` requires the new leader to already be a member and stores the stock `MemberList.IndexOf` result (`src/ecs/party.zig:148`). Removal is one function for all three stock entry points, leave, kick and disconnect (`src/ecs/party.zig:160`):

```zig
    pub fn removePlayer(self: *Manager, entity_id: i32) ?Removal {
        if (entity_id < 0) return null;
        const p = self.partyByMember(entity_id) orelse return null;
        var out = Removal{
            .party_id = p.id,
            .changed_entity = entity_id,
        };
```

`autoJoin` is `ServerHandleAutoJoinParty`: it joins or creates party id 1 and leaves the `AutoParty` world-stat decision to the caller (`src/ecs/party.zig:192`). `setVoiceLobby` copies the id for the wire round trip only; zdtd has no voice lobby integration (`src/ecs/party.zig:202`). The removal result type exists so the caller can build the right final snapshot: it carries the remaining members, the changed entity and the disband flag (`src/ecs/party.zig:52`).

## C2S routing and authorization

Both party and ally packages are routed from the quest-domain handler, which is where the social packages arrive on the stock exchange (`src/server/c2s/quest.zig:205`). A server-to-client `NetPackagePartyData` arriving from a client is counted as an ownership reject and dropped rather than parsed (`src/server/c2s/quest.zig:209`), and the same treatment is given to `NetPackageAllyResponse`, which is a ToClient direction package (`src/server/c2s/quest.zig:294`). The party action body is parsed into an action byte, two entity ids and a voice string, and a parse failure increments the malformed counter and returns without any state change (`src/server/game/social.zig:167`).

Every action is authorized against live state before it mutates anything. The target must be a currently connected client, checked once before the switch (`src/server/game/social.zig:172`). Accept requires both a non-negative inviter and a connected target, then runs `acceptInvite` (`src/server/game/social.zig:175`). Change-lead requires the sender's own party, requires the sender to be its leader, and then re-targets the leader index (`src/server/game/social.zig:190`). Kick requires the sender to be the leader and the named entity to already be a member, so a leader cannot kick a stranger (`src/server/game/social.zig:211`). Leave and the disconnect action both remove the sender, and the sender is the only identity taken from the packet on those paths (`src/server/game/social.zig:204`, `:217`). The auto-join and voice-lobby actions resolve the sender's party, and an unknown action byte falls through with no effect (`src/server/game/social.zig:235`, `:249`). Every successful mutation ends in one broadcast helper, `broadcastPartySnapshot` or `broadcastPartyRemoval`, so no path can change the group without telling the affected peers (`src/server/game/social.zig:253`, `:290`).

A disconnect runs the same removal without a client packet: the session drop path removes the departing entity from its party and broadcasts the removal with the `disconnected` action, then continues with the shared-quest withdrawal and the entity remove (`src/server/game/session_drop.zig:36`).

## The party wire bodies

`NetPackagePartyActions` is the client-to-server action package. Its body is an operation byte, the inviter entity id, the invited entity id and the voice lobby string; the stock `partyMembers` field is deliberately not serialized (`src/wire/stock_party.zig:2`). The action values are the stock enumeration, with the eight known names and a catch-all arm so an unknown byte still parses (`src/wire/stock_party.zig:16`):

```zig
pub const PartyActions = enum(u8) {
    send_invite = 0,
    accept_invite = 1,
    change_lead = 2,
    leave_party = 3,
    kick_from_party = 4,
    disconnected = 5,
    join_auto_party = 6,
    set_voice_lobby = 7,
    _,
};
```

`readActions` parses that order into caller-owned scratch and treats the body as untrusted: a short body or an over-long voice string is a read error and the caller drops the packet (`src/wire/stock_party.zig:35`). The response direction is `NetPackagePartyData`, and its snapshot is built from the manager's own state rather than from the request (`src/wire/stock_party.zig:72`):

```zig
pub const PartyDataArgs = struct {
    party_id: i32,
    leader_index: u8,
    voice_lobby: []const u8 = "",
    /// Member entity ids (≤ 8).
    members: []const i32,
    changed_entity: i32 = -1,
    party_action: u8 = 0,
    disband: bool = false,
};
```

The encoder writes the party id, a narrowed leader index byte, the voice lobby, the member count, the members, the changed entity, the action and the disband flag (`src/wire/stock_party.zig:85`). It refuses more than 255 members rather than truncating the count field, though the party cap makes that unreachable from the manager (`src/wire/stock_party.zig:90`). A disband snapshot is sent to the changed entity even though the member list is empty, which is what tells the last survivor the group is gone (`src/server/game/social.zig:275`). Shared party kills have their own body, a four-field record of entity type, experience, killed entity and killer, parsed by the server from the client report and validated against live entities by the caller (`src/wire/stock_party.zig:99`, `:127`).

## Ally identities and transitions

Allies are keyed on the platform identity, not on the runtime entity, so the relationship survives a reconnect and a restart. One pair is stored once, with the status of the first identity toward the second and the reverse derived as its mirror, because stock's `SetStatus` always writes both directions and they are mirrors of one another (`src/server/ally.zig:13`). The four states include the two pending invite directions (`src/server/ally.zig:30`):

```zig
pub const Status = enum(u8) {
    not_allied = 0,
    allies = 1,
    outgoing_invite = 2,
    incoming_invite = 3,

    /// The same relationship seen from the other player. `SetStatus` writes this
    /// value into the reverse direction (asm.il 885424).
    pub fn mirror(self: Status) Status {
```

Every request is a pure transition on the pair, computed from the current status and an `add_ally` flag, with the events each side should receive (`src/server/ally.zig:76`):

```zig
pub fn computeTransition(old: Status, add_ally: bool) Transition {
    const unchanged: Transition = .{ .new_status = old, .event_source = .none, .event_target = .none };
    return switch (old) {
        .not_allied => if (add_ally) .{
            .new_status = .outgoing_invite,
            .event_source = .outgoing_sent,
            .event_target = .incoming_received,
        } else unchanged,
```

The five edges are the whole relationship machine: a request from `not_allied` becomes an outgoing invite, an incoming invite accepted becomes mutual allies, and declined or cancelled requests return to `not_allied` with the matching notification events (`src/server/ally.zig:91`). A no-op transition still holds a status but carries no events, and the handler then sends nothing, because stock's response would tell neither side anything (`src/server/ally.zig:69`). A transition is applied by `processRequest`, which computes it, writes the new status and hands it back so the caller can encode the response (`src/server/ally.zig:285`). `setStatus` clears the pair for `not_allied` and otherwise stores it with the mirror applied when the stored direction is reversed (`src/server/ally.zig:150`). The store holds 256 pairs; a request beyond that is refused with `error.Full` rather than evicting an existing relationship, and the handler counts it as a throttle (`src/server/ally.zig:108`, `src/server/game/social.zig:414`).

The C2S handler requires the request's source identity to be the sender's own primary identity; a body naming another player is an ownership reject (`src/server/game/social.zig:407`). Both identities must decode to a value, because a null one is a dead request that stock drops before writing anything, and a successful transition is encoded as `NetPackageAllyResponse` and broadcast to every peer (`src/server/game/social.zig:419`, `:427`). On join the server sends a standing-ally snapshot to the joining peer, one response per stored pair with the `none` event, because the client's ally store is otherwise driven only by transitions and would forget every pair formed before this connection (`src/server/game/social.zig:368`, `:382`). The response body's direction is ToClient, so the server only ever writes it (`src/wire/packages.zig:6678`).

## The `.zal` file and its lifetime

`allies.zal` sits in the world directory and is written by the store itself, which owns the path formatting and the only allocation on this path. The header is a four-byte magic `ZAL1` and a `u16` record count; each record is four length-prefixed identity strings and a status byte (`src/server/ally.zig:198`):

```zig
    pub fn save(self: *const Store, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/allies.zal", .{dir});
        const buf = try allocator.alloc(u8, 6 + max_pairs * (1 + 16 + 1 + 64 + 1 + 16 + 1 + 64 + 1));
        defer allocator.free(buf);
        @memcpy(buf[0..4], "ZAL1");
        var o: usize = 6; // 4 magic + 2 count reserved; records start at 6
        var save_count: u16 = 0;
```

The identity strings are bounded to 16 bytes of platform and 64 bytes of id, and only used pairs are written (`src/server/ally.zig:199`). Loading fails closed: a missing file is a fresh server, any other read error surfaces so the caller can log before the next save clobbers data, and a bad magic or a corrupt record stops the load with an error rather than loading a partial set (`src/server/ally.zig:237`). The status byte is range-checked before the enum conversion, because `Status` is an exhaustive `u8` enum and an out-of-range conversion would panic rather than return (`src/server/ally.zig:267`). Every step of the load goes back through `setStatus`, so a loaded file cannot produce a state the runtime could not (`src/server/ally.zig:276`). The store is written on the periodic autosave and on shutdown (`src/server/game/step.zig:537`, `src/server/persist.zig:66`), and loaded once at boot (`src/server/game.zig:1150`). `wipeplayer` erases an identity from the file on both identity forms of the named client and rewrites it immediately, so an erased player cannot survive in `allies.zal` (`src/server/admin_console.zig:1444`, `:1459`).

## See also

- [`ecs.md`](ecs.md): the world and entity model the party's entity ids point into.
- [`c2s.md`](c2s.md): the dispatch order and the phase gate these handlers sit behind.
- [`wire.md`](wire.md): the identity codec and the framing both party packages use.
- [`persistence.md`](persistence.md): the world save paths `allies.zal` is written beside.
- [`quests.md`](quests.md): the shared-quest and party-kill paths that read the same membership.
