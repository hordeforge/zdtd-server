//! Main tick step — extracted verbatim from game.zig.
//! `Game.step` and helpers that are only called from the step.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const apm = @import("../../apm/root.zig");
const clock = @import("../../util/clock.zig");
const protocol = @import("../../protocol.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const interest = @import("../../ecs/interest.zig");
const replicate_te = @import("../replicate_te.zig");
const invsys = @import("../../ecs/inventory.zig");
const assets_loot = @import("../../assets/loot.zig");
const game_stability = @import("stability.zig");
const game_net = @import("net.zig");
const util_sim = @import("../../util/sim.zig");
const sky = @import("../../world/sky.zig");

pub fn step(self: *Game) !void {
    const sc = apm.profiler.scope(&self.harness.prof, .tick_total);
    var completed = false;
    defer {
        sc.end();
        apm.tracy.frameMark();
        if (completed and clock.isVirtual()) util_sim.advanceTick();
    }
    self.tick_n += 1;
    self.harness.counters.inc(.ticks);
    self.plugins.setTick(self.tick_n);

    {
        const sn = apm.profiler.scope(&self.harness.prof, .net_poll);
        defer sn.end();
        var polls: u32 = 0;
        while (polls < 64) : (polls += 1) {
            const ev = self.net.poll(&self.recv_buf) catch |err| {
                self.harness.counters.inc(.net_poll_errors);
                if (util_sim.isEnabled()) {
                    var seed_buf: [32]u8 = undefined;
                    var ts: [19]u8 = undefined;
                    std.debug.print("zdtd: {s} net poll error: {s} ({s})\n", .{
                        clock.wallStamp(&ts),
                        @errorName(err),
                        util_sim.formatSeed(&seed_buf),
                    });
                } else {
                    var ts: [19]u8 = undefined;
                    std.debug.print("zdtd: {s} net poll error: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
                }
                return err;
            };
            switch (ev) {
                .none => break,
                .connected => |p| self.onConnected(p) catch |e| {
                    self.harness.counters.inc(.join_fail);
                    var ts: [19]u8 = undefined;
                    std.debug.print(
                        "zdtd: {s} onConnected failed local_id={d}: {s}\n",
                        .{ clock.wallStamp(&ts), p.local_id, @errorName(e) },
                    );
                },
                .data => |d| self.onData(d.peer, d.payload) catch |err| {
                    self.harness.counters.inc(.net_payload_errors);
                    game_net.logPayloadErr(self, d.peer.local_id, err);
                },
            }
        }
        self.reapStalePeers();
        self.reapPolicyKicks();
        var info_n: u32 = 0;
        while (info_n < 8) : (info_n += 1) self.info_tcp.poll();
        self.pollAdmin();
        var web_n: u32 = 0;
        while (web_n < 4) : (web_n += 1) self.pollWebui();
        self.mcp.poll();
    }

    const dt: f32 = 1.0 / @as(f32, @floatFromInt(protocol.ticks_per_second));
    {
        const se = apm.profiler.scope(&self.harness.prof, .sim_entities);
        defer se.end();
        if (self.terrain_snapshot_on) {
            const ts = apm.profiler.scope(&self.harness.prof, .terrain_snap);
            var px: [game_mod.max_clients]f32 = undefined;
            var py: [game_mod.max_clients]f32 = undefined;
            var pz: [game_mod.max_clients]f32 = undefined;
            const pn = self.gatherPlayerPositions(&px, &py, &pz);
            const covered = self.terrain_snap.rebuild(&self.world, px[0..pn], pz[0..pn]);
            ts.end();
            self.harness.counters.add(.terrain_snap_chunks, covered);
        }
        self.sim.director.party_stage = self.partyHighestGameStage();
        // Day/night ambient (world/sky.zig slice 1): one value per tick from
        // the world clock + its dawn/dusk boundary (WorldClock dawn/dusk =
        // stock GameUtils::CalcDuskDawnHours(DayLightLength)) feeds the sim's
        // stealth light legs (CanSleeperAttackDetect crouch range) and the
        // stealth-meter S2C byte.
        const clk = &self.sim.director.clock;
        self.sim.ambient_light = sky.ambientLuma(sky.dayPercent(
            clk.worldTimeBits(),
            clk.dawn,
            clk.dusk,
        ));
        // Wake sleeper volumes whose AABB contains this tick's combat noise
        // (stock World.CheckSleeperVolumeNoise; player-independent) - must run
        // before systems.tickAll consumes the noise ring.
        self.triggerSleeperVolumesByNoise();
        const r = systems.tickAll(&self.sim, dt);
        self.harness.counters.add(.path_replans, r.path_replans);
        self.harness.counters.add(.path_replans_denied, r.path_replans_denied);
        // Sleeper re-arm (stock ClearedUpdate IL=33): recount the per-volume
        // alive sleeper zombies; a group that died sets the volume's
        // respawn_time (LootRespawnDays x 24000 ticks) for the touch re-arm.
        self.tickSleeperRearm();
        // Movement-noise sleeper wake (stock PlayerStealth.NotifyNoise →
        // World.CheckSleeperVolumeNoise): the stealth system queued points
        // when a player's sleeperNoiseVolume hit the 360 cap; wake volumes
        // whose AABB contains them (post-tick: the points landed mid-tick).
        self.triggerSleeperVolumesByStealthNoise();
        // Water leveling: pour basins opened by this tick's block edits (dig
        // beside a lake, placed water). Budgeted per tick; the fills mark
        // chunks dirty and the chunk stream broadcasts them.
        _ = self.world.levelWaterTick(
            self.sim.rules.water.edits_per_tick,
            self.sim.rules.water.spread_cap,
            self.sim.rules.water.puddle_cap,
        );
        // Stability-collapse falling blocks (EntityFallingBlock groups): fall
        // under gravity, die on landing (RE entity-ai.md landing: no
        // re-placement).
        systems.systemFallingBlocks(&self.sim, dt);
        // Demolition explosions (RE entity-ai.md EntityZombieCop): the sim
        // countdowns pushed requests; apply the entity + block AoE here.
        self.drainExplosions();
        // MoveHelper dig damage (RE entity-ai.md DigUpdate): the sim runs the
        // cadence; the Game applies the block damage like the chase chew.
        self.drainDigRequests();
        // Sleeper wakes (RE EntityAlive.ConditionalTriggerSleeperWakeUp): the
        // sim flipped sleepers to awake (proximity/noise/damage); broadcast
        // NetPackageSleeperWakeup so clients play the wake animation.
        self.drainSleeperWakeups();
        // Cosmetic head-aim (RE EntityAlive.SetLookPosition): broadcast
        // EntityLookAt to tracking players when a zombie's look target moves.
        self.tickEntityLookAt();
        // Stealth meters (RE PlayerStealth.TickServer S2C): broadcast
        // NetPackageEntityStealth for each player every 16 ticks on change.
        self.tickStealthBroadcast();
        // In-game minimap (RE MapChunkDatabase.GetMapChunkPackagesToSend):
        // fill the 17x17 window around each client's map middle, batched.
        self.tickMapChunks();
        // Map player markers (RE GameManager.playerPositionsCountdownTimer):
        // broadcast PersistentPlayerPositions every 6 s.
        self.tickPlayerPositions();
        // Player list (RE ConnectionManager.updateClientInfo): broadcast
        // ClientInfo every 5 s.
        self.tickClientInfo();
        // serveradmin.xml hot-reload poll (stock InitFileWatcher).
        self.tickServerAdminReload();
        self.tickSurvival(dt);
        self.tickBots(dt);
        {
            // This loop destroys consumed bags, so snapshot the dense group to
            // preserve ascending traversal without scanning the full capacity.
            var bags: [ecs.max_entities]ecs.Slot = undefined;
            const bag_n = ecs.query.copyKindInto(&self.sim, .loot_bag, &bags);
            for (bags[0..bag_n]) |bs| {
                if (!self.sim.alive[bs] or !self.sim.mask[bs].loot_bag) continue;
                const b = self.sim.loot_bag[bs];
                if ((b.distraction_tags & 1) == 0 or b.distraction_eat_ticks > 0) continue;
                const lid = self.sim.network_id[bs].id;
                if (packages.buildRemoveBodyReason(&self.body_buf, lid, .despawned)) |rm| {
                    self.broadcast("NetPackageEntityRemove", rm) catch {};
                } else |_| {}
                self.sim.destroy(bs);
            }
        }
        if (self.claims_last_day != self.sim.director.clock.day) {
            self.claims_last_day = self.sim.director.clock.day;
            for (self.vending.items[0..], self.vending.used[0..]) |*v, u| {
                if (!u) continue;
                if (v.rental_end_day > 0 and self.sim.director.clock.day > v.rental_end_day) v.clear();
            }
            self.expireClaims();
        }
        {
            const bm = game_stability.bloodMoonDayFor(self.sim.director.clock);
            if (self.last_bm_day != bm) {
                if (self.last_bm_day >= 0) self.broadcastGameStats() catch |err| {
                    self.harness.counters.inc(.net_send_errors);
                    var ts: [19]u8 = undefined;
                    std.debug.print("zdtd: {s} broadcastGameStats failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
                };
                self.last_bm_day = bm;
            }
        }
        if (self.terrain_snapshot_on) {
            const now = self.terrain_snap.misses.load(.monotonic);
            self.harness.counters.add(.terrain_snap_misses, now -| self.snap_misses_seen);
            self.snap_misses_seen = now;
        }
        if (self.tick_n % self.sleeper_tick_ticks == 0) self.tickSleeperVolumes();
        if (self.tick_n % self.sleeper_tick_ticks == 0) {
            self.tickAirDrop();
            self.tickZombieBlockDamage();
        }
        if (self.tick_n % self.sleeper_tick_ticks == 0) {
            self.tickWorkstations(@as(f32, @floatFromInt(self.sleeper_tick_ticks)) * 0.05) catch |err| {
                self.harness.counters.inc(.net_send_errors);
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} broadcastDirtyWorkstations failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
            };
            self.tickBlockRadiusEffects();
            // Always-on radius sources (torch/candle/radiated barrel/pumpkin,
            // no fuel module): per-player local scan, WORK_PLAN T38.
            self.tickAlwaysOnRadiusEffects();
        }
        const daylight = !self.sim.director.clock.isNight();
        _ = self.sim.power.tick(dt, daylight);
        replicate_te.broadcastPowerVisuals(self);
        self.reapStaleLocks();
        {
            var corpses: [16]ecs.entity.NetId = undefined;
            const nc = self.sim.sweepCorpses(dt, &corpses);
            var ci: usize = 0;
            while (ci < nc) : (ci += 1) {
                const rm = packages.buildRemoveBody(&self.body_buf, corpses[ci]) catch continue;
                self.broadcast("NetPackageEntityRemove", rm) catch continue;
            }
        }
        self.tickTraderAreas();
        if (r.turret_kills > 0) {
            var tk: u8 = 0;
            while (tk < r.killed_n) : (tk += 1) {
                const owner = r.owner_slots[tk];
                if (owner < 0 or @as(usize, @intCast(owner)) >= self.clients.len) continue;
                const osz: usize = @intCast(owner);
                const oc = &self.clients[osz];
                if (!oc.joined) continue;
                // ClearSleepers phases gate kills to the quest's POI, so the
                // victim position rides the kill event (stock EntityKill event
                // carries the killed entity).
                const vz = self.sim.slotOfNetId(r.killed_ids[tk]);
                if (vz) |vs| {
                    systems.questOnZombieKilled(&self.sim, osz, self.sim.transform[vs].x, self.sim.transform[vs].z);
                } else {
                    systems.questOnZombieKilled(&self.sim, osz, 0, 0);
                }
                // ItemActionAttack.Hit / ProjectileMoveScript.checkCollision scale a
                // turret/trap kill's XP by PassiveEffects.ElectricalTrapXP rather than
                // paying full credit like a direct player kill; stock's own default is
                // 0 (buffs.xml), unlocked only by perkAdvancedEngineering. zdtd has no
                // perk levels yet (docs/adr/0023-perk-attribute-system.md), so
                // trap_kill_xp_frac is a flat floor rather than a per-player lookup.
                const trap_xp = self.xpGainFor(r.killed_ids[tk]);
                // Guard the float->int cast: a negative or huge
                // trap_kill_xp_frac (config) traps @trunc into u64.
                const trap_scaled_f = @as(f32, @floatFromInt(trap_xp)) *
                    @max(0, self.sim.rules.progression.trap_kill_xp_frac);
                const trap_xp_scaled: u64 = if (!std.math.isFinite(trap_scaled_f))
                    0
                else
                    @min(@as(u64, @intFromFloat(trap_scaled_f)), std.math.maxInt(i32));
                self.killXpAward(osz, trap_xp_scaled, 100); // trap kills carry no verdict scale
                if (oc.zombie_kills < std.math.maxInt(u16)) oc.zombie_kills += 1;
                if (oc.peer) |kpeer| {
                    if (packages.stock_xp.buildAddScoreBody(self.body_buf[32..48], .{
                        .entity_id = oc.entity_id,
                        .zombie_kills = oc.zombie_kills,
                    })) |ab| {
                        self.sendGame(kpeer, "NetPackageEntityAddScoreClient", ab) catch {
                            self.harness.counters.inc(.net_send_errors);
                        };
                    } else |_| {}
                }
            }
        }
        var ki: u8 = 0;
        while (ki < r.killed_n) : (ki += 1) {
            const kid = r.killed_ids[ki];
            if (kid <= 0) continue;
            const rm = try packages.buildRemoveBody(&self.body_buf, kid);
            try self.broadcast("NetPackageEntityRemove", rm);
        }
        var di: u8 = 0;
        while (di < r.despawned_n) : (di += 1) {
            const did = r.despawned_ids[di];
            if (did <= 0) continue;
            const rm = try packages.buildRemoveBodyReason(&self.body_buf, did, .despawned);
            try self.broadcast("NetPackageEntityRemove", rm);
        }
        if (r.buff_expired_n > 0) try self.broadcastBuffExpiries(&r);
        var li: u8 = 0;
        while (li < r.loot_n) : (li += 1) {
            const lid = r.loot_bag_ids[li];
            if (lid > 0) {
                self.fillLootBagFromTable(lid, "", @bitCast(lid), self.partyLootStage());
                try self.broadcastLootSpawn(lid);
            }
        }
        self.harness.counters.add(.entities_ticked, self.sim.countKind(.zombie));

        if (self.tick_n % self.world_time_send_ticks == 0) {
            const tb = try packages.buildWorldTimeBody(self.body_buf[0..16], r.world_time);
            try self.broadcast("NetPackageWorldTime", tb);
            self.world.weather.tick(
                &self.world.biome_layers_table,
                @intCast(@min(r.world_time, std.math.maxInt(i64))),
                self.sim.director.bloodmoon_active,
            );
            if (!self.loadShedding()) try self.broadcastWeather();
            // Blood-moon music is per player (stock EntityPlayer.bloodMoonParty):
            // a player hears it while their own party's horde is alive. Each
            // client's edge is tracked; the old single global bool made every
            // player hear horde music when any party was horded.
            for (&self.clients) |*cl| {
                if (!cl.joined or cl.peer == null) continue;
                const on = self.playerBloodMoonMusic(cl);
                if (on != cl.bloodmoon_music) {
                    cl.bloodmoon_music = on;
                    const bm_body = try packages.buildBloodmoonMusicBody(self.body_buf[0..1], on);
                    try self.sendGame(cl.peer.?, "NetPackageBloodmoonMusic", bm_body);
                }
            }
        }
        if (self.tick_n % self.vehicle_pos_send_ticks == 0 and !self.loadShedding()) try self.broadcastVehiclePositions();
        if (self.tick_n % self.turret_sync_ticks == 0) try self.broadcastTurretSync();
        self.plugins.onTick();
        self.wasm_plugins.onTick();
        // Temporal composability: a plugin that disabled itself this pass must
        // not leave queued (undrained) effects behind; withdraw before the
        // next drain (paper: revertible effects).
        var wsrc: [8]i16 = undefined;
        const wn = self.wasm_plugins.takeWithdrawn(&wsrc);
        for (wsrc[0..wn]) |s| self.sim.commands.dropFrom(s);
    }
    {
        const cn = self.sim.completed_quests_n;
        var ci: usize = 0;
        while (ci < cn) : (ci += 1) {
            const cq = self.sim.completed_quests_ring[ci];
            if (cq.slot >= self.sim.player.len) continue;
            const peer: usize = @intCast(self.sim.player[cq.slot].peer_slot);
            if (peer >= self.clients.len) continue;
            const d = self.sim.catalog.byId(cq.def_id) orelse continue;
            const sv = self.plugins.questComplete(self.sim.network_id[cq.slot].id, cq.def_id);
            const v = if (sv != 0) sv else self.wasm_plugins.questComplete(self.sim.network_id[cq.slot].id, cq.def_id);
            if (v < 0) continue;
            const pct: u32 = if (v > 0) @intCast(v) else 100;
            // reward_coin through the same verdict (deny withholds, >0
            // scales the coin leg like items/exp). Widen before the multiply:
            // a verdict percent can be huge, and u32 math would wrap the
            // payout (or trap on the overflow check).
            const coin_reward: u32 = @intCast(@min(
                @as(u64, d.reward_coin) * @as(u64, pct) / 100,
                @as(u64, std.math.maxInt(u32)),
            ));
            if (coin_reward > 0) {
                if (self.sim.mask[cq.slot].wallet) {
                    self.sim.wallet[cq.slot].coins +|= coin_reward;
                }
            }
            var ri: usize = 0;
            while (ri < @min(@as(usize, d.reward_n), ecs.quest.max_reward_flags)) : (ri += 1) {
                const spec = d.rewards[ri];
                // ischosen rewards are the pick-one-of-N choices and are NOT
                // granted by the stock dedi: every CloseQuest/RefreshQuest
                // Completion caller passes a null rewardChoice, so CloseQuest's
                // ischosen gate (IL_034B-038B) skips them; the player's pick is
                // applied in the CLIENT's local sim (XUiC_QuestTurnInRewards
                // Window.BtnAccept_OnPress builds the chosen list) and rides the
                // inventory sync - the same trust model as harvest loot. The
                // server rolling the choice groups would grant every option.
                if (spec.is_chosen) continue;
                const scaled: u32 = @intCast(@min(
                    @as(u64, spec.value) * @as(u64, pct) / 100,
                    @as(u64, std.math.maxInt(u32)),
                ));
                switch (spec.kind) {
                    .item => {
                        const eid = self.items.ecsIdByName(spec.item_name);
                        if (eid != 0) _ = invsys.give(&self.sim, peer, eid, @intCast(@min(scaled, 65535)));
                    },
                    .loot_item => {
                        // A LootItem reward id is a stock item name OR a loot
                        // group (stock quests.xml uses groupQuest* ids with
                        // ischosen/isfixed). Group ids roll prob-weighted
                        // picks (or the first entries when isfixed) and grant
                        // each rolled stack; plain items grant as before.
                        if (self.loot.groupByName(spec.item_name)) |_| {
                            var stacks: [8]assets_loot.Stack = undefined;
                            const picks: u8 = @intCast(@min(spec.value, 8));
                            const want = if (picks == 0) 1 else picks;
                            const seed: u32 = @truncate(self.sim.director.clock.worldTimeBits() ^ @as(u64, @intCast(cq.def_id)));
                            // Stock GetRewardItem rolls with gameStage =
                            // GetTraderStage(quest tier) = Level*(1+mod) (RE
                            // loot-economy.md 8.4, progression.md
                            // GetTraderStage IL=46); the tier mod comes from
                            // the traders.xml root quest_tier_mod.
                            const n = self.loot.rollGroupPicks(spec.item_name, self.questRewardStage(d, peer), seed, want, spec.is_fixed, &stacks);
                            var si: usize = 0;
                            while (si < n) : (si += 1) {
                                const eid = self.items.ecsIdByName(stacks[si].item_name);
                                if (eid != 0) _ = invsys.give(&self.sim, peer, eid, @intCast(@min(stacks[si].count, 65535)));
                            }
                        } else {
                            const eid = self.items.ecsIdByName(spec.item_name);
                            if (eid != 0) _ = invsys.give(&self.sim, peer, eid, @intCast(@min(scaled, 65535)));
                        }
                    },
                    .exp => self.awardXp(peer, scaled),
                    // RewardQuest chaining (stock Quest.AddQuestReward): the
                    // turn-in grants the named quest to the player's journal.
                    .quest => {
                        if (spec.item_name.len > 0) {
                            if (self.sim.catalog.byName(spec.item_name)) |qd| {
                                _ = systems.questAccept(&self.sim, cq.slot, qd.id);
                            }
                        }
                    },
                    else => {},
                }
            }
        }
        self.sim.completed_quests_n = 0;
    }

    try self.replicate();
    if (self.tick_n % self.save_interval_ticks == 0) {
        const ss = apm.profiler.scope(&self.harness.prof, .save_io);
        defer ss.end();
        {
            const es = apm.profiler.scope(&self.harness.prof, .save_encode);
            defer es.end();
            self.world.saveAll() catch |e| game_mod.logPersistErr(self, "save world", e);
        }
        self.containers.save(self.world.world_dir, self.allocator) catch |e| game_mod.logPersistErr(self, "save containers", e);
        self.workstations.save(self.world.world_dir, self.allocator) catch |e| game_mod.logPersistErr(self, "save workstations", e);
        self.vending.save(self.world.world_dir) catch |e| game_mod.logPersistErr(self, "save vending", e);
        self.saveClaims() catch |e| game_mod.logPersistErr(self, "save claims", e);
        self.saveEntities() catch |e| game_mod.logPersistErr(self, "save entities", e);
        self.allies.save(self.world.world_dir, self.allocator) catch |e| game_mod.logPersistErr(self, "save allies", e);
        self.saveBlockMeta() catch |e| game_mod.logPersistErr(self, "save block meta", e);
        self.saveWeather() catch |e| game_mod.logPersistErr(self, "save weather", e);
        self.saveClock() catch |e| game_mod.logPersistErr(self, "save clock", e);
        if (self.players_dirty) {
            self.players_dirty = false;
            self.savePlayers() catch |e| game_mod.logPersistErr(self, "save players", e);
        }
    }
    self.sampleFlushCounters();

    if (self.tick_n % self.apm_report_period_ticks == 0) {
        var snap = self.harness.snapshot();
        var entered_n: u32 = 0;
        var peers_alive: u32 = 0;
        for (&self.clients) |cl| {
            if (cl.entered) entered_n += 1;
        }
        for (&self.net.peers) |p| {
            if (p.alive) peers_alive += 1;
        }
        snap.ops = .{
            .tick = self.tick_n,
            .joined = self.countJoined(),
            .entered = entered_n,
            .peers_alive = peers_alive,
            .zombies = @intCast(@min(self.sim.countKind(.zombie), std.math.maxInt(u32))),
            .chunks = @intCast(@min(self.world.chunks.count(), std.math.maxInt(u32))),
        };
        var report_buf: [apm.report.max_json_bytes]u8 = undefined;
        var report_writer: std.Io.Writer = .fixed(&report_buf);
        var report_ok = true;
        apm.report.writeJsonLine(&snap, &report_writer) catch |err| {
            report_ok = false;
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} apm report failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
        };
        if (report_ok) {
            var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            std.Io.File.stdout().writeStreamingAll(threaded.io(), report_writer.buffered()) catch |e| {
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} apm report write failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(e) });
            };
        }
    }
    completed = true;
}

