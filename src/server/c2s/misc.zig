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

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageChat") or std.mem.eql(u8, name, "NetPackageSimpleChat")) {
        if (!self.acceptChatRate(c)) return true;
        if (std.mem.eql(u8, name, "NetPackageChat")) {
            const ch = packages.parseStockChat(body) catch return true;
            if (!chatMsgOk(ch.msg)) return true;
            var chat_buf: [c2s_text.max_chat_msg_len]u8 = undefined;
            var wasm_buf: [c2s_text.max_chat_msg_len]u8 = undefined;
            const chat_msg = filteredChatText(self, c, ch.msg, &chat_buf, &wasm_buf) orelse return true;
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
            // Sender name: read to advance the reader, then discard.
            _ = r.readString(&from_buf) catch "";
            const msg = r.readString(&msg_buf) catch return true;
            if (!chatMsgOk(msg)) return true;
            var chat_buf2: [c2s_text.max_chat_msg_len]u8 = undefined;
            var wasm_buf2: [c2s_text.max_chat_msg_len]u8 = undefined;
            const chat_msg = filteredChatText(self, c, msg, &chat_buf2, &wasm_buf2) orelse return true;
            const stock = try packages.buildStockChat(self.body_buf[0..512], 0, c.entity_id, chat_msg, &.{});
            try self.broadcast("NetPackageChat", stock);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageGameMessage")) {
        // Stock NetPackageGameMessage (write IL=17): msgType u8
        // (EnumGameMessages PlainTextLocal=0/EntityWasKilled=1/JoinedGame=2/
        // LeftGame=3/ChangedTeam=4/Chat=5), mainEntityId i32,
        // secondaryEntityId i32. GameManager.GameMessageServer ->
        // FinishGameMessageServer (IL=69) re-broadcasts the Setup body to
        // every client with an unfiltered SendPackage, and the remote
        // client's ProcessPackage displays it (DisplayGameMessage), so the
        // sender receives its own message back too. The verbatim relay is
        // byte-identical to the stock rebuild; the client sends these for
        // EntityAlive.OnEntityDeath (isGameMessageOnDeath), team changes and
        // disconnect (LeftGame), and chat-form announcements.
        if (body.len < 9) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        relayBodyAll(self,"NetPackageGameMessage", body, "GameMessage");
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageSoundAtPosition")) {
        // Stock NetPackageSoundAtPosition (write IL=25): pos 3xf32 | clip
        // string | mode u8 | distance i32 | entityId i32 | volumeScale f32.
        // GameManager.PlaySoundAtPositionServer (IL=60, dedicated branch)
        // re-broadcasts the Setup body with allButAttachedToEntityId =
        // entityId, so every client except the owning player hears the sound
        // (the owner already played it locally); the distance field drives
        // the receiving client's rolloff, not the fan-out. Verbatim relay
        // excludes that entity's client, like stock.
        const snd = packages.parseSoundAtPosition(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        relayBodyExcept(self,"NetPackageSoundAtPosition", body, snd.entity_id, "SoundAtPosition");
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageParticleEffect")) {
        // Stock NetPackageParticleEffect (write IL=20): ParticleEffect.Write
        // (ParticleId, pos, rot, color32, two sound strings, volumeScale)
        // then entityThatCausedIt i32, forceCreation bool, worldSpawn bool.
        // GameManager.SpawnParticleEffectServer (IL=41, dedicated branch)
        // re-broadcasts the Setup body with allButAttachedToEntityId =
        // entityThatCausedIt, so every client except the causing entity's
        // owner sees the effect (the owner already spawned it locally).
        // Verbatim relay excludes that entity's client, like stock.
        const pe = packages.parseParticleEffectInvoke(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        relayBodyExcept(self,"NetPackageParticleEffect", body, pe.entity_caused, "ParticleEffect");
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityStealth")) {
        // Stock NetPackageEntityStealth (read IL=9): id i32, six u16 stealth
        // flags, data u16, cSmellRadiusMin i32 - the client reports its
        // stealth state for AI detection (crouch/smell/eating/sheltered/
        // alert). zdtd computes stealth server-side (the crouch flag rides the
        // movement frames and the AI senses row derives smell from buffs), so
        // the report is a redundant echo: validate the body and drop.
        if (body.len < 20) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityPhysics")) {
        // Stock NetPackageEntityPhysics (read IL=74): cFlagIsMaster u16,
        // cFlagIsCollided u16, cFlagOnGround u16, EntityId i32, Pos 3xf32,
        // QRot 4xf32, Velocity 3xf32, AngularVelocity 3xf32, Flags u16. The
        // entity's physics master reports pos/rot/velocity so the server
        // mirrors it (ProcessPackage gates on isPhysicsMaster). zdtd's
        // movement, falling-block and vehicle sims are server-authoritative
        // (broadcast PosAndRot / VehiclePositions / EntityVelocity), so the
        // report is a redundant echo: validate the body and drop.
        if (body.len < 70) {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityRagdoll")) {
        // Stock NetPackageEntityRagdoll (write IL=59): entityId i32, flags
        // u8, then conditionally (flags&1) duration/bodyPart/three vectors,
        // (flags&2) mode, (flags&4) state. The owner's client forces the
        // local ragdoll (EntityBuffs buff trigger / EModelBase.DoRagdoll);
        // the server re-broadcasts to the entity's tracked players
        // (SendPacketToTrackedPlayersAndTrackedEntity), so a verbatim relay
        // to the other clients matches stock - the owner already ragdolled.
        const rg = packages.parseRagdollInvoke(body) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        // Owner already ragdolled (SendPacketToTrackedPlayersAndTrackedEntity).
        relayBodyExcept(self,"NetPackageEntityRagdoll", body, rg.entity_id, "EntityRagdoll");
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
        // Stock quit signal (extends PlayerData: entity id, protocol-packages.md
        // NetPackagePlayerDisconnect).
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
    if (std.mem.eql(u8, name, "NetPackageMapPosition")) {
        // In-game minimap drive (RE protocol-packages.md §3.3): the client
        // sends its map middle (entityId + Vector2i); the server fills the
        // 17x17 chunk window around it with NetPackageMapChunks. Accept only
        // the sender's own entity; a moved middle resets the sent set.
        if (body.len >= 12) {
            const eid = std.mem.readInt(i32, body[0..4], .little);
            if (eid != c.entity_id) return true;
            const mx = std.mem.readInt(i32, body[4..8], .little);
            const mz = std.mem.readInt(i32, body[8..12], .little);
            if (!c.map_middle_set or c.map_middle_x != mx or c.map_middle_z != mz) {
                c.map_middle_x = mx;
                c.map_middle_z = mz;
                c.map_middle_set = true;
                @memset(&c.map_chunks_sent, 0);
            }
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageBossEvent") or std.mem.eql(u8, name, "NetPackageEntityStatsBuff") or std.mem.eql(u8, name, "NetPackagePlayerEquipment") or std.mem.eql(u8, name, "NetPackageInventoryKeepOpen") or std.mem.eql(u8, name, "NetPackagePlayerInventoryForAI") or std.mem.eql(u8, name, "NetPackageLobbyRegisterClient") or std.mem.eql(u8, name, "NetPackagePlayerQuestPositions")) {
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntityAddScoreServer") or std.mem.eql(u8, name, "NetPackageEntityAddExpServer")) {
        // No server-side skill sim for these yet; ack silently.
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageEntitySetSkillLevelServer")) {
        // ADR 0023 ledger: the client requests one skill purchase. Body
        // (sender-addressed, inherited serialization): skill string | level
        // i32 (RE netpackage-bodies.md). Server-validated; echoes the Client
        // package on success.
        var r = wire_binary.Reader{ .data = body };
        var skill_buf: [128]u8 = undefined;
        const skill = r.readString(&skill_buf) catch return true;
        const level = r.readI32() catch return true;
        if (skill.len == 0 or level < 1 or level > 255) return true;
        // Wasm-first (AGENTS rule 29, ADR 0033): the on_perk_spend verdict
        // gates/customizes spending on top of the catalog validation - <0
        // denies the spend, 0 keeps, >0 scales the skill-point cost by
        // percent. The stat deltas stay native (the passive-effects VM).
        const cost = self.skillCostOf(c.slot, skill, @intCast(level)) orelse return true;
        const verdict = self.perkSpendVerdict(c.entity_id, skill, level, @intCast(@min(cost, std.math.maxInt(i32))));
        var eff_cost: ?u32 = null;
        if (verdict < 0) return true;
        if (verdict > 0) {
            const scaled: u64 = @as(u64, cost) * @as(u64, @intCast(verdict)) / 100;
            eff_cost = @intCast(@max(1, @min(scaled, std.math.maxInt(u32))));
        }
        if (!self.purchaseSkillAtCost(c.slot, skill, @intCast(level), eff_cost)) return true;
        if (c.entity_id > 0) {
            if (packages.stock_xp.buildEntitySetSkillLevelBody(&self.body_buf, c.entity_id, skill, level)) |sb| {
                self.sendGame(peer, "NetPackageEntitySetSkillLevelClient", sb) catch {};
            } else |_| {}
        }
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
        const zclass = self.entityClassOf(zdef);
        var k: i32 = 0;
        while (k < cnt and k < 8) : (k += 1) {
            const ang = @as(f32, @floatFromInt(k)) * 1.4;
            // Stop at the entity cap instead of spinning on null spawns.
            // A35: spawn the full resolved class so the quest summons carry stats.
            if (self.sim.spawnZombieDef(t.x + @cos(ang) * 6, t.y, t.z + @sin(ang) * 6, zdef.max_hp, zclass) == null) break;
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
        const target_slot = if (self.sim.slotOfNetId(d.entity_id)) |ts| ts else {
            // Host-side bot target (ADR 0026): bots are not ECS slots, so the
            // ECS damage path cannot see them. Players may fight bots with the
            // same trust gates as ECS targets: the actor is validated above,
            // the claimed strength is capped, and a forged far-away id is
            // range-gated to interest. No PvP gate (bots are NPCs), no armor
            // mitigation, and no `fatal` honor (same as players).
            if (self.bots.find(d.entity_id)) |bs| {
                const b = &self.bots.bots[bs];
                if (!self.sim.mask[actor_slot].transform) return true;
                const ap = self.sim.transform[actor_slot];
                const bdx = b.x - ap.x;
                const bdz = b.z - ap.z;
                if (bdx * bdx + bdz * bdz > self.interest_range * self.interest_range) {
                    self.harness.counters.inc(.bounds_rejects);
                    return true;
                }
                const bamount: f32 = @floatFromInt(@min(d.strength, self.max_claimed_damage));
                // Attributed damage: the guest sees the event in its next sense
                // pass and retaliates (clanker OnDamaged parity). Death / knock-
                // back / unspawn: BotManager owns hp; the replicate pass
                // unspawns dead bots and the population floor self-heals.
                _ = self.bots.damageFrom(d.entity_id, bamount, self.sim.network_id[actor_slot].id);
            }
            return true;
        };
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
        const was_zombie = self.sim.kind[target_slot] == .zombie or self.sim.kind[target_slot] == .animal;
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
                // Armor mitigation, less the attacker's held-item TargetArmor
                // penetration (RE GetTotalPhysicalArmorRating IL=47).
                const mit = invsys.armorMitigationVs(&self.sim, @intCast(self.sim.player[ei].peer_slot), actor_slot);
                amount *= (1.0 - mit);
            }
        }
        // Wasm-first (AGENTS rule 29): damage directed at a player passes the
        // on_player_damage plugin verdict after the native gate, so plugins
        // express PvP/friendly-fire and damage-scaling policy. <0 deny, 0
        // keep, >0 scale by percent. The native pvp_mode floor still wins.
        if (self.sim.slotOfNetId(d.entity_id)) |ei| {
            if (self.sim.mask[ei].player) {
                const atk = self.sim.network_id[actor_slot].id;
                const sv = self.plugins.playerDamage(atk, d.entity_id, @intFromFloat(amount));
                const v = if (sv != 0) sv else self.wasm_plugins.playerDamage(atk, d.entity_id, @intFromFloat(amount));
                if (v < 0) return true;
                if (v > 0) amount = amount * @as(f32, @floatFromInt(v)) / 100.0;
            }
        }
        // Attribute the hit: stock's NetPackageDamageEntity carries
        // attackerEntityId (::read, asm.il:810693) and EAISetAsTargetIfHurt
        // turns it into the victim's attack target. The actor is already
        // validated above, so use its net id rather than the claimed field.
        const dmg = self.sim.damageFrom(d.entity_id, amount, self.sim.network_id[actor_slot].id);
        // Item durability (GAP "Item durability"): the held tool wears with
        // each landed hit (stock ItemValue.UseTimes; the client shows the
        // durability bar). Zero keeps a broken, repairable stack.
        if (self.sim.mask[actor_slot].inventory) {
            _ = invsys.degradeUse(&self.sim, c.slot, self.sim.inventory[actor_slot].holding, 1.0);
            // Per-attack stamina (RE ItemActionMelee IL: the swing drains
            // `StaminaLoss x StaminaUsageMultiplier` via AddStamina(-cost)).
            // The item's StaminaLoss passive is the cost; the survival pass
            // picks the deduction up on its next stamina sync.
            if (self.sim.mask[actor_slot].health and self.sim.mask[actor_slot].player) {
                const held = &self.sim.inventory[actor_slot].slots[self.sim.inventory[actor_slot].holding];
                if (self.items.byId(held.item_id)) |item_def| {
                    if (item_def.stamina_loss > 0) {
                        const cost = item_def.stamina_loss * self.sim.rules.combat.stamina_usage_multiplier;
                        if (cost > 0) self.sim.health[actor_slot].stamina = @max(0, self.sim.health[actor_slot].stamina - cost);
                    }
                }
            }
        }
        // Combat noise (stock NotifyNoise): a landed ranged hit alerts zombies
        // and wakes sleepers around the shooter (group-AI PARTIAL).
        if (self.sim.mask[actor_slot].transform) {
            const pt = self.sim.transform[actor_slot];
            self.sim.pushNoise(pt.x, pt.y, pt.z, self.sim.rules.ai.combat_noise_radius);
        }
        // Hit shove: the victim's knockback impulse animates on every peer
        // that sees it (stock EntityAlive.AddMotion -> NetPackageEntityVelocity).
        if (dmg.knocked) {
            if (self.sim.slotOfNetId(d.entity_id)) |vslot| {
                const kb = self.sim.zombie_ai[vslot];
                const kb_vx: f32 = kb.kb_dx * self.sim.rules.combat.knockback_speed;
                const kb_vz: f32 = kb.kb_dz * self.sim.rules.combat.knockback_speed;
                if (packages.stock_xp.buildEntityVelocityBody(self.body_buf[48..72], .{
                    .entity_id = d.entity_id,
                    .b_add = true,
                    .dx = kb_vx,
                    .dy = 0,
                    .dz = kb_vz,
                })) |vb| {
                    const vt = self.sim.transform[vslot];
                    for (&self.clients) |*cl| {
                        if (!cl.joined or cl.peer == null) continue;
                        if (self.clientObserves(cl, vt.x, vt.z)) {
                            if (cl.peer) |p| self.sendGame(p, "NetPackageEntityVelocity", vb) catch {
                                self.harness.counters.inc(.net_send_errors);
                            };
                        }
                    }
                } else |_| {}
            }
        }
        if (dmg.killed) {
            // Dead players keep the entity (client runs its own death →
            // respawn flow); EntityRemove would delete the local player.
            const target_is_player = if (self.sim.slotOfNetId(d.entity_id)) |ti| self.sim.mask[ti].player else false;
            if (!target_is_player) {
                // Corpse dwell (EntityAlive::OnDeathUpdate): the body stays
                // in world for TimeStayAfterDeath (30 s zombies, 300 s
                // animals) so the client's ragdoll is not yanked mid
                // animation; the tick sweep broadcasts EntityRemove when
                // the dwell expires. The loot bag below still spawns now.
            } else {
                // The death screen spawn list (NetPackageWorldSpawnPoints) is
                // sent from the hp-replicate pass on any player death (C2S and
                // AI kills alike); the client runs its own death screen.
                // DropOnDeath: 0 nothing, 1 all, 2 toolbelt, 3 backpack, 4 delete.
                // Modes 1..3 drop a loot bag at the death position holding the
                // victim's real inventory range; 0/4 drop nothing.
                if (self.drop_on_death >= 1 and self.drop_on_death <= 3) {
                    if (self.sim.slotOfNetId(d.entity_id)) |ti| {
                        self.spawnDeathBag(ti);
                    }
                }
            }
            if (was_zombie) {
                // The victim position rides the kill event so ClearSleepers
                // phases can gate kills to the quest's bound POI.
                const vs_opt = self.sim.slotOfNetId(d.entity_id);
                const vx: f32 = if (vs_opt) |vs| self.sim.transform[vs].x else 0;
                const vz: f32 = if (vs_opt) |vs| self.sim.transform[vs].z else 0;
                systems.questOnZombieKilled(&self.sim, c.slot, vx, vz);
                // XPMultiplier + party split: award scaled server-side XP for
                // the kill, sharing it with in-range party mates (§2.3).
                self.killXpAward(c.slot, self.xpGainFor(d.entity_id), dmg.kill_scale_pct);
                // AddScoreClient: the character-sheet zombie-kill counter.
                // Stock EntityAlive.AddScore fires on every zombie kill.
                if (c.zombie_kills < std.math.maxInt(u16)) c.zombie_kills += 1;
                sendScoreUpdate(self, c);
            } else if (target_is_player) {
                // PvP kill (PlayerKillingMode != 0): the killer's playerKills
                // counter, stock EntityAlive.AddScore.
                if (c.player_kills < std.math.maxInt(u16)) c.player_kills += 1;
                sendScoreUpdate(self, c);
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
                if (trader_slot) |ts| {
                    // Stock EntityTrader opens the window only inside the
                    // trader_info open hours (vending machines and traders
                    // without hours are always open). Deny outside them.
                    if (!self.traderIsOpen(ts)) {
                        const resp = try packages.buildLockResponseDeny(&self.body_buf, req, "closed");
                        try self.sendGame(peer, "NetPackageLockResponse", resp);
                        return true;
                    }
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
                        .trader_id = self.sim.network_id[ts].id,
                        .available_money = self.traderMoney(ts),
                        .entries = ent_buf[0..n],
                    });
                    try self.sendGame(peer, "NetPackageLockResponse", resp);
                    // Wasm-first: the window-open announcement rides a plugin
                    // (kind 0 = trader open), not native code.
                    self.plugins.traderEvent(c.entity_id, self.sim.network_id[ts].id, 0);
                    self.wasm_plugins.traderEvent(c.entity_id, self.sim.network_id[ts].id, 0);
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
            if (self.sim.slotOfNetId(tid)) |ts| {
                self.sim.turret[ts].owner_slot = @intCast(c.slot);
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

/// Relay `body` verbatim to every joined client, including the sender
/// (stock GameMessageServer re-broadcasts to all peers, sender included).
fn relayBodyAll(self: *Game, pkg: []const u8, body: []const u8, label: []const u8) void {
    relayBodyExcept(self,pkg, body, null, label);
}

/// Relay `body` verbatim to every joined client except `except_entity_id`'s
/// client (stock allButAttachedToEntityId fan-out); null relays to all.
fn relayBodyExcept(self: *Game, pkg: []const u8, body: []const u8, except_entity_id: ?i32, label: []const u8) void {
    for (&self.clients) |*cl| {
        if (!cl.joined or cl.peer == null) continue;
        if (except_entity_id) |eid| {
            if (cl.entity_id == eid) continue;
        }
        self.sendGame(cl.peer.?, pkg, body) catch |err| {
            self.harness.counters.inc(.net_send_errors);
            std.debug.print("zdtd: send {s} failed: {s}\n", .{ label, @errorName(err) });
        };
    }
}

/// Native then Wasm chat filter chain. Returns the possibly-rewritten text
/// (aliasing one of the scratch buffers), or null when policy drops it.
fn filteredChatText(self: *Game, c: *Client, msg: []const u8, native_buf: []u8, wasm_buf: []u8) ?[]const u8 {
    if (self.plugins.chatFilter(c.entity_id, msg, native_buf)) |f| {
        if (f.len == 0) return null;
        if (!chatMsgOk(f)) return null;
        // f aliases native_buf; return it directly rather than copying onto
        // itself ("@memcpy arguments alias").
        return f;
    }
    if (self.wasm_plugins.chatFilter(c.entity_id, msg, wasm_buf)) |f| {
        if (f.len == 0) return null;
        if (!chatMsgOk(f)) return null;
        return f;
    }
    return msg;
}

/// Push the killer's AddScoreClient (zombie + player kill counters).
fn sendScoreUpdate(self: *Game, c: *Client) void {
    const kpeer = c.peer orelse return;
    if (packages.stock_xp.buildAddScoreBody(self.body_buf[32..48], .{
        .entity_id = c.entity_id,
        .zombie_kills = c.zombie_kills,
        .player_kills = c.player_kills,
    })) |ab| {
        self.sendGame(kpeer, "NetPackageEntityAddScoreClient", ab) catch |err| {
            self.harness.counters.inc(.net_send_errors);
            std.debug.print("zdtd: send AddScoreClient failed: {s}\n", .{@errorName(err)});
        };
    } else |_| {}
}
