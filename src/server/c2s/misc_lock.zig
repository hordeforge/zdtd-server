//! C2S lock arm: container/door lock requests.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const packLockPos = game_mod.Game.packLockPos;
const firstLockTargetPos = game_mod.Game.firstLockTargetPos;
const clock = @import("../../util/clock.zig");
const ecs = @import("../../ecs/root.zig");
const vending_mod = @import("../../world/vending.zig");
const wire_binary = @import("../../wire/binary.zig");
const systems = @import("../../ecs/systems.zig");
const plugin_compose = @import("../game/plugin_compose.zig");
const replicate_te = @import("../game/replicate_te.zig");
const log = @import("../../util/log.zig");

/// One `NetPackageLockTarget` address entry, decoded from the `WorldAddress`
/// tag byte (b18: tag 0 None, 1 TileEntity, 2 TEFeature, 3 Entity; no
/// presence byte precedes it, protocol-packages.md §1.5.1).
const LockTarget = union(enum) {
    /// Tag 1 TileEntity / tag 2 TEFeature (prefab name already skipped).
    pos: [3]i32,
    /// Tag 3 Entity id.
    entity_id: i32,
    /// Tag 0 None: empty slot, no payload.
    empty,
};

/// Decode one target address. null ends the walk: truncated entry or unknown
/// tag. Stock aborts the package read there, so the reader position is
/// untrustworthy past that point and callers must stop.
fn nextLockTarget(r: *wire_binary.Reader) ?LockTarget {
    const ty = r.readByte() catch return null;
    switch (ty) {
        0 => return .empty, // WorldObjectType.None
        1, 2 => { // TileEntity / TEFeature: Vector3i (+ feature name on 2)
            const x = r.readI32() catch return null;
            const y = r.readI32() catch return null;
            const z = r.readI32() catch return null;
            if (ty == 2) r.skipString() catch return null;
            return .{ .pos = .{ x, y, z } };
        },
        3 => return .{ .entity_id = r.readI32() catch return null }, // Entity
        else => return null,
    }
}

/// True when `name` is a lock package and was handled.
/// Sandbox `VendingEnabled` off disables the machine's activation command
/// (`BlockVendingMachine` IL_006D-0190 sets `cmds[0].enabled`), so the position is
/// not a vending target: the machine does not open and no TraderData is echoed.
pub fn vendingTargetAt(self: *Game, x: i32, y: i32, z: i32) ?vending_mod.PosKey {
    if (!self.vending_enabled) return null;
    const p: vending_mod.PosKey = .{ .x = x, .y = y, .z = z };
    if (self.vending.get(p) == null) return null;
    return p;
}

