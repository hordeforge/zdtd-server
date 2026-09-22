//! C2S misc domain: chat, player data / disconnect, dropped packages, game
//! events, quest entity spawns, console commands, damage, lock requests,
//! vehicles, attach, wire actions and turret spawns.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the join-SM arms otherwise.

const std = @import("std");
const misc_chat = @import("misc_chat.zig");
const misc_relay = @import("misc_relay.zig");
const misc_session = @import("misc_session.zig");
const misc_av = @import("misc_av.zig");
const misc_questequip = @import("misc_questequip.zig");
const misc_progress = @import("misc_progress.zig");
const misc_gameevent = @import("misc_gameevent.zig");
const misc_spawn = @import("misc_spawn.zig");
const misc_admin = @import("misc_admin.zig");
const misc_damage = @import("misc_damage.zig");
const misc_lock = @import("misc_lock.zig");
const misc_drop = @import("misc_drop.zig");
const protocol = @import("../../protocol.zig");
const replicate_te = @import("../game/replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");
const clock = @import("../../util/clock.zig");
const invsys = @import("../../ecs/inventory.zig");
const inv_apply = @import("../inv_apply.zig");
const components = @import("../../ecs/components.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_binary = @import("../../wire/binary.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const c2s_text = @import("../c2s_text.zig");
const packLockPos = game_mod.Game.packLockPos;
const firstLockTargetPos = game_mod.Game.firstLockTargetPos;
const logPersistErr = game_mod.logPersistErr;
const reverseItemType = game_mod.Game.reverseItemType;
const max_chat_msg_len = c2s_text.max_chat_msg_len;
const chatMsgOk = c2s_text.chatMsgOk;
const plugin_compose = @import("../game/plugin_compose.zig");

/// Honored-`fatal` kill amount vs NPC kinds. Lives in misc_damage.zig;
/// this alias keeps the name resolving for any out-of-tree caller.
const fatal_kill_amount = misc_damage.fatal_kill_amount;

/// Highest `WireActions` value NetPackageWireToolActions::ProcessPackage
/// (IL=254) acts on: the switch takes 0 (SetParent) and 1 (RemoveParent) and
/// returns for anything else, so a higher op never reaches its rebroadcast.
const wire_tool_max_op: u8 = 1;

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (try misc_chat.handleChat(self, c, peer, name, body)) return true;
    if (try misc_relay.handleRelay(self, c, peer, name, body)) return true;
    if (try misc_drop.handleDrop(self, c, peer, name, body)) return true;
    if (try misc_relay.handleAvatar(self, c, peer, name, body)) return true;
    if (try misc_session.handleSession(self, c, peer, name, body)) return true;
    if (try misc_av.handleAv(self, c, peer, name, body)) return true;
    if (try misc_questequip.handleQuestEquip(self, c, peer, name, body)) return true;
    if (try misc_progress.handleProgress(self, c, peer, name, body)) return true;
    if (try misc_gameevent.handleGameEvent(self, c, peer, name, body)) return true;
    if (try misc_spawn.handleSpawn(self, c, peer, name, body)) return true;
    if (try misc_admin.handleAdmin(self, c, peer, name, body)) return true;
    if (try misc_damage.handleDamage(self, c, peer, name, body)) return true;
    if (try misc_lock.handleLock(self, c, peer, name, body)) return true;
    // Accepted and dropped on purpose (phase-gated above, so this is a
    // deliberate no-op, not an unhandled package). Each is a documented
    // divergence in docs/DIVERGENCES.md; keep that list in sync when adding
    // one here.
    // - NetPackagePlayerStats: stock relays the owning client's own stats blob
    //   (EntityNetworkStats::ToEntity, RE progression.md 441560ff). Applying it
    //   would let a client author its level/XP/kill totals, so the server keeps
    //   its own ledger and sends that instead (AGENTS rule 17).
    // - NetPackageDiscordIdMappings: Discord rich-presence id map, a client
    //   social feature with no server-side sim effect.
    if (std.mem.eql(u8, name, "NetPackagePlayerStats") or std.mem.eql(u8, name, "NetPackageDiscordIdMappings")) {
        return true;
    }
    // Second accepted-and-dropped group; see the note above and
    // docs/DIVERGENCES.md.
    // - NetPackageBossEvent: client-side boss HUD banner, no sim effect.
    // - NetPackageEntityStatsBuff: stock applies the client's whole buff blob
    //   (EntityBuffs.Read IL=76). The server owns the buff set, so accepting it
    //   would let a client grant itself buffs (AGENTS rule 17). Known cost:
    //   client-local consume buffs never sync server-side, so the
    //   dysentery-dependent behaviours miss them - recorded in DIVERGENCES.md.
    // - NetPackagePlayerInventoryForAI: feeds stock's AIDirector smell/threat
    //   model from a client-reported bag (RE protocol-packages.md, Process
    //   IL=23). zdtd's AI reads its own sim state; a client must not be able to
    //   steer zombie targeting by declaring its inventory.
    // - NetPackageLobbyRegisterClient: matchmaking-lobby registration, which a
    //   self-hosted dedicated server does not participate in.
    if (std.mem.eql(u8, name, "NetPackageInventoryKeepOpen")) {
        // Stock NetPackageInventoryKeepOpen::ProcessPackage (IL=6) calls
        // LockManager.ProcessKeepOpen(sender.entityId) (IL=31): a player holding
        // a lock gets keepOpenTimes refreshed, and LockManager.Update (IL=128)
        // reaps only a stamp older than 10s. The stock client sends this every
        // 2.5s from its own LockManager.Update while a window is open (client
        // branch IL_0182). Dropping it let the stale reaper expire a live
        // window. The body is empty (read IL=1), so it refreshes a server-owned
        // timer and carries no client state.
        self.refreshLocksForPeer(c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageBossEvent") or std.mem.eql(u8, name, "NetPackageEntityStatsBuff") or std.mem.eql(u8, name, "NetPackagePlayerInventoryForAI") or std.mem.eql(u8, name, "NetPackageLobbyRegisterClient")) {
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageVehicleDataSync")) {
        // Real stock body (asm.il:844254); the opaque ReadSyncData payload
        // stays undecoded and is only relayed, as the stock server does.
        const s = packages.parseVehicleDataSync(body) catch return true;
        if (s.sender_id != c.entity_id) return true;
        const vi = self.sim.slotOfNetId(s.vehicle_id) orelse return true;
        if (!self.sim.mask[vi].vehicle) return true;
        if (self.sim.vehicle[vi].driverNetId() != c.entity_id) return true;
        try self.broadcastExcept("NetPackageVehicleDataSync", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageVehicleSpawn") and body.len == packages.vehicle_control_len) {
        const vc = packages.parseVehicleControl(body) catch return true;
        const vi = self.sim.slotOfNetId(vc.entity_id) orelse return true;
        if (!self.sim.mask[vi].vehicle) return true;
        switch (vc.op) {
            0 => try self.seatRider(c.entity_id, vi, systems.seat_any),
            1 => try self.unseatRider(c.entity_id),
            2 => {
                // Passengers do not steer: only seat 0 drives (asm.il:542176).
                if (self.sim.vehicle[vi].driverNetId() != c.entity_id) return true;
                systems.vehicleControl(&self.sim, vi, vc.throttle, vc.steer, 1.0 / @as(f32, @floatFromInt(protocol.ticks_per_second)));
            },
            else => {},
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityAttach")) {
        const a = packages.parseEntityAttach(body) catch return true;
        if (a.rider_id != c.entity_id) return true;
        // Types 0/2 are the server branch of NetPackageEntityAttach::
        // ProcessPackage (asm.il:844722); the server answers with 1/3 and
        // never echoes the client's own body, which would put every peer on
        // the server branch.
        if (packages.attachTypeIsDetach(a.attach_type)) {
            // Detach carries vehicleId = -1 (asm.il:406816): resolve the hull
            // from server state, never from the packet.
            try self.unseatRider(c.entity_id);
        } else {
            const vi = self.sim.slotOfNetId(a.vehicle_id) orelse return true;
            if (!self.sim.mask[vi].vehicle) return true;
            try self.seatRider(c.entity_id, vi, a.slot);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageWireActions")) {
        // Same rate gate as SetBlock: unthrottled would let a spam loop fan
        // this broadcast out to every other peer for free (bandwidth DoS).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Stock parent/child wiring (SetParent/RemoveParent) drives powered state.
        _ = self.sim.power.applyWireActionsStock(body);
        // Rebroadcast raw package so peers get the client-side wire visual.
        try self.broadcastExcept("NetPackageWireActions", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageWireToolActions")) {
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Tool handshake carries one endpoint + player: visual only, no graph
        // mutation (mirrors stock ProcessPackage re-Setup+SendPackage to peers).
        // read IL=13: currentOperation u8 | tileEntityPosition Vector3i |
        // entityID i32. ProcessPackage IL=254 opens with
        // ValidEntityIdForSender(entityID, false) and returns on failure, so a
        // body naming another player is dropped, not relayed. It also returns
        // for any operation outside {0,1} before reaching either SendPackage.
        const tool = packages.parseWireToolActions(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (tool.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        if (tool.operation > wire_tool_max_op) return true;
        try self.broadcastExcept("NetPackageWireToolActions", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityAnimationData")) {
        // Stock NetPackageEntityAnimationData (client-originated: the local
        // AvatarController broadcasts the avatar anim params; ProcessPackage
        // IL=64 re-Setups + relays to the other players). The server
        // re-broadcasts the raw body to the entity's tracked players, gated
        // on the sender's own entity id (the anim params describe its own
        // avatar). Same rate gate as the wire tool: an unthrottled spam loop
        // would fan a broadcast out to every other peer for free.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const anim = packages.parseAnimationData(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        if (anim.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        // Trim to the parsed body: the parameter list is variable length, so a
        // raw relay would forward whatever a peer appended.
        relayBodyExcept(self, "NetPackageEntityAnimationData", body[0..anim.wire_len], anim.entity_id, "EntityAnimationData");
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageTurretSpawn")) {
        if (body.len < 12) return true;
        // Stock's body is `entityType` i32 | pos Vector3 (3 x f32) | rot
        // Vector3 | ItemValue | `entityThatPlaced` i32 (RE
        // inventories/netpackage-bodies.md, write IL=24). zdtd also accepts a
        // compact 12-byte form of three i32 world coordinates for loadgen and
        // the scenarios. Reading the stock body as that compact form decoded
        // the float bit patterns as coordinates in the billions, which the
        // reach gate then rejected: a real client's turret never got placed.
        const stock = body.len >= 16;
        const x, const y, const z = if (stock) blk: {
            const fx: f32 = @bitCast(std.mem.readInt(u32, body[4..8], .little));
            const fy: f32 = @bitCast(std.mem.readInt(u32, body[8..12], .little));
            const fz: f32 = @bitCast(std.mem.readInt(u32, body[12..16], .little));
            if (!std.math.isFinite(fx) or !std.math.isFinite(fy) or !std.math.isFinite(fz)) return true;
            break :blk .{
                std.math.lossyCast(i32, @floor(fx)),
                std.math.lossyCast(i32, @floor(fy)),
                std.math.lossyCast(i32, @floor(fz)),
            };
        } else .{
            std.mem.readInt(i32, body[0..4], .little),
            std.mem.readInt(i32, body[4..8], .little),
            std.mem.readInt(i32, body[8..12], .little),
        };
        // Same rate gate as SetBlock: a spam loop must not plant turrets
        // faster than the bucket refills and drain the entity table.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Client-chosen coordinates: same reach + claim gate as SetBlock, so a
        // spam loop cannot plant turrets map-wide and drain the entity table.
        if (!self.placeAllowed(c, x, y, z)) return true;
        if (self.sim.spawnTurret(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z))) |tid| {
            if (self.sim.slotOfNetId(tid)) |ts| {
                self.sim.turret[ts].owner_slot = @intCast(c.slot);
                // The slot dies with the session; the name is what lets a
                // restart hand the turret back to whoever placed it.
                self.sim.turret[ts].setOwnerName(c.name[0..c.name_len]);
                var gi: ?u16 = null;
                var i: usize = 0;
                while (i < self.sim.power.node_n) : (i += 1) {
                    if (self.sim.power.nodes[i].kind == .generator) {
                        gi = self.sim.power.nodes[i].id;
                        break;
                    }
                }
                if (gi) |gid| {
                    _ = self.sim.power.connect(gid, self.sim.turret[ts].power_node);
                    self.sim.power.resolve();
                }
            }
        }
        return true;
    }
    return false;
}



/// Relay `body` verbatim to every joined client, including the sender
/// (stock GameMessageServer re-broadcasts to all peers, sender included).
fn relayBodyAll(self: *Game, pkg: []const u8, body: []const u8, label: []const u8) void {
    misc_relay.relayBodyAll(self, pkg, body, label);
}

/// Relay `body` verbatim to every joined client except `except_entity_id`'s
/// client (stock allButAttachedToEntityId fan-out); null relays to all.
fn relayBodyExcept(self: *Game, pkg: []const u8, body: []const u8, except_entity_id: ?i32, label: []const u8) void {
    misc_relay.relayBodyExcept(self, pkg, body, except_entity_id, label);
}

/// Native then Wasm chat filter chain. Lives in misc_chat.zig; this alias
/// keeps the name resolving for any out-of-tree caller.
const filteredChatText = misc_chat.filteredChatText;

/// Push the killer's AddScoreClient. Lives in misc_damage.zig; this alias
/// keeps the name resolving for any out-of-tree caller.
const sendScoreUpdate = misc_damage.sendScoreUpdate;
