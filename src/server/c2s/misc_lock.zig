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

/// Type 3 lock-target payload: opaque 16 bytes to stock (RE netpackage-bodies.md).
const lock_target_opaque_len: usize = 16;

/// One NetPackageLockRequest target entry, decoded in stock blob order
/// (i32 count | (u8 present, u8 type, ...)* per entry).
const LockTarget = union(enum) {
    /// Type 0 block pos / type 1 prefab pos (prefab name already skipped).
    pos: [3]i32,
    /// Type 2 entity id.
    entity_id: i32,
    /// Type 3 opaque payload, already skipped.
    opaque16,
    /// present == 0: empty slot, no payload.
    empty,
};

/// Decode one target entry. null ends the walk: truncated entry or unknown
/// type. Stock aborts the package read there, so the reader position is
/// untrustworthy past that point and callers must stop.
fn nextLockTarget(r: *wire_binary.Reader) ?LockTarget {
    if ((r.readByte() catch return null) == 0) return .empty;
    const ty = r.readByte() catch return null;
    switch (ty) {
        0, 1 => {
            const x = r.readI32() catch return null;
            const y = r.readI32() catch return null;
            const z = r.readI32() catch return null;
            if (ty == 1) r.skipString() catch return null;
            return .{ .pos = .{ x, y, z } };
        },
        2 => return .{ .entity_id = r.readI32() catch return null },
        3 => {
            if (r.remaining() < lock_target_opaque_len) return null;
            r.pos += lock_target_opaque_len;
            return .opaque16;
        },
        else => return null,
    }
}

/// True when `name` is a lock package and was handled.
pub fn handleLock(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageLockRequest")) {
        if (packages.parseLockRequest(body)) |req| {
            // Deny acquiring a container lock while quarantined; always let
            // an unlock through so a quarantined peer cannot pin a channel.
            if (req.locking and self.quarantineDenies(c, .container)) return true;
            const ch: usize = @min(@as(usize, req.channel), self.lock_channel.len - 1);
            // Stale holder on this channel before grant check.
            if (self.lock_channel[ch] >= 0 and self.lock_granted_ns[ch] != 0) {
                const now = clock.monoNs();
                if (now -% self.lock_granted_ns[ch] >= self.lock_stale_ns) self.clearLockSlot(ch);
            }
            const pos_key: u64 = if (firstLockTargetPos(req.targets_blob)) |p|
                packLockPos(p.x, p.y, p.z)
            else
                0;
            if (req.locking) {
                // Gate 1 (IL=239): any existing entry for this player is invalid
                // state. Stock force-unlocks everything the player holds and
                // returns without granting the new request (the ret at IL_0067).
                // The RE prose said "then continue"; the IL is the authority and
                // says otherwise.
                if (self.peerHoldsLock(c.slot)) {
                    self.releaseAllLocksForPeer(c.slot);
                    return true;
                }
                // Gate 2 (IL=239): reject null targets and a span longer than 5.
                // The refusal still replies: stock sets errorMsg and falls
                // through to a NetPackageLockResponse with success=false
                // (IL_0263), so the client's pending lock resolves instead of
                // hanging on a body that was silently dropped here.
                if (req.has_null_target or req.target_count > packages.max_lock_targets_declared) {
                    const msg = if (req.has_null_target) "null target" else "too many targets";
                    const resp = try packages.buildLockResponseDeny(&self.body_buf, req, msg);
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
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
                                if (self.sim.mask[ts].kind and self.sim.kind[ts] == .trader) {
                                    trader_slot = ts;
                                    break;
                                }
                            },
                            .pos => |p| {
                                // TileEntity lock target (type 0): a vending block
                                // under the position opens as a vending machine.
                                if (self.vending.get(.{ .x = p[0], .y = p[1], .z = p[2] }) != null) {
                                    vending_pos = .{ .x = p[0], .y = p[1], .z = p[2] };
                                }
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
                        try self.sendGame(peer, "NetPackageLockResponse", resp);
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
                            try self.sendGame(peer, "NetPackageLockResponse", resp);
                            return true;
                        }
                    }
                }
                if (self.lock_channel[ch] >= 0) {
                    const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "locked");
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
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
                    systems.questOnTraderOpen(&self.sim, c.slot);
                    var ent_buf: [50]packages.TraderStockEntry = undefined;
                    const n = self.stockEntries(ts, &ent_buf);
                    const resp = try packages.buildLockResponseTrader(&self.body_buf, req, .{
                        // TraderID indexes traders.xml; entity id leaves TraderInfo null.
                        .trader_id = self.sim.trader_stock[ts].trader_info_id,
                        .available_money = self.traderMoney(ts),
                        .entries = ent_buf[0..n],
                    });
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
                    // Wasm-first: the window-open announcement rides a plugin
                    // (kind 0 = trader open), not native code.
                    plugin_compose.traderEvent(self, c.entity_id, self.sim.network_id[ts].id, 0);
                } else if (vending_pos) |vp| {
                    // Vending machines are always open (trader_info has no
                    // hours). The LockResponse carries the machine's
                    // TraderData under the request's VendingMachineLockContext
                    // type name; the client opens the trader window from it.
                    const v = self.vending.get(vp) orelse return true;
                    if (v.stock_n == 0) replicate_te.fillVendingStore(self, v);
                    var vent_buf: [vending_mod.max_vending_stock]packages.TraderStockEntry = undefined;
                    const vn = replicate_te.vendingEntries(self, v, &vent_buf);
                    const resp = try packages.buildLockResponseTrader(&self.body_buf, req, .{
                        .trader_id = v.trader_id,
                        .available_money = v.available_money,
                        .entries = vent_buf[0..vn],
                    });
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
                    try replicate_te.sendVendingTe(self, peer, vp.x, vp.y, vp.z);
                } else {
                    const resp = try packages.buildLockResponseGrant(&self.body_buf, req);
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
                }
                // Re-push TE for any storage container near the first TEFeature target.
                if (req.targets_blob.len >= 4) {
                    var tr: wire_binary.Reader = .{ .data = req.targets_blob };
                    const n = tr.readI32() catch 0;
                    var ti: i32 = 0;
                    while (ti < n) : (ti += 1) {
                        switch (nextLockTarget(&tr) orelse break) {
                            .pos => |p| {
                                try replicate_te.sendStorageTe(self, peer, p[0], p[1], p[2]);
                                try replicate_te.sendWorkstationTe(self, peer, p[0], p[1], p[2]);
                                try replicate_te.sendVendingTe(self, peer, p[0], p[1], p[2]);
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
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
                } else {
                    const resp = try packages.buildLockResponseUnlock(&self.body_buf, false);
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
                }
            }
        } else |_| {
            std.debug.print("zdtd: LockRequest parse fail body={d}\n", .{body.len});
        }
        return true;
    }
    return false;
}