pub fn handleLock(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageLockTarget")) {
        // The package body is `i32 payloadLen | payload`; strip the framing
        // before parsing the LockManager request (protocol-packages.md §1.5.1).
        const payload = packages.unwrapLockTargetPayload(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (packages.parseLockRequest(payload)) |req| {
            // Deny acquiring a container lock while quarantined; always let
            // an unlock through so a quarantined peer cannot pin a channel.
            if (req.is_lock and self.quarantineDenies(c, .container)) return true;
            const ch: usize = @min(@as(usize, req.channel), self.lock_channel.len - 1);
            // Stale holder on this channel before grant check.
            if (self.lock_channel[ch] >= 0 and self.lock_granted_ns[ch] != 0) {
                const now = clock.monoNs();
                if (lockIsStale(now, self.lock_granted_ns[ch], self.lock_stale_ns)) self.clearLockSlot(ch);
            }
            const pos_key: u64 = if (firstLockTargetPos(req.targets_blob)) |p|
                packLockPos(p.x, p.y, p.z)
            else
                0;
            if (req.is_lock) {
                // Gate 1 (IL=239): any existing entry for this player is invalid
                // state. Stock force-unlocks everything the player holds and
                // returns without granting the new request (the ret at IL_0067).
                // The RE prose said "then continue"; the IL is the authority and
                // says otherwise.
                if (self.peerHoldsLock(c.slot)) {
                    self.releaseAllLocksForPeer(c.slot);
                    return true;
                }
                // Gate 2 (`LockRequestServer` IL_000E-0014): accept a span of
                // 1..5. Over-limit logs and **drops** with no reply in b18
                // (protocol-packages.md §1.5.1); a null target fails closed
                // with a deny (IL_00BE), so the client's pending lock resolves.
                if (req.target_count < 1 or req.target_count > packages.max_lock_targets_declared) {
                    self.harness.counters.inc(.c2s_rejects);
                    return true;
                }
                if (req.has_null_target) {
                    const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "null target");
                    try self.sendGame(peer, "NetPackageLockTarget", resp);
                    return true;
                }
                // Parse the targets once. An entity target that is a trader
                // opens the trader window from the LockResponse context; a
                // vending position opens the machine. Gate 4 needs this before
                // the lock table is written.
                var trader_slot: ?ecs.Slot = null;
                var vending_pos: ?vending_mod.PosKey = null;
                if (req.targets_blob.len >= 4) {
                    var tr: wire_binary.Reader = .{ .data = req.targets_blob };
                    const n = tr.readI32() catch 0;
                    var ti: i32 = 0;
                    while (ti < n) : (ti += 1) {
                        switch (nextLockTarget(&tr) orelse break) {
                            .entity_id => |eid| if (self.sim.slotOfNetId(eid)) |ts| {
                                // Sandbox `TradersEnabled` off: the trader is
                                // not an interaction target at all.
                                if (self.traders_enabled and self.sim.mask[ts].kind and self.sim.kind[ts] == .trader) {
                                    trader_slot = ts;
                                    break;
                                }
                            },
                            .pos => |p| {
                                // TileEntity lock target (type 0): a vending block
                                // under the position opens as a vending machine.
                                // Sandbox `VendingEnabled` off: stock disables the
                                // activation command, so the machine is not a
                                // vending target at all and a modified client
                                // gets the plain lock path.
                                vending_pos = vendingTargetAt(self, p[0], p[1], p[2]);
                            },
                            else => {},
                        }
                    }
                }
                // Gate 4 (IL=239): per-target CanLockOnServer. TEFeatureAbs,
                // TileEntity and TransactionalInventory return true;
                // EntityTrader refuses a dead or closed trader. It runs before
                // the grant, so a refused open leaves no server-side lock: the
                // old trader-deny path held the channel while telling the client
                // the lock failed.
                if (trader_slot) |ts| {
                    if (!self.sim.alive[ts] or !self.traderIsOpen(ts)) {
                        const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "closed");
                        try self.sendGame(peer, "NetPackageLockTarget", resp);
                        return true;
                    }
                }
                // Gate 3: the same TE already locked on another channel by
                // another player, or this channel held by someone else. Gate 1
                // cleared this player's own channels, so any holder is another.
                if (pos_key != 0) {
                    for (self.lock_pos_key, 0..) |pk, oi| {
                        if (oi == ch) continue;
                        if (pk != pos_key) continue;
                        if (self.lock_channel[oi] >= 0) {
                            const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "locked");
                            try self.sendGame(peer, "NetPackageLockTarget", resp);
                            return true;
                        }
                    }
                }
                if (self.lock_channel[ch] >= 0) {
                    const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "locked");
                    try self.sendGame(peer, "NetPackageLockTarget", resp);
                    return true;
                }
                self.lock_channel[ch] = @intCast(c.slot);
                self.lock_holder_entity[ch] = c.entity_id;
                self.lock_granted_ns[ch] = clock.monoNs();
                self.lock_pos_key[ch] = pos_key;
                if (trader_slot) |ts| {
                    // Stock restock is lazy, triggered by the open: rebuild the
                    // window with fresh rolls when the ResetInterval elapsed.
                    self.maybeRestockTrader(ts);
                    // trader_interact / turn-in quests advance on the open
                    // (stock QuestEventManager fires for the window open, not
                    // for a trade body); some clients signal the open with a
                    // minimal TraderData package, but the LockResponse path is
                    // the reliable one, so fire here too.
                    // The trader entity id makes the turn-in gate hold stock's
                    // giver rule; `ts` is the stock trader slot, and the entity
                    // is the NPC the client opened.
                    systems.questOnTraderOpenFrom(&self.sim, c.slot, self.sim.network_id[ts].id);
                    var ent_buf: [50]packages.TraderStockEntry = undefined;
                    const n = self.stockEntries(ts, &ent_buf);
                    // EntityTrader.OnLockResponseServer writes TraderData only
                    // on channel 1 (Trade); Interaction (0) writes nothing
                    // (EntityTrader.il.txt IL_005B-0082).
                    const resp = try packages.buildLockResponseTrader(&self.body_buf, req, .{
                        // TraderID indexes traders.xml; entity id leaves TraderInfo null.
                        .trader_id = self.sim.trader_stock[ts].trader_info_id,
                        .available_money = self.traderMoney(ts),
                        .entries = ent_buf[0..n],
                    }, req.channel == 1);
                    try self.sendGame(peer, "NetPackageLockTarget", resp);
                    // Wasm-first: the window-open announcement rides a plugin
                    // (kind 0 = trader open), not native code.
                    plugin_compose.traderEvent(self, c.entity_id, self.sim.network_id[ts].id, 0);
                } else if (vending_pos) |vp| {
                    // Vending machines are always open (trader_info has no
                    // hours). TileEntityVendingMachine.OnLockResponseServer
                    // always writes TraderData (no channel gate); the client
                    // opens the trader window from it.
                    const v = self.vending.get(vp) orelse return true;
                    replicate_te.maybeRestockVending(self, v);
                    var vent_buf: [vending_mod.max_vending_stock]packages.TraderStockEntry = undefined;
                    const vn = replicate_te.vendingEntries(self, v, &vent_buf);
                    const resp = try packages.buildLockResponseTrader(&self.body_buf, req, .{
                        .trader_id = v.trader_id,
                        .available_money = v.available_money,
                        .entries = vent_buf[0..vn],
                    }, true);
                    try self.sendGame(peer, "NetPackageLockTarget", resp);
                    try replicate_te.sendVendingTe(self, peer, vp.x, vp.y, vp.z);
                } else {
                    // TEFeatureAbs default OnLockResponseServer is empty (ret);
                    // a storage target would carry its grid here, but zdtd
                    // still re-pushes the TE below for the plain grant path.
                    const resp = try packages.buildLockResponseGrant(&self.body_buf, req, "");
                    try self.sendGame(peer, "NetPackageLockTarget", resp);
                }
                // Re-push TE for any storage container near the first TEFeature target.
                // Stock's open path is `activate -> lock request -> PopulateTE ->
                // LootContainerOpened` (loot-economy.md §2), so the deferred loot
                // roll fires here on the lock grant, before the grid ships.
                // zdtd adds the edit-reach gate stock omits on this path (rule 20):
                // a container the player cannot walk to must not roll or stream.
                if (req.targets_blob.len >= 4) {
                    var reach_ok = true;
                    if (self.sim.playerByPeer(c.slot)) |ps| {
                        reach_ok = self.sim.mask[ps].transform;
                    }
                    var tr: wire_binary.Reader = .{ .data = req.targets_blob };
                    const n = tr.readI32() catch 0;
                    var ti: i32 = 0;
                    while (ti < n) : (ti += 1) {
                        switch (nextLockTarget(&tr) orelse break) {
                            .pos => |p| {
                                if (reach_ok) {
                                    const ps = self.sim.playerByPeer(c.slot).?;
                                    const ep = self.sim.transform[ps];
                                    if (self.rejectIfBeyondEditRange(
                                        c,
                                        peer.local_id,
                                        c.entity_id,
                                        .container,
                                        ep.x,
                                        ep.y,
                                        ep.z,
                                        @floatFromInt(p[0]),
                                        @floatFromInt(p[1]),
                                        @floatFromInt(p[2]),
                                    )) continue;
                                }
                                if (self.containers.get(.{ .x = p[0], .y = p[1], .z = p[2] })) |cont| {
                                    self.ensureContainerLoot(cont, c.slot);
                                }
                                try replicate_te.sendStorageTe(self, peer, p[0], p[1], p[2]);
                                try replicate_te.sendWorkstationTe(self, peer, p[0], p[1], p[2]);
                                try replicate_te.sendVendingTe(self, peer, p[0], p[1], p[2]);
                                // A locked door's padlock rides its own composite
                                // body (`TEFeatureDoor` + `TEFeatureLockable`).
                                try replicate_te.sendDoorTe(self, peer, p[0], p[1], p[2]);
                            },
                            else => {},
                        }
                    }
                }
            } else {
                // Unlock only if we hold the channel (or free).
                if (self.lock_channel[ch] == @as(i32, @intCast(c.slot)) or self.lock_channel[ch] < 0) {
                    self.clearLockSlot(ch);
                    // Stock TEFeatureStorage.OnUnlockedServer -> CheckDestroyTileEntity
                    // (loot-economy.md 454-456): a container whose loot def has
                    // destroy_on_close is destroyed on close (airDrop "true"
                    // always; safes/backpacks "empty" only when emptied).
                    if (firstLockTargetPos(req.targets_blob)) |tp| {
                        self.maybeDestroyContainerOnClose(tp.x, tp.y, tp.z);
                    }
                    const resp = try packages.buildLockResponseUnlock(&self.body_buf, true);
                    try self.sendGame(peer, "NetPackageLockTarget", resp);
                } else {
                    const resp = try packages.buildLockResponseUnlock(&self.body_buf, false);
                    try self.sendGame(peer, "NetPackageLockTarget", resp);
                }
            }
        } else |_| {
            self.harness.counters.inc(.c2s_malformed);
            const mal = self.harness.counters.get(.c2s_malformed);
            log.warnEvery(mal, "LockRequest parse fail slot={d} body_len={d} n={d}\n", .{ c.slot, body.len, mal });
        }
        return true;
    }
    return false;
}