/// Stock GetRewardItem rolls quest rewards with gameStage =
/// GetTraderStage(quest tier) = Level*(1+quest_tier_mod[tier-1]) (RE
/// loot-economy.md 8.4, progression.md GetTraderStage IL=46; the tier mod
/// is the traders.xml root quest_tier_mod). Falls back to the party loot
/// stage when the def has no tier or the table no quest_tier_mod.
pub fn questRewardStage(self: *const Game, d: ecs.quest.QuestDef, peer: usize) i32 {
    if (d.difficulty_tier < 1 or peer >= self.clients.len) return self.partyLootStage();
    const mods = self.traders.quest_tier_mod;
    if (mods.len == 0) return self.partyLootStage();
    const idx: usize = @min(@as(usize, d.difficulty_tier - 1), mods.len - 1);
    const level: f32 = @floatFromInt(self.clients[peer].level);
    const base = level * (1.0 + mods[idx]);
    // Clamp before the cast: a modded quest_tier_mod can push base past the
    // i32 range (finite), which traps @intFromFloat.
    if (!std.math.isFinite(base) or base < 1.0) return 1;
    // 2^31 is exactly representable in f32; anything at or above it
    // truncates out of i32 range.
    if (base >= 2147483648.0) return std.math.maxInt(i32);
    return @max(1, @as(i32, @floor(base)));
}
