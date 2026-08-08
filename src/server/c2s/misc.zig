//! C2S misc domain: chat, player data / disconnect, dropped packages, game
//! events, quest entity spawns, console commands, damage, lock requests,
//! vehicles, attach, wire actions and turret spawns.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the join-SM arms otherwise.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const replicate_te = @import("../replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");
const clock = @import("../../util/clock.zig");
const invsys = @import("../../ecs/inventory.zig");
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

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageChat") or std.mem.eql(u8, name, "NetPackageSimpleChat")) {
        if (!self.acceptChatRate(c)) return true;
        if (std.mem.eql(u8, name, "NetPackageChat")) {
            const ch = packages.parseStockChat(body) catch return true;
            if (!chatMsgOk(ch.msg)) return true;
            var chat_msg: []const u8 = ch.msg;
            var chat_buf: [c2s_text.max_chat_msg_len]u8 = undefined;
            var wasm_buf: [c2s_text.max_chat_msg_len]u8 = undefined;
            if (self.plugins.chatFilter(c.entity_id, ch.msg, &chat_buf)) |f| {
                if (f.len == 0) return true;
                if (!chatMsgOk(f)) return true;
                @memcpy(chat_buf[0..f.len], f[0..f.len]);
                chat_msg = chat_buf[0..f.len];
            } else if (self.wasm_plugins.chatFilter(c.entity_id, ch.msg, &wasm_buf)) |f| {
                if (f.len == 0) return true;
                if (!chatMsgOk(f)) return true;
                @memcpy(chat_buf[0..f.len], f[0..f.len]);
                chat_msg = chat_buf[0..f.len];
            }
            const stock = packages.buildStockChat(
                self.body_buf[0..512],
                ch.chat_type,
                c.entity_id,
                chat_msg,
                ch.recipients[0..ch.recipient_count],
            ) catch return true;
            if (ch.recipient_count > 0) {
                for (ch.recipients[0..ch.recipient_count]) |rid| {
                    if (rid == c.entity_id) continue;
                    if (self.clientByEntityId(rid)) |rc| {
                        if (rc.peer) |rpeer| {
                            self.sendGame(rpeer, "NetPackageChat", stock) catch |err| {
                                self.harness.counters.inc(.net_send_errors);
                                std.debug.print("zdtd: send chat failed: {s}\n", .{@errorName(err)});
                            };
                        }
                    }
                }
            } else {
                try self.broadcastExcept("NetPackageChat", stock, c.slot);
            }
        } else {
            var r: wire_binary.Reader = .{ .data = body };
            var from_buf: [64]u8 = undefined;
            var msg_buf: [max_chat_msg_len]u8 = undefined;
            const from = r.readString(&from_buf) catch "";
            var msg = r.readString(&msg_buf) catch return true;
            _ = from;
            if (!chatMsgOk(msg)) return true;
            var chat_msg: []const u8 = msg;
            var chat_buf2: [c2s_text.max_chat_msg_len]u8 = undefined;
            var wasm_buf2: [c2s_text.max_chat_msg_len]u8 = undefined;
            if (self.plugins.chatFilter(c.entity_id, msg, &chat_buf2)) |f| {
                if (f.len == 0) return true;
                if (!chatMsgOk(f)) return true;
                @memcpy(chat_buf2[0..f.len], f[0..f.len]);
                chat_msg = chat_buf2[0..f.len];
                msg = chat_msg;
            } else if (self.wasm_plugins.chatFilter(c.entity_id, msg, &wasm_buf2)) |f| {
                if (f.len == 0) return true;
                if (!chatMsgOk(f)) return true;
                @memcpy(chat_buf2[0..f.len], f[0..f.len]);
                chat_msg = chat_buf2[0..f.len];
                msg = chat_msg;
            } else {
                chat_msg = msg;
            }
            const stock = try packages.buildStockChat(self.body_buf[0..512], 0, c.entity_id, chat_msg, &.{});
            try self.broadcast("NetPackageChat", stock);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePlayerData")) {
        const ps = self.sim.playerByPeer(c.slot);
        if (ps) |slot| {
            if (self.sim.mask[slot].inventory) {
                if (packages.stock_inv.applyPlayerDataNetwork(body, &self.sim.inventory[slot], reverseItemType, self)) |h| {
                    self.clampInventoryStacks(&self.sim.inventory[slot]);
                    // Entity ids are minted by sim.spawnPlayer; a mismatch is
                    // a client claiming someone else's body, never adoption.
                    // Do NOT apply ECD pos either: client PDF pos is
                    // Unity-origin relative after Origin Reposition (y=0
                    // artifacts); PosAndRot is the world-space source of truth.
                    // Success path is silent (periodic PDF is normal). Mismatch
                    // is the operator-visible signal: counter + rate-limited log.
                    if (h.entity_id != c.entity_id) {
                        self.harness.counters.inc(.ownership_rejects);
                        const n = self.harness.counters.get(.ownership_rejects);
                        if (n == 1 or n % 100 == 0) {
                            std.debug.print(
                                "zdtd: PlayerData ownership reject n={d} claimed={d} expected={d} local_id={d}\n",
                                .{ n, h.entity_id, c.entity_id, peer.local_id },
                            );
                        }
                    }
                } else |_| {
                    // Fall back to ECD head only. Parse-skip is rare; log once per 100
                    // decode rejects so a broken client is visible without per-packet noise.
                    if (packages.parsePlayerDataEcdHead(body)) |h| {
                        _ = h; // pos unreliable (origin-relative); ignore
                    } else |_| {
                        self.harness.counters.inc(.decode_rejects);
                        const n = self.harness.counters.get(.decode_rejects);
                        if (n == 1 or n % 100 == 0) {
                            std.debug.print(
                                "zdtd: PlayerData parse skip n={d} body_len={d} local_id={d}\n",
                                .{ n, body.len, peer.local_id },
                            );
                        }
                    }
                }
            }
        } else if (packages.parsePlayerDataEcdHead(body)) |h| {
            _ = h; // pos unreliable (origin-relative); ignore
        } else |_| {}
        // Defer file write to the periodic save tick (no open/rewrite per packet).
        self.players_dirty = true;
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackagePlayerDisconnect")) {
        // Stock quit signal (extends PlayerData: entity id, netpackages.md).
        // Take the same removal path as the transport peer-death poll, but
        // immediately and after saving, so a quit is never lost to the
        // autosave interval. Accept only the sender's own entity.
        if (body.len >= 4) {
            const eid = std.mem.readInt(i32, body[0..4], .little);
            if (eid != c.entity_id) return true;
        }
        self.savePlayers() catch |e| logPersistErr(self, "save players", e);
        self.dropClientSlot(c.slot, "quit");
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageAudio") or std.mem.eql(u8, name, "NetPackagePlayerStats") or std.mem.eql(u8, name, "NetPackageDiscordIdMappings")) {
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageBossEvent") or std.mem.eql(u8, name, "NetPackageEntityStatsBuff") or std.mem.eql(u8, name, "NetPackagePlayerEquipment") or std.mem.eql(u8, name, "NetPackageInventoryKeepOpen") or std.mem.eql(u8, name, "NetPackagePlayerInventoryForAI") or std.mem.eql(u8, name, "NetPackageLobbyRegisterClient") or std.mem.eql(u8, name, "NetPackageMapPosition") or std.mem.eql(u8, name, "NetPackagePlayerQuestPositions")) {
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityAddScoreServer") or std.mem.eql(u8, name, "NetPackageEntityAddExpServer") or std.mem.eql(u8, name, "NetPackageEntitySetSkillLevelServer")) {
        // No server-side skill sim yet; the client tracks its own progress.
        // Ack silently (dir=1, client-authoritative XP under EAC-off).
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageGameEventRequest")) {
        if (packages.buildGameEventResponse(&self.body_buf, body)) |resp| {
            self.sendGame(peer, "NetPackageGameEventResponse", resp) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                std.debug.print(
                    "zdtd: GameEventResponse send failed slot={d}: {s}\n",
                    .{ c.slot, @errorName(err) },
                );
            };
        } else |err| {
            self.harness.counters.inc(.encode_errors);
            std.debug.print(
                "zdtd: GameEventResponse encode failed slot={d}: {s}\n",
                .{ c.slot, @errorName(err) },
            );
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageQuestEntitySpawn")) {
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        var r: wire_binary.Reader = .{ .data = body };
        _ = r.readI32() catch return true; // player entity id
        var gname: [64]u8 = undefined;
        _ = r.readString(&gname) catch return true;
        const cnt = r.readI32() catch 1;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].journal or !self.sim.journal[ps].anyActive()) {
            self.harness.counters.inc(.c2s_rejects);
            return true;
        }
        const t = self.sim.transform[ps];
        const zdef = self.entities.defaultZombie();
        var k: i32 = 0;
        while (k < cnt and k < 8) : (k += 1) {
            const ang = @as(f32, @floatFromInt(k)) * 1.4;
            // Stop at the entity cap instead of spinning on null spawns.
            if (self.sim.spawnZombieClass(t.x + @cos(ang) * 6, t.y, t.z + @sin(ang) * 6, zdef.max_hp, zdef.hash, zdef.loot_list) == null) break;
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageRequestToSpawnEntity")) {
        // The generic ECD request does not prove item ownership or a legal
        // spawn class. Typed drop/throw paths must validate and consume the
        // corresponding server-side inventory first.
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageConsoleCmdServer")) {
        self.handleConsoleCmd(peer, c, body) catch |err| {
            std.debug.print(
                "zdtd: console cmd failed slot={d}: {s}\n",
                .{ c.slot, @errorName(err) },
            );
        };
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEditorAddVolumeFromClient")) {
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageDamageEntity")) {
        const d = packages.parseDamageHead(body) catch return true;
        if (self.quarantineDenies(c, .damage)) return true;
        if (!self.takeDamageToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Damage is a client claim, so require both actor and target to be
        // in the server's current interest range. This blocks forged net
        // ids from damaging players or AI elsewhere in the world.
        const actor_slot = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.alive[actor_slot] or self.sim.health[actor_slot].hp <= 0) {
            self.harness.counters.inc(.bounds_rejects);
            self.noteEvidence(c, peer.local_id, d.entity_id, .bounds, .strong, .damage, 0, 1);
            return true;
        }
        const target_slot = self.sim.slotOfNetId(d.entity_id) orelse return true;
        if (!self.sim.alive[target_slot]) {
            self.harness.counters.inc(.bounds_rejects);
            self.noteEvidence(c, peer.local_id, d.entity_id, .bounds, .strong, .damage, 0, 1);
            return true;
        }
        if (!self.sim.mask[actor_slot].transform or !self.sim.mask[target_slot].transform) return true;
        const actor_pos = self.sim.transform[actor_slot];
        const target_pos = self.sim.transform[target_slot];
        const damage_dx = target_pos.x - actor_pos.x;
        const damage_dy = target_pos.y - actor_pos.y;
        const damage_dz = target_pos.z - actor_pos.z;
        const damage_d2 = damage_dx * damage_dx + damage_dy * damage_dy + damage_dz * damage_dz;
        if (damage_d2 > self.interest_range * self.interest_range) {
            self.harness.counters.inc(.bounds_rejects);
            self.noteEvidence(c, peer.local_id, d.entity_id, .bounds, .strong, .damage, @sqrt(damage_d2), self.interest_range);
            return true;
        }
        const was_zombie = blk: {
            break :blk self.sim.kind[target_slot] == .zombie or self.sim.kind[target_slot] == .animal;
        };
        // Client strength is a claim: cap it, and honor `fatal` only against
        // NPC kinds (a spoofed fatal must not one-shot another player).
        var amount: f32 = @floatFromInt(@min(d.strength, self.max_claimed_damage));
        if (d.fatal and was_zombie) amount = 9999;
        // PvP gate + armor mitigation when damaging a player.
        if (self.sim.slotOfNetId(d.entity_id)) |ei| {
            if (self.sim.mask[ei].player and self.sim.player[ei].peer_slot >= 0) {
                // PlayerKillingMode 0 = no PvP: drop player-to-player damage.
                if (self.pvp_mode == 0 and self.sim.player[ei].peer_slot != @as(i32, @intCast(c.slot)))
                    return true;
                const mit = invsys.armorMitigation(&self.sim, @intCast(self.sim.player[ei].peer_slot));
                amount *= (1.0 - mit);
            }
        }
        // Attribute the hit: stock's NetPackageDamageEntity carries
        // attackerEntityId (::read, asm.il:810693) and EAISetAsTargetIfHurt
        // turns it into the victim's attack target. The actor is already
        // validated above, so use its net id rather than the claimed field.
        const dmg = self.sim.damageFrom(d.entity_id, amount, self.sim.network_id[actor_slot].id);
        if (dmg.killed) {
            // Dead players keep the entity (client runs its own death →
            // respawn flow); EntityRemove would delete the local player.
            const target_is_player = blk: {
                if (self.sim.slotOfNetId(d.entity_id)) |ti|
                    break :blk self.sim.mask[ti].player;
                break :blk false;
            };
            if (!target_is_player) {
                // Corpse dwell (EntityAlive::OnDeathUpdate): the body stays
                // in world for TimeStayAfterDeath (30 s zombies, 300 s
                // animals) so the client's ragdoll is not yanked mid
                // animation; the tick sweep broadcasts EntityRemove when
                // the dwell expires. The loot bag below still spawns now.
            } else {
                // DropOnDeath: 0 nothing, 1 all, 2 toolbelt, 3 backpack, 4 delete.
                // Modes 1..3 drop a loot bag at the death position; 0/4 drop nothing.
                if (self.drop_on_death >= 1 and self.drop_on_death <= 3) {
                    if (self.sim.slotOfNetId(d.entity_id)) |ti| {
                        const t = self.sim.transform[ti];
                        if (self.sim.spawnLootBag(t.x, t.y, t.z, 1, 1)) |bag_nid| {
                            self.broadcastLootSpawn(bag_nid) catch {};
                        }
                    }
                }
            }
            if (was_zombie) {
                systems.questOnZombieKilled(&self.sim, c.slot);
                systems.questOnFetchItem(&self.sim, c.slot, 1);
                // XPMultiplier + party split: award scaled server-side XP for
                // the kill, sharing it with in-range party mates (§2.3).
                self.killXpAward(c.slot, 100);
            }
            // Stock DroppedLootContainer ECD + bag; refill from loot.xml when known.
            if (dmg.loot_bag_id > 0) {
                self.fillLootBagFromTable(dmg.loot_bag_id, dmg.loot_list, @intCast(d.entity_id), self.lootStageForPlayer(c.slot));
                try self.broadcastLootSpawn(dmg.loot_bag_id);
            }
        }
        return true;
    }
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
            // Same TE already locked on another channel by someone else → deny.
            if (req.locking and pos_key != 0) {
                for (self.lock_pos_key, 0..) |pk, oi| {
                    if (oi == ch) continue;
                    if (pk != pos_key) continue;
                    const oh = self.lock_channel[oi];
                    if (oh >= 0 and oh != @as(i32, @intCast(c.slot))) {
                        const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "locked");
                        try self.sendGame(peer, "NetPackageLockResponse", resp);
                        return true;
                    }
                }
            }
            if (req.locking) {
                const holder = self.lock_channel[ch];
                if (holder >= 0 and holder != @as(i32, @intCast(c.slot))) {
                    const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "locked");
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
                    return true;
                }
                self.lock_channel[ch] = @intCast(c.slot);
                self.lock_holder_entity[ch] = c.entity_id;
                self.lock_granted_ns[ch] = clock.monoNs();
                self.lock_pos_key[ch] = pos_key;
                // Trader open: the LockResponse context carries server TraderData
                // (stock serializes EntityTraderLockContext into the response;
                // NetPackageTraderData is ToServer-only). Detect an entity target
                // whose slot is a trader and build that context.
                var trader_slot: ?ecs.Slot = null;
                var vending_pos: ?vending_mod.PosKey = null;
                if (req.targets_blob.len >= 4) {
                    var tr: wire_binary.Reader = .{ .data = req.targets_blob };
                    const n = tr.readI32() catch 0;
                    var ti: i32 = 0;
                    while (ti < n) : (ti += 1) {
                        const present = tr.readByte() catch break;
                        if (present == 0) continue;
                        const ty = tr.readByte() catch break;
                        if (ty == 2) {
                            const eid = tr.readI32() catch break;
                            if (self.sim.slotOfNetId(eid)) |ts| {
                                if (self.sim.mask[ts].kind and self.sim.kind[ts] == .trader) {
                                    trader_slot = ts;
                                    break;
                                }
                            }
                        } else if (ty == 0 or ty == 1) {
                            const tx = tr.readI32() catch break;
                            const tty = tr.readI32() catch break;
                            const tz = tr.readI32() catch break;
                            if (ty == 1) tr.skipString() catch {};
                            // TileEntity lock target (type 0): a vending block
                            // under the position opens as a vending machine.
                            if (self.vending.get(.{ .x = tx, .y = tty, .z = tz }) != null) {
                                vending_pos = .{ .x = tx, .y = tty, .z = tz };
                            }
                        } else if (ty == 3) {
                            if (tr.remaining() < 16) break;
                            tr.pos += 16;
                        } else break;
                    }
                }
                if (trader_slot) |ts| {
                    // Stock EntityTrader opens the window only inside the
                    // trader_info open hours (vending machines and traders
                    // without hours are always open). Deny outside them.
                    if (!self.traderIsOpen(ts)) {
                        const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "closed");
                        try self.sendGame(peer, "NetPackageLockResponse", resp);
                        return true;
                    }
                    var ent_buf: [16]packages.TraderStockEntry = undefined;
                    const n = self.stockEntries(ts, &ent_buf);
                    const resp = try packages.buildLockResponseTrader(&self.body_buf, req, .{
                        .trader_id = self.sim.network_id[ts].id,
                        .available_money = self.traderMoney(ts),
                        .entries = ent_buf[0..n],
                    });
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
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
                // Target blob: i32 count | (present, type, …)*
                if (req.targets_blob.len >= 4) {
                    var tr: wire_binary.Reader = .{ .data = req.targets_blob };
                    const n = tr.readI32() catch 0;
                    var ti: i32 = 0;
                    while (ti < n) : (ti += 1) {
                        const present = tr.readByte() catch break;
                        if (present == 0) continue;
                        const ty = tr.readByte() catch break;
                        if (ty == 0 or ty == 1) {
                            const x = tr.readI32() catch break;
                            const y = tr.readI32() catch break;
                            const z = tr.readI32() catch break;
                            if (ty == 1) tr.skipString() catch {};
                            try replicate_te.sendStorageTe(self, peer, x, y, z);
                            try replicate_te.sendWorkstationTe(self, peer, x, y, z);
                            try replicate_te.sendVendingTe(self, peer, x, y, z);
                        } else if (ty == 2) {
                            _ = tr.readI32() catch break;
                        } else if (ty == 3) {
                            if (tr.remaining() < 16) break;
                            tr.pos += 16;
                        } else break;
                    }
                }
            } else {
                // Unlock only if we hold the channel (or free).
                if (self.lock_channel[ch] == @as(i32, @intCast(c.slot)) or self.lock_channel[ch] < 0) {
                    self.clearLockSlot(ch);
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
        // Stock parent/child wiring (SetParent/RemoveParent) drives powered state.
        _ = self.sim.power.applyWireActionsStock(body);
        // Rebroadcast raw package so peers get the client-side wire visual.
        try self.broadcastExcept("NetPackageWireActions", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageWireToolActions")) {
        // Tool handshake carries one endpoint + player: visual only, no graph
        // mutation (mirrors stock ProcessPackage re-Setup+SendPackage to peers).
        try self.broadcastExcept("NetPackageWireToolActions", body, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageTurretSpawn")) {
        if (body.len < 12) return true;
        const x = std.mem.readInt(i32, body[0..4], .little);
        const y = std.mem.readInt(i32, body[4..8], .little);
        const z = std.mem.readInt(i32, body[8..12], .little);
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
            var gi: ?u16 = null;
            var i: usize = 0;
            while (i < self.sim.power.node_n) : (i += 1) {
                if (self.sim.power.nodes[i].kind == .generator) {
                    gi = self.sim.power.nodes[i].id;
                    break;
                }
            }
            if (gi) |gid| {
                if (self.sim.slotOfNetId(tid)) |ts| {
                    _ = self.sim.power.connect(gid, self.sim.turret[ts].power_node);
                    self.sim.power.resolve();
                }
            }
        }
        return true;
    }
    return false;
}
