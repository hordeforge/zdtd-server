//! Serialize-once replicate fan-out extracted from game.zig.
//! Verbatim move — called via forwarder in game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const packages = @import("../../wire/packages.zig");
const apm = @import("../../apm/root.zig");
const ecs = @import("../../ecs/root.zig");
const interest = @import("../../ecs/interest.zig");
const gbot = @import("bot.zig");

/// Display name for a bot spawn body; bots always carry a bounded name, so this
/// is non-empty for live bots (fallback backstop only).
fn botName(b: *const gbot.Bot) []const u8 {
    if (b.name_len == 0) return gbot.default_bot_name;
    return b.name[0..b.name_len];
}

pub fn replicate(self: *Game) !void {
    const sc = apm.profiler.scope(&self.harness.prof, .replicate);
    defer sc.end();
    for (&self.clients) |*c| {
        if (c.peer) |p| p.resendPending(&self.net.sock) catch self.harness.counters.inc(.net_send_errors);
    }
    if (self.wire_chunks and self.tick_n % self.chunk_stream_period_ticks == 0) {
        for (&self.clients) |*cl| {
            if (cl.peer == null or !(cl.entered or cl.world_ready)) continue;
            self.streamChunksForClient(cl) catch |err| {
                self.harness.counters.inc(.stream_errors);
                const n = self.harness.counters.get(.stream_errors);
                if (n == 1 or n % 100 == 0) {
                    std.debug.print(
                        "zdtd: chunk stream failed slot={d} entity={d} n={d}: {s}\n",
                        .{ cl.slot, cl.entity_id, n, @errorName(err) },
                    );
                }
            };
        }
    }
    self.replicatePlayerHealth();
    if (self.tick_n % self.motion_replicate_period_ticks != 0) {
        self.clearDeadKnownEntities();
        return;
    }
    if (self.sim.entity_count == 0) {
        self.clearDeadKnownEntities();
        return;
    }

    var pos_frame_buf: [game_mod.replicate_frame_cap]u8 = undefined;
    var speeds_frame_buf: [game_mod.replicate_frame_cap]u8 = undefined;
    var flags_frame_buf: [game_mod.replicate_frame_cap]u8 = undefined;
    var vel_frame_buf: [game_mod.replicate_frame_cap]u8 = undefined;
    var turret_frame_buf: [game_mod.replicate_frame_cap]u8 = undefined;

    var obs_cx: [game_mod.max_clients]i32 = .{0} ** game_mod.max_clients;
    var obs_cz: [game_mod.max_clients]i32 = .{0} ** game_mod.max_clients;
    var obs_ok: [game_mod.max_clients]bool = .{false} ** game_mod.max_clients;
    var obs_r: [game_mod.max_clients]i32 = .{0} ** game_mod.max_clients;
    var active: game_mod.ObsMask = 0;
    for (&self.clients, 0..) |*cl, ci| {
        obs_r[ci] = cl.view_radius;
        if (cl.joined and cl.entered and cl.peer != null) active |= game_mod.bitOf(ci);
        if (!cl.joined or cl.peer == null or cl.entity_id <= 0) continue;
        if (self.sim.slotOfNetId(cl.entity_id)) |si| {
            const oc = interest.cellOf(self.sim.transform[si].x, self.sim.transform[si].z);
            obs_cx[ci] = oc.cx;
            obs_cz[ci] = oc.cz;
            obs_ok[ci] = true;
        }
    }

    const heartbeat = self.tick_n % interest.pos_heartbeat_period_ticks == 0;
    var candidates: ecs.world.AtomicBits = .initEmpty();
    if (!heartbeat) {
        candidates = self.sim.dirty_bits;
        for (self.sim.kind_groups.slice(.zombie)) |s| candidates.set(s);
        for (self.sim.kind_groups.slice(.animal)) |s| candidates.set(s);
        for (self.sim.kind_groups.slice(.trader)) |s| candidates.set(s);
        for (self.sim.kind_groups.slice(.falling_block)) |s| candidates.set(s);
        candidates.intersectFromStatic(self.sim.alive_bits);
    } else {
        // Heartbeat: every live entity is a candidate.
        candidates.copyFromStatic(self.sim.alive_bits);
    }

    var cand_it = candidates.iterator(.{});
    while (cand_it.next()) |cand| {
        const i: ecs.Slot = @intCast(cand);
        if (!self.sim.alive[i] or !self.sim.mask[i].transform or !self.sim.mask[i].network_id) continue;
        self.harness.counters.inc(.replicate_candidates);
        const ecell = interest.cellOf(self.sim.transform[i].x, self.sim.transform[i].z);
        const in_range = interest.observerMask(game_mod.max_clients, &obs_cx, &obs_cz, &obs_r, active, ecell.cx, ecell.cz);

        const is_falling = self.sim.mask[i].kind and self.sim.kind[i] == .falling_block;
        const is_mob = self.sim.mask[i].kind and (self.sim.kind[i] == .zombie or
            self.sim.kind[i] == .animal or
            self.sim.kind[i] == .trader or
            is_falling);
        var spawn_mask: game_mod.ObsMask = 0;
        if (is_mob) {
            var m = in_range;
            while (m != 0) : (m &= m - 1) {
                const ci = @ctz(m);
                if (!self.clients[ci].known_entities.isSet(i)) spawn_mask |= game_mod.bitOf(ci);
            }
        }
        if (spawn_mask != 0) {
            // Singular fallingBlock (n=1, stock default path) vs the opt-in
            // fallingBlocks group: distinct class hashes and ECD payloads.
            const falling_single = is_falling and self.sim.falling[i].n == 1;
            const eclass: i32 = if (falling_single)
                packages.stock_entity.class_falling_block
            else if (is_falling)
                packages.stock_entity.class_falling_blocks
            else if (self.sim.mask[i].class_id and self.sim.class_id[i].hash != 0)
                self.sim.class_id[i].hash
            else
                packages.stock_entity.class_zombie_default;
            const sleeper = self.sim.mask[i].sleeper and !self.sim.sleeper[i].awake;
            // Falling blocks carry their cells (RE entity-ai.md
            // CreateFallingBlockGroup): raw values + world positions so the
            // client renders the right blocks falling.
            var fb_buf: [ecs.components.falling_group_cap]packages.stock_entity.FallingBlock = undefined;
            const fb_slice: ?[]const packages.stock_entity.FallingBlock = if (is_falling and !falling_single) blk: {
                const n = @min(self.sim.falling[i].n, ecs.components.falling_group_cap);
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    fb_buf[k] = .{
                        .raw_data = self.sim.falling[i].cells[k].raw,
                        .x = self.sim.falling[i].cells[k].x,
                        .y = self.sim.falling[i].cells[k].y,
                        .z = self.sim.falling[i].cells[k].z,
                    };
                }
                break :blk fb_buf[0..n];
            } else null;
            if (packages.stock_entity.buildEntitySpawnStock(&self.body_buf, .{
                .entity_id = self.sim.network_id[i].id,
                .entity_class = eclass,
                .x = self.sim.transform[i].x,
                .y = self.sim.transform[i].y,
                .z = self.sim.transform[i].z,
                .yaw = self.sim.transform[i].yaw,
                .is_sleeper = sleeper,
                .is_sleeper_passive = sleeper,
                .falling_block = if (falling_single) .{ .block = .{
                    .raw_data = self.sim.falling[i].cells[0].raw,
                } } else null,
                .falling_blocks = if (fb_slice) |fb| .{ .blocks = fb } else null,
                .trader_data = if (self.sim.kind[i] == .trader and self.sim.mask[i].trader_stock) blk: {
                    var ent_buf: [ecs.components.max_stock]packages.TraderStockEntry = undefined;
                    const n = self.stockEntries(i, &ent_buf);
                    break :blk .{ .trader_id = self.sim.network_id[i].id, .available_money = self.traderMoney(i), .entries = ent_buf[0..n] };
                } else null,
            })) |spb| {
                var m = spawn_mask;
                while (m != 0) : (m &= m - 1) {
                    const ci = @ctz(m);
                    const cl = &self.clients[ci];
                    const peer = cl.peer orelse continue;
                    try self.sendGame(peer, "NetPackageEntitySpawn", spb);
                    cl.known_entities.set(i);
                    self.harness.counters.inc(.replicate_fanouts);
                }
                self.harness.counters.inc(.packages_encoded);
            } else |_| {
                self.harness.counters.inc(.encode_errors);
            }
        }

        if (is_mob) {
            for (&self.clients, 0..) |*cl, ci| {
                if (!cl.known_entities.isSet(i)) continue;
                if (!cl.joined or !cl.entered or !obs_ok[ci]) continue;
                const peer = cl.peer orelse continue;
                if (interest.cellsInRange(obs_cx[ci], obs_cz[ci], ecell.cx, ecell.cz, cl.view_radius)) continue;
                const rb = packages.buildRemoveBodyReason(
                    &self.body_buf,
                    self.sim.network_id[i].id,
                    .unloaded,
                ) catch {
                    self.harness.counters.inc(.encode_errors);
                    continue;
                };
                try self.sendGame(peer, "NetPackageEntityRemove", rb);
                cl.known_entities.unset(i);
                self.harness.counters.inc(.packages_encoded);
            }
        }

        const d = if (self.sim.mask[i].dirty) self.sim.dirty[i] else @as(ecs.components.Dirty, .{});
        if (!interest.needsPosSend(d, self.tick_n)) continue;

        const viewers = if (self.sim.mask[i].player)
            in_range & ~game_mod.bitOfPeerSlot(self.sim.player[i].peer_slot)
        else
            in_range;
        if (viewers == 0) {
            self.harness.counters.inc(.replicate_encodes_skipped);
            continue;
        }

        const nid = self.sim.network_id[i].id;
        const body = packages.buildPosAndRotBody(
            self.body_buf[0..game_mod.speeds_body_off],
            nid,
            self.sim.transform[i].x,
            self.sim.transform[i].y,
            self.sim.transform[i].z,
            0,
            self.sim.transform[i].yaw,
            0,
            true,
        ) catch continue;
        const pos_framed = packages.framed(&pos_frame_buf, "NetPackageEntityPosAndRot", body) catch continue;
        self.harness.counters.inc(.packages_encoded);

        var speeds_framed: ?[]const u8 = null;
        var flags_framed: ?[]const u8 = null;
        var vel_framed: ?[]const u8 = null;
        var turret_framed: ?[]const u8 = null;
        if (self.sim.mask[i].kind and (self.sim.kind[i] == .zombie or self.sim.kind[i] == .animal)) {
            var fwd: f32 = 0.2;
            var state: u8 = 1;
            var flags: u16 = packages.cF_spawned;
            if (self.sim.mask[i].zombie_ai) {
                const st = self.sim.zombie_ai[i].state;
                if (st == .chase or st == .attack) {
                    fwd = 1.0;
                    state = 2;
                    flags |= packages.cF_is_alert | packages.cF_approaching_player;
                } else if (st == .sleep) {
                    fwd = 0;
                    state = 0;
                }
            }
            if (packages.buildEntitySpeedsBody(self.body_buf[game_mod.speeds_body_off..game_mod.flags_body_off], nid, state, fwd, 0)) |sb| {
                if (packages.framed(&speeds_frame_buf, "NetPackageEntitySpeeds", sb)) |sf| {
                    speeds_framed = sf;
                    self.harness.counters.inc(.packages_encoded);
                } else |_| {}
            } else |_| {}
            if (packages.buildAliveFlagsBody(self.body_buf[game_mod.flags_body_off .. game_mod.flags_body_off + 16], nid, flags)) |fb| {
                if (packages.framed(&flags_frame_buf, "NetPackageEntityAliveFlags", fb)) |ff| {
                    flags_framed = ff;
                    self.harness.counters.inc(.packages_encoded);
                } else |_| {}
            } else |_| {}
            // Vertical motion (RE NetEntityDistributionEntry velocity updates):
            // a falling/jumping zombie streams its vy so the client renders the
            // fall instead of gliding; delta-gated per slot. The gen gate
            // clears a recycled slot's stale last-sent vy so the new entity's
            // first fall streams instead of being swallowed by the delta.
            const vy = self.sim.zombie_ai[i].vy;
            const vs = &self.entity_vel_sent[i];
            if (vs.gen != self.sim.network_id[i].gen) vs.* = .{ .gen = self.sim.network_id[i].gen };
            if (@abs(vy - vs.vy) > 0.1) {
                vs.vy = vy;
                if (packages.buildEntityVelocityBody(self.body_buf[game_mod.flags_body_off .. game_mod.flags_body_off + 32], nid, false, 0, vy, 0)) |vb| {
                    if (packages.framed(&vel_frame_buf, "NetPackageEntityVelocity", vb)) |vf| {
                        vel_framed = vf;
                        self.harness.counters.inc(.packages_encoded);
                    } else |_| {}
                } else |_| {}
            }
        }

        // Turret aim/on state (RE EntityTurret TurretSync): broadcast to
        // viewers when the target or powered-on state changes; the client
        // aims the turret at the target and plays the fire state.
        if (self.sim.mask[i].kind and self.sim.kind[i] == .turret) {
            const t = self.sim.turret[i];
            const is_on = t.target_id >= 0;
            const st = &self.turret_sync_sent[i];
            // Slot recycled onto a new turret: a stale target/on pair equal to
            // the new turret's initial state must not suppress its first sync
            // (the client never saw this net id's TurretSync yet).
            if (st.gen != self.sim.network_id[i].gen) st.* = .{ .gen = self.sim.network_id[i].gen };
            if (!st.sent or st.target != t.target_id or st.on != is_on) {
                st.target = t.target_id;
                st.on = is_on;
                st.sent = true;
                if (packages.buildTurretSyncBody(self.body_buf[game_mod.flags_body_off .. game_mod.flags_body_off + 32], nid, t.target_id, is_on)) |tb| {
                    if (packages.framed(&turret_frame_buf, "NetPackageTurretSync", tb)) |tf| {
                        turret_framed = tf;
                        self.harness.counters.inc(.packages_encoded);
                    } else |_| {}
                } else |_| {}
            }
        }

        const per_viewer: u64 = 1 +
            @as(u64, @intFromBool(speeds_framed != null)) +
            @as(u64, @intFromBool(flags_framed != null)) +
            @as(u64, @intFromBool(vel_framed != null)) +
            @as(u64, @intFromBool(turret_framed != null));
        var m = viewers;
        while (m != 0) : (m &= m - 1) {
            const ci = @ctz(m);
            const peer = self.clients[ci].peer orelse continue;
            self.sendFramedUnreliable(peer, pos_framed);
            if (speeds_framed) |sf| self.sendFramedUnreliable(peer, sf);
            if (flags_framed) |ff| self.sendFramedDroppable(peer, ff);
            if (vel_framed) |vf| self.sendFramedUnreliable(peer, vf);
            if (turret_framed) |tf| self.sendFramedReliable(peer, "NetPackageTurretSync", tf, game_mod.window_retry_budget_ns, false) catch self.harness.counters.inc(.net_send_errors);
            self.harness.counters.add(.replicate_fanouts, per_viewer);
        }
    }

    try replicateBots(self, &obs_cx, &obs_cz, &obs_ok, &obs_r, active);

    var dirty_now = self.sim.dirty_bits;
    var dirty_it = dirty_now.iterator(.{});
    while (dirty_it.next()) |j| {
        interest.clearAfterReplicate(&self.sim.dirty[j]);
        self.sim.syncDirtyBit(@intCast(j));
    }
    self.clearDeadKnownEntities();
}

