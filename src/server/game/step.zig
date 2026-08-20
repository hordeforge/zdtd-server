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
const game_stability = @import("stability.zig");
const game_net = @import("net.zig");
const util_sim = @import("../../util/sim.zig");

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
        const r = systems.tickAll(&self.sim, dt);
        self.harness.counters.add(.path_replans, r.path_replans);
        self.harness.counters.add(.path_replans_denied, r.path_replans_denied);
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
                systems.questOnZombieKilled(&self.sim, osz);
                // ItemActionAttack.Hit / ProjectileMoveScript.checkCollision scale a
                // turret/trap kill's XP by PassiveEffects.ElectricalTrapXP rather than
                // paying full credit like a direct player kill; stock's own default is
                // 0 (buffs.xml), unlocked only by perkAdvancedEngineering. zdtd has no
                // perk levels yet (docs/adr/0023-perk-attribute-system.md), so
                // trap_kill_xp_frac is a flat floor rather than a per-player lookup.
                const trap_xp = self.xpGainFor(r.killed_ids[tk]);
                const trap_xp_scaled: u64 = @trunc(@as(f32, @floatFromInt(trap_xp)) * self.sim.rules.progression.trap_kill_xp_frac);
                self.killXpAward(osz, trap_xp_scaled);
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
            const bm = self.sim.director.bloodmoon_active;
            if (bm != self.bloodmoon_sent) {
                self.bloodmoon_sent = bm;
                const bm_body = try packages.buildBloodmoonMusicBody(self.body_buf[0..1], bm);
                try self.broadcast("NetPackageBloodmoonMusic", bm_body);
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
            var ri: usize = 0;
            while (ri < @min(@as(usize, d.reward_n), ecs.quest.max_reward_flags)) : (ri += 1) {
                const spec = d.rewards[ri];
                const scaled: u32 = @as(u32, spec.value) * pct / 100;
                switch (spec.kind) {
                    .item, .loot_item => {
                        const eid = self.items.ecsIdByName(spec.item_name);
                        if (eid != 0) _ = invsys.give(&self.sim, peer, eid, @intCast(@min(scaled, 65535)));
                    },
                    .exp => self.awardXp(peer, scaled),
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