test "VendingEnabled gates the vending lock target" {
    // `BlockVendingMachine` IL_006D-0190: the machine's activation command is
    // enabled only while `TraderManager.VendingEnabled`, so the server must not
    // treat the position as a vending target when it is off.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const world_dir = try @import("../../util/test_tmp.zig").rootOf(&tmp);
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer g.destroy();
    _ = g.vending.getOrCreate(.{ .x = 7, .y = 70, .z = 8 }, 1234, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expect(vendingTargetAt(g, 7, 70, 8) != null);
    // A position with no machine stays null either way.
    try std.testing.expect(vendingTargetAt(g, 9, 70, 9) == null);
    g.vending_enabled = false;
    try std.testing.expect(vendingTargetAt(g, 7, 70, 8) == null);
    g.vending_enabled = true;
    try std.testing.expect(vendingTargetAt(g, 7, 70, 8) != null);
}

/// Pure staleness comparison for a held lock: only a forward clock can expire
/// one. A backwards or wrapped clock would otherwise read as a huge age and free
/// a live holder's slot, letting another player grab the container.
pub fn lockIsStale(now_ns: u64, granted_ns: u64, stale_ns: u64) bool {
    return now_ns >= granted_ns and now_ns -% granted_ns >= stale_ns;
}

test "a backwards clock does not expire a lock" {
    const granted: u64 = 10_000_000_000;
    const stale: u64 = 10_000_000_000; // 10 s
    try std.testing.expect(!lockIsStale(granted, granted, stale));
    try std.testing.expect(!lockIsStale(granted - 1, granted, stale));
    try std.testing.expect(!lockIsStale(10, granted, stale));
    try std.testing.expect(!lockIsStale(granted + stale - 1, granted, stale));
    try std.testing.expect(lockIsStale(granted + stale, granted, stale));
}