/// Non-ECS bot replication (ADR 0026). Host-side bots are not ECS slots, so
/// they get their own spawn-on-approach / range-remove / PosAndRot fan-out
/// against the same observer grid computed for the ECS entities in replicate().
/// Per-client knowledge is the Client.known_bots bitset (bit = bot slot); it is
/// cleaned only here — never by the ECS dead-entity reconcile, which has no
/// knowledge of bots (they are not in alive_bits).
fn replicateBots(
    self: *Game,
    obs_cx: *const [game_mod.max_clients]i32,
    obs_cz: *const [game_mod.max_clients]i32,
    obs_ok: *const [game_mod.max_clients]bool,
    obs_r: *const [game_mod.max_clients]i32,
    active: game_mod.ObsMask,
) !void {
    const heartbeat = self.tick_n % interest.pos_heartbeat_period_ticks == 0;
    var pos_frame_buf: [game_mod.replicate_frame_cap]u8 = undefined;
    for (&self.bots.bots, 0..) |*b, bi| {
        if (!b.alive) {
            // Dead/removed bot: unspawn it from every viewer that knows it.
            // A removed slot carries net_id -1 (nothing left to send; just
            // clear the bit so the slot can be reused without a stale spawn).
            // Unlike ECS entities there is no separate dead-reconcile pass, so
            // the bit is always cleared even when the send cannot complete.
            for (&self.clients) |*cl| {
                if (!cl.known_bots.isSet(bi)) continue;
                if (b.net_id >= 0) {
                    if (cl.peer) |peer| {
                        if (packages.buildRemoveBodyReason(&self.body_buf, b.net_id, .unloaded)) |rb| {
                            self.sendGame(peer, "NetPackageEntityRemove", rb) catch {
                                self.harness.counters.inc(.net_send_errors);
                            };
                            self.harness.counters.inc(.packages_encoded);
                        } else |_| {
                            self.harness.counters.inc(.encode_errors);
                        }
                    }
                }
                cl.known_bots.unset(bi);
            }
            continue;
        }
        self.harness.counters.inc(.replicate_candidates);
        const ecell = interest.cellOf(b.x, b.z);
        const in_range = interest.observerMask(game_mod.max_clients, obs_cx, obs_cz, obs_r, active, ecell.cx, ecell.cz);

        // Spawn-on-approach: the player-mesh body (hash 2001454542, the same
        // class_table[0] default a bot used as an ECS entity).
        var m = in_range;
        while (m != 0) : (m &= m - 1) {
            const ci = @ctz(m);
            const cl = &self.clients[ci];
            if (cl.known_bots.isSet(bi)) continue;
            const peer = cl.peer orelse continue;
            if (packages.stock_entity.buildEntitySpawnStock(&self.body_buf, .{
                .entity_id = b.net_id,
                .entity_class = packages.stock_entity.class_player_male,
                .x = b.x,
                .y = b.y,
                .z = b.z,
                .yaw = b.yaw,
                // The player-mesh class REQUIRES a player spawn info body; the
                // bot carries an operator/console name for this field. Without
                // it the builder refuses with MissingPlayerSpawnInfo, so a bot
                // would never appear on clients.
                .player = .{ .entity_name = botName(b) },
                .is_sleeper = false,
                .trader_data = null,
            })) |spb| {
                try self.sendGame(peer, "NetPackageEntitySpawn", spb);
                cl.known_bots.set(bi);
                self.harness.counters.inc(.replicate_fanouts);
                self.harness.counters.inc(.packages_encoded);
            } else |_| {
                self.harness.counters.inc(.encode_errors);
            }
        }

        // Range-remove: known but now out of the viewer's interest square.
        for (&self.clients, 0..) |*cl, ci| {
            if (!cl.known_bots.isSet(bi)) continue;
            if (!cl.joined or !cl.entered or !obs_ok[ci]) continue;
            const peer = cl.peer orelse continue;
            if (interest.cellsInRange(obs_cx[ci], obs_cz[ci], ecell.cx, ecell.cz, cl.view_radius)) continue;
            const rb = packages.buildRemoveBodyReason(&self.body_buf, b.net_id, .unloaded) catch {
                self.harness.counters.inc(.encode_errors);
                continue;
            };
            try self.sendGame(peer, "NetPackageEntityRemove", rb);
            cl.known_bots.unset(bi);
            self.harness.counters.inc(.packages_encoded);
        }

        // PosAndRot: a bot with a live move intent changes position every tick
        // (move_active), otherwise the heartbeat covers a stationary one. Bots
        // are not zombies, so no EntitySpeeds / AliveFlags.
        if (!heartbeat and !b.move_active) continue;
        if (in_range == 0) {
            self.harness.counters.inc(.replicate_encodes_skipped);
            continue;
        }
        const body = packages.buildPosAndRotBody(
            self.body_buf[0..game_mod.speeds_body_off],
            b.net_id,
            b.x,
            b.y,
            b.z,
            0,
            b.yaw,
            0,
            true,
        ) catch continue;
        const pos_framed = packages.framed(&pos_frame_buf, "NetPackageEntityPosAndRot", body) catch continue;
        self.harness.counters.inc(.packages_encoded);
        var vm = in_range;
        while (vm != 0) : (vm &= vm - 1) {
            const ci = @ctz(vm);
            const peer = self.clients[ci].peer orelse continue;
            self.sendFramedUnreliable(peer, pos_framed);
            self.harness.counters.inc(.replicate_fanouts);
        }
    }
}
