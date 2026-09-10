//! Lock helpers extracted from game.zig - pack/unpack + slot bookkeeping.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const wire_binary = @import("../../wire/binary.zig");
const packages = @import("../../wire/packages.zig");

pub fn packLockPos(x: i32, y: i32, z: i32) u64 {
    const ux: u64 = @as(u32, @bitCast(x));
    const uy: u64 = @as(u32, @bitCast(y));
    const uz: u64 = @as(u32, @bitCast(z));
    return (ux & 0x1fffff) | ((uy & 0x1fffff) << 21) | ((uz & 0x1fffff) << 42);
}

pub const LockPos = struct { x: i32, y: i32, z: i32 };
pub fn firstLockTargetPos(targets_blob: []const u8) ?LockPos {
    if (targets_blob.len < 4) return null;
    var tr: wire_binary.Reader = .{ .data = targets_blob };
    const n = tr.readI32() catch return null;
    var ti: i32 = 0;
    while (ti < n) : (ti += 1) {
        const present = tr.readByte() catch return null;
        if (present == 0) continue;
        const ty = tr.readByte() catch return null;
        if (ty == 0 or ty == 1) {
            const x = tr.readI32() catch return null;
            const y = tr.readI32() catch return null;
            const z = tr.readI32() catch return null;
            return .{ .x = x, .y = y, .z = z };
        } else if (ty == 2) {
            _ = tr.readI32() catch return null;
        } else if (ty == 3) {
            if (tr.remaining() < 16) return null;
            tr.pos += 16;
        } else return null;
    }
    return null;
}

pub fn clearLockSlot(self: *Game, ch: usize) void {
    if (ch >= self.lock_channel.len) return;
    self.lock_channel[ch] = -1;
    self.lock_holder_entity[ch] = -1;
    self.lock_granted_ns[ch] = 0;
    self.lock_pos_key[ch] = 0;
}

/// `keep_ch` value meaning "release every channel this peer holds". Any index
/// past the table is out of range by construction, but naming it keeps the
/// intent at the call site instead of an unexplained `lock_channel.len`.
pub const keep_no_channel: usize = std.math.maxInt(usize);

/// Release the locks this peer holds on channels other than `keep_ch`, and tell
/// it. Stock's `LockRequestServer` gate 1 (IL=239, RE
/// dedicated-leftovers.md:134) force-unlocks a player's existing entry before
/// granting a new one, so a player holds one container at a time. The unlock
/// goes to the requesting peer (its UI still has the old window open); the
/// other clients learn the channel is free from the grant they are about to
/// see, and stock's own reply on this path is to the acting player.
pub fn releaseOtherLocksForPeer(self: *Game, peer_slot: usize, keep_ch: usize) void {
    const ps: i32 = @intCast(peer_slot);
    const peer = self.clients[peer_slot].peer orelse {
        for (&self.lock_channel, 0..) |*h, i| {
            if (i != keep_ch and h.* == ps) self.clearLockSlot(i);
        }
        return;
    };
    for (&self.lock_channel, 0..) |*h, i| {
        if (i == keep_ch or h.* != ps) continue;
        self.clearLockSlot(i);
        const body = packages.buildLockResponseForceUnlock(&self.body_buf, @intCast(i)) catch {
            self.harness.counters.inc(.encode_errors);
            continue;
        };
        self.sendGame(peer, "NetPackageLockResponse", body) catch {
            self.harness.counters.inc(.net_send_errors);
        };
    }
}

/// Release every lock held by a departing peer and tell the others. Clearing
/// server-side alone lets the next player open the container, but the clients
/// that watched it get locked are never told it opened again: stock sends the
/// force-unlock from `ForceUnlockByPlayer` (IL=11) on exactly this path (RE
/// dedicated-leftovers.md:167). The holder's own peer is gone, so this goes to
/// everyone else; `locking = false` routes the client to `UnlockResponse`,
/// which reads only success/errorMsg/isForceUnlocked and never the targets.
pub fn clearLocksForPeer(self: *Game, peer_slot: usize) void {
    const ps: i32 = @intCast(peer_slot);
    for (&self.lock_channel, 0..) |*h, i| {
        if (h.* != ps) continue;
        self.clearLockSlot(i);
        const body = packages.buildLockResponseForceUnlock(&self.body_buf, @intCast(i)) catch {
            self.harness.counters.inc(.encode_errors);
            continue;
        };
        self.broadcastExcept("NetPackageLockResponse", body, peer_slot) catch {};
    }
}
