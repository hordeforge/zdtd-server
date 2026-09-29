//! World-tick drivers: powered doors, airdrop, zombie block damage,
//! stale locks/peers/policy, dead-entity reconcile, dig/sleeper drains,
//! look-at/attack-target, admin reload, client info. *Game helpers called
//! from step.zig; `game.zig` exposes forwarding methods.
//!
//! Split out of tick.zig (same functions, moved verbatim); buff-event
//! drivers and the survival VM stay in tick.zig.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const packages = @import("../../wire/packages.zig");
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const clock = @import("../../util/clock.zig");
const ln_peer = @import("../../litenet/peer.zig");
const io_fs = @import("../../util/io_fs.zig");
const admin_xml = @import("../admin_xml.zig");
const log = @import("../../util/log.zig");

/// Current whole world-hour (day*24 + hour), for time-based scheduling.
/// Power consumer actuation (RE tile-entities-power.md PowerConsumer
/// HandlePowerUpdate → `Block.ActivateBlock(world, pos, bv, IsPowered, ...)`):
/// a powered door block opens while its circuit delivers power and closes when
/// the power drops (load shed, fuel out, switch off). Uses the same open/close
/// meta bit + SetBlock broadcast as the zombie door-open path (tickZombieBlockDamage);
/// the per-node `net_powered` flip (previously never written) drives the
/// one-shot so a settled circuit does not re-broadcast every tick. The
/// powered-state echo for other consumer kinds (lights, traps) stays recorded
/// in GAP 4693.
pub fn actuatePoweredDoors(self: *Game) void {
    const grid = &self.sim.power;
    var i: usize = 0;
    while (i < grid.node_n) : (i += 1) {
        const n = &grid.nodes[i];
        if (n.kind != .consumer) continue;
        if (n.powered == n.net_powered) continue;
        n.net_powered = n.powered;
        const id = self.blockIdAtWorld(n.x, n.y, n.z);
        const def = self.blocks.byId(id) orelse continue;
        if (!def.is_door) continue;
        // A 2-tall door spans two cells; the vertical partner gets the same
        // open bit (the consumer node may sit on either half).
        const door_dys = [_]i32{ 0, 1, -1 };
        for (door_dys) |dy| {
            const yy = n.y + dy;
            if (self.blockIdAtWorld(n.x, yy, n.z) != id) continue;
            const raw = self.world.rawWorld(n.x, yy, n.z) catch continue;
            const open = (packages.blockMeta(raw) & packages.block_meta_on) != 0;
            if (open == n.powered) continue;
            const new_raw = packages.withBlockMeta(raw, if (n.powered) packages.block_meta_on else 0);
            self.world.setBlockRawWorld(n.x, yy, n.z, new_raw) catch continue;
            // Keep the sparse block_raw mirror coherent with the chunk plane
            // (GAP 13): a prior SetBlock can leave a closed-door hit that would
            // otherwise outrank the chunk on the next blockRawAt.
            self.setBlockRaw(n.x, yy, n.z, new_raw);
            if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], n.x, yy, n.z, new_raw, 0, -1, -1)) |sb| {
                self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(n.x), @floatFromInt(n.z), self.interest_range) catch {};
            } else |_| {}
        }
    }
}

pub fn worldHour(self: *const Game) u64 {
    const clk = self.sim.director.clock;
    return @as(u64, clk.day) * 24 + @as(u64, @trunc(clk.hours));
}

/// Next scheduled airdrop as a world-hour. "interval" (default): every
/// `AirDropFrequency` game-hours from the last drop (the pre-config behavior).
/// "days" (`[sim] airdrop_schedule = "days"`): the stock-like day-count + TOD
/// schedule - `SandboxOptions.SetupAirDropTimeRanges` (IL=124) maps options
/// 52/54 to Min/MaxDayCount + Min/MaxTimeOfDay (default 3/3 days, 12:00), and
/// `calcNextAirdrop` (IL=39) picks `day + RandomRange(Min, Max+1) - 1` at that
/// TOD; zdtd replays that deterministically (same seed → same schedule) by
/// scheduling at day_min + k*(day_max - day_min + 1) days at the drop hour.
pub fn nextAirdropHour(self: *const Game, now: u64) u64 {
    if (self.airdrop_schedule == .days) {
        const span: u64 = @max(1, @as(u64, self.airdrop_day_max) -| self.airdrop_day_min + 1);
        const start: u64 = @as(u64, self.airdrop_day_min) * 24 + self.airdrop_drop_hour;
        if (now < start) return start;
        return start + ((now - start) / (span * 24) + 1) * (span * 24);
    }
    return now + self.air_drop_interval_hours;
}

/// AirDropFrequency: spawn a supply crate near a player every N game-hours.
/// DIVERGENCE (RE: aidirector.md airdrop schedule): stock schedules by
/// DAY-COUNT + fixed time-of-day - see nextAirdropHour above; `[sim]
/// airdrop_schedule = "days"` restores that. Also: stock AirDropFrequency=0
/// does NOT disable (the sandbox option default overrides the 0 pref; live
/// getgamestat reads 3); zdtd's 0 = off is a deliberate policy difference.
pub fn tickAirDrop(self: *Game) void {
    const enabled = if (self.airdrop_schedule == .days)
        self.airdrop_day_max > 0
    else
        self.air_drop_interval_hours > 0;
    if (!enabled) return;
    const now = self.worldHour();
    if (self.next_air_drop_hour == 0) {
        self.next_air_drop_hour = nextAirdropHour(self, now);
        return;
    }
    if (now < self.next_air_drop_hour) return;
    self.next_air_drop_hour = nextAirdropHour(self, now);
    // Drop above the first joined player.
    for (&self.clients) |*cl| {
        if (!cl.joined) continue;
        const ps = self.sim.playerByPeer(cl.slot) orelse continue;
        const t = self.sim.transform[ps];
        if (self.sim.spawnLootBag(t.x, t.y + 2, t.z, 1, 1)) |bag_nid| {
            // `[sim] airdrop_loot_list` (default stock "airDrop"; the old
            // "supplyCrate" name does not exist in stock loot.xml and rolled
            // empty crates - fixed here).
            self.fillLootBagFromTable(bag_nid, self.airdrop_loot_list, @intCast(bag_nid), self.lootStageForPlayer(cl.slot));
            self.broadcastLootSpawn(bag_nid) catch {};
            // AIDirectorAirDropComponent.RefreshCrates (map-objects.md section
            // 8): the one server-push nav marker case, everything else is
            // client-derived. nav_object_classes.xml "supply_drop" is the
            // shipped class name (map/compass/onscreen icon lookup; no display
            // name needed). entity_id ties the marker to the bag so a future
            // NetPackageEntityMapMarkerRemove on crate death has something to
            // reference; not implemented yet, so the marker outlives the loot.
            if (self.sim.slotOfNetId(bag_nid)) |bi| self.sim.loot_bag[bi].supply_crate = true;
            if (packages.buildNavObjectAdd(self.body_buf[8192..8704], "supply_drop", "", t.x, t.y + 2, t.z, @intCast(bag_nid))) |nb| {
                self.broadcast("NetPackageNavObject", nb) catch {};
            } else |_| {}
            log.infoTagged("air drop supply crate at ({d:.0},{d:.0}) hour={d}\n", .{ t.x, t.z, now });
        }
        return;
    }
}

/// BlockDamageAI / AIBM: attacking zombies chew through a solid block between
/// them and their target. Scaled by BlockDamageAI (BlockDamageAIBM on blood moon).
pub fn tickZombieBlockDamage(self: *Game) void {
    // Sandbox `AllowZombieDigging` (stock `EntityMoveHelper.AllowZombieDigging`):
    // off means a zombie attacks but never breaks cover.
    if (!self.allow_zombie_digging) return;
    const mult: u32 = if (self.sim.director.bloodmoon_active) self.block_damage_ai_bm else self.block_damage_ai;
    if (mult == 0) return;
    // Per-class chew: the hand item's DamageBlock (zombie 8, feral 24) when
    // the class resolved one; the Rules floor otherwise.
    const base_bite: u32 = @trunc(@max(0, self.sim.rules.progression.block_bite_damage));
    // Cached zombie group: this pass only damages blocks, never spawns or
    // destroys entities, so the slice stays valid for the whole loop.
    for (ecs.groupSlice(&self.sim, .zombie)) |s| {
        const ai = self.sim.zombie_ai[s];
        if (ai.state != .attack and ai.state != .chase) continue;
        // `EAIBreakBlock.Update` counts a per-zombie `attackDelay` down before
        // `AttackBlock` strikes again (1.0-1.8 s, entity-ai.md:1817-1825). The
        // pass runs every 10 ticks, so without this gate one zombie chewed the
        // same cover 2-3x stock's rate.
        if (ai.block_attack_cd > 0) continue;
        const tgt = self.sim.slotOfNetId(ai.target_id) orelse continue;
        const zt = self.sim.transform[s];
        const tt = self.sim.transform[tgt];
        var dx = tt.x - zt.x;
        var dz = tt.z - zt.z;
        const len = @sqrt(dx * dx + dz * dz);
        const block_range = @max(0.1, self.sim.rules.progression.block_damage_range);
        if (len < 0.1 or len > block_range) continue; // only when pressed against cover
        dx /= len;
        dz /= len;
        const bx: i32 = @floor(zt.x + dx);
        const bz: i32 = @floor(zt.z + dz);
        // The cell the zombie collides with sits at its body height: probe
        // the front column from feet to head and chew the first solid cell.
        // The old single head-height probe left zombies stuck against
        // 1-block-tall walls/fences (the head cell is air while the wall is
        // at feet level), so they never broke out.
        const feet_y: i32 = @floor(zt.y);
        const head_y: i32 = @floor(zt.y + 1);
        const by: i32 = blk: {
            var yi: i32 = feet_y;
            while (yi <= head_y) : (yi += 1) {
                if (self.world.isSolidWorld(bx, yi, bz) catch false) break :blk yi;
            }
            break :blk -1;
        };
        if (by < 0) continue;
        const id = self.blockIdAtWorld(bx, by, bz);
        if (id == 0) continue;
        // Zombies open unlocked doors on their path instead of chewing (RE
        // entity-ai.md CheckForDoorAndOpen: block with the door tag +
        // TEFeatureDoor, SetOpen when not open). Set the open meta bit and
        // broadcast; an already-open door is skipped (no re-broadcast). A
        // 2-tall door spans two cells, so the vertical partner gets the same
        // open bit (the probe may have landed on either half).
        if (self.blocks.byId(id)) |def| {
            if (def.is_door) {
                const door_dys = [_]i32{ 0, 1, -1 };
                for (door_dys) |dy| {
                    const yy = by + dy;
                    if (self.blockIdAtWorld(bx, yy, bz) != id) continue;
                    const raw = self.world.rawWorld(bx, yy, bz) catch continue;
                    if ((packages.blockMeta(raw) & packages.block_meta_on) != 0) continue;
                    const open_raw = packages.withBlockMeta(raw, packages.block_meta_on);
                    self.world.setBlockRawWorld(bx, yy, bz, open_raw) catch continue;
                    // Same mirror write-through as actuatePoweredDoors: chunk is
                    // SoT, but a stale sparse hit must not report the door closed.
                    self.setBlockRaw(bx, yy, bz, open_raw);
                    if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], bx, yy, bz, open_raw, 0, -1, -1)) |sb| {
                        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                    } else |_| {}
                }
                continue;
            }
        }
        // Per-class chew: hand-item DamageBlock (zombie 8, feral 24) beats
        // the flat Rules floor when the class resolved one.
        const chew: u32 = if (self.sim.class_id[s].block_chew > 0)
            @trunc(self.sim.class_id[s].block_chew)
        else
            base_bite;
        // Ally boost: each other zombie within the stock +-(1.7,1.5,1.7) box
        // adds 20% (`damageBoostPercent += 0.2`, EAIBreakBlock.AttackBlock
        // IL=118), which is what makes a pack break a wall faster than one.
        const allies = systems.ai_tasks.blockAttackAllyCount(&self.sim, s);
        const dmg_u32 = chew * mult * (100 + 20 * allies) / 10_000;
        const dmg: u16 = @intCast(@min(dmg_u32, 65535));
        const max_hp = self.maxDamageForBlock(id);
        const total = self.addBlockDamage(bx, by, bz, dmg) catch continue;
        if (total >= max_hp) {
            // Downgrade swap (stock Block.OnBlockDamaged): a block with a
            // DowngradeBlock turns into it instead of breaking.
            const down_raw = self.downgradeBreakRaw(bx, by, bz, id);
            if (down_raw != 0) {
                // The downgrade replaces the block, so the old one is gone
                // even though the cell stays occupied: its node, container
                // and vending entry go with it, same as a break.
                self.noteBlockRemoved(bx, by, bz, id);
                _ = self.world.setBlockRawWorld(bx, by, bz, down_raw) catch continue;
                // ...and the block it turned into claims what its own type
                // owns: a downgrade that lands a powered block needs a node.
                self.noteBlockAdded(bx, by, bz, world_store.typeId(down_raw));
                self.clearBlockHp(bx, by, bz);
                self.clearBlockRaw(bx, by, bz);
                if (packages.buildSetBlockBodyRaw(&self.body_buf, bx, by, bz, down_raw, 0, -1, -1)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                } else |_| {}
            } else {
                // A removed bedroll clears the owner's respawn point.
                self.noteBlockRemoved(bx, by, bz, id);
                self.world.setBlockWorld(bx, by, bz, 0) catch continue;
                self.clearBlockHp(bx, by, bz);
                self.clearBlockRaw(bx, by, bz);
                if (packages.buildSetBlockBody(&self.body_buf, bx, by, bz, 0)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(bx), @floatFromInt(bz), self.interest_range) catch {};
                } else |_| {}
            }
        } else {
            // Survived the bite: stock still replicates the damage change
            // (Block::OnBlockDamaged IL_0457), so a watching client sees the
            // block crack instead of a pristine cell until it breaks.
            self.echoBlockDamage(bx, by, bz, id, total);
        }
        // Arm the next strike (`EAIBreakBlock.AttackBlock` installs the rolled
        // delay after a successful hit). `continue` above skipped the door-open
        // arm, which is not a strike and must not consume one.
        self.sim.zombie_ai[s].block_attack_cd = systems.ai_tasks.rollBlockAttackDelay(&self.sim, s);
    }
}

/// Drop locks held longer than the lock stale window (tick path).
pub fn reapStaleLocks(self: *Game) void {
    const now = clock.monoNs();
    for (&self.lock_channel, 0..) |h, i| {
        if (h < 0) continue;
        const g = self.lock_granted_ns[i];
        if (g == 0) continue;
        if (now -% g >= self.lock_stale_ns) self.clearLockSlot(i);
    }
}

/// Free a reaped peer's transport state before the session teardown runs:
/// the pending reliable window would otherwise keep retransmitting to an
/// address nobody is listening on until the slot is reused.
fn releaseReapedPeer(p: *ln_peer.Peer) void {
    p.alive = false;
    p.authenticated = false;
    for (&p.pending) |*slot| slot.used = false;
    p.local_window_start = p.local_seq;
}

pub fn reapStalePeers(self: *Game) void {
    const now = clock.monoNs();
    const stale_ns: u64 = self.peer_stale_ms *| 1_000_000;
    // Stock MaxDurationInAuthState (10 s): the auth sweep runs off the
    // challenge issue time, not RX silence, so a peer that keeps the socket
    // warm with junk but never echoes is still reaped.
    const auth_ns: u64 = game_mod.default_auth_state_ms *| 1_000_000;
    for (&self.clients) |*c| {
        const p = c.peer orelse continue;
        if (!p.alive) {
            self.harness.counters.inc(.stale_peers_reaped);
            log.infoTagged(
                "peer reaped dead local_id={d} slot={d} entity={d}\n",
                .{ p.local_id, c.slot, c.entity_id },
            );
            // One drop path owns the teardown (persist, party removal, claims,
            // EntityRemove fan-out, sim destroy) - see clientFor, which hit the
            // same bug. The hand-rolled `c.* = .{}` here left the sim player
            // entity alive as a ghost every other client kept rendering,
            // because nothing broadcast NetPackageEntityRemove.
            self.dropClientSlot(c.slot, "reap-dead");
            continue;
        }
        if (p.last_recv_ns == 0) continue;
        // Auth-state age (stock MaxDurationInAuthState): a peer that never
        // echoed the challenge is reaped past the age cap even when it keeps
        // receiving (RX silence alone never fires: last_recv_ns updates on
        // every datagram, including junk). Authenticated peers have
        // challenge_ns == 0 and skip this arm.
        if (c.challenge_ns != 0 and now -% c.challenge_ns > auth_ns) {
            self.harness.counters.inc(.stale_peers_reaped);
            log.warn(
                "peer reaped in-auth (never echoed the challenge) local_id={d} slot={d} age_ms={d}\n",
                .{ p.local_id, c.slot, (now -% c.challenge_ns) / 1_000_000 },
            );
            releaseReapedPeer(p);
            self.dropClientSlot(c.slot, "reap-auth");
            continue;
        }
        if (now -% p.last_recv_ns > stale_ns) {
            self.harness.counters.inc(.stale_peers_reaped);
            log.infoTagged(
                "peer reaped stale local_id={d} slot={d} entity={d} idle_ms={d}\n",
                .{ p.local_id, c.slot, c.entity_id, (now -% p.last_recv_ns) / 1_000_000 },
            );
            releaseReapedPeer(p);
            self.dropClientSlot(c.slot, "reap-stale");
        }
    }
}

/// Drop armed policy kicks once the stock 0.5 s grace has elapsed.
/// Bounded by max_clients per tick.
pub fn reapPolicyKicks(self: *Game) void {
    for (&self.clients, 0..) |*cl, i| {
        if (cl.guard.kick_at_tick == 0) continue;
        if (self.tick_n < cl.guard.kick_at_tick) continue;
        if (cl.peer == null) {
            cl.guard.kick_at_tick = 0;
            continue;
        }
        self.dropClientSlot(i, "guard");
    }
}

pub fn clearDeadKnownEntities(self: *Game) void {
    // Most ticks free no slots; skip the reconcile entirely.
    if (!self.sim.any_freed_this_tick) return;
    // Word-wise AND per client against the sim's live set, instead of a
    // per-slot × per-client unset sweep (512×64 every tick).
    for (&self.clients) |*kc| kc.known_entities.setIntersection(self.sim.alive_bits);
    self.sim.any_freed_this_tick = false;
}

/// Drain MoveHelper dig damage requests (RE entity-ai.md DigUpdate): each
/// request damages the sim-marked block with the chew's bite damage; a broken
/// block ends the dig so the zombie walks on.
pub fn drainDigRequests(self: *Game) void {
    // Sandbox `AllowZombieDigging`: the MoveHelper dig leg is gated by the same
    // switch as the chew pass, and its queued requests are dropped rather than
    // held for the tick the option comes back.
    if (!self.allow_zombie_digging) {
        self.sim.dig_n = 0;
        return;
    }
    const mult: u32 = if (self.sim.director.bloodmoon_active) self.block_damage_ai_bm else self.block_damage_ai;
    if (mult == 0) return;
    // Per-class chew floor: hand-item DamageBlock beats the flat Rules value.
    const base_bite: u32 = @trunc(@max(0, self.sim.rules.progression.block_bite_damage));
    const n = @min(self.sim.dig_n, self.sim.dig_reqs.len);
    self.sim.dig_n = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const d = self.sim.dig_reqs[i];
        if (!self.sim.alive[d.slot]) continue;
        const solid = self.world.isSolidWorld(d.x, d.y, d.z) catch continue;
        if (!solid) {
            self.sim.zombie_ai[d.slot].digging = false;
            continue;
        }
        const id = self.blockIdAtWorld(d.x, d.y, d.z);
        if (id == 0) continue;
        const chew: u32 = if (self.sim.class_id[d.slot].block_chew > 0)
            @trunc(self.sim.class_id[d.slot].block_chew)
        else
            base_bite;
        const dmg: u16 = @intCast(@min(chew * mult / 100, 65535));
        const max_hp = self.maxDamageForBlock(id);
        const total = self.addBlockDamage(d.x, d.y, d.z, dmg) catch continue;
        if (total >= max_hp) {
            // Downgrade swap (stock Block.OnBlockDamaged): a block with a
            // DowngradeBlock turns into it instead of breaking.
            const down_raw = self.downgradeBreakRaw(d.x, d.y, d.z, id);
            if (down_raw != 0) {
                // Same as the damage-break downgrade above: the old block is
                // displaced, so its side state goes with it.
                self.noteBlockRemoved(d.x, d.y, d.z, id);
                _ = self.world.setBlockRawWorld(d.x, d.y, d.z, down_raw) catch continue;
                self.noteBlockAdded(d.x, d.y, d.z, world_store.typeId(down_raw));
                self.clearBlockHp(d.x, d.y, d.z);
                self.clearBlockRaw(d.x, d.y, d.z);
                self.sim.zombie_ai[d.slot].digging = false;
                if (packages.buildSetBlockBodyRaw(&self.body_buf, d.x, d.y, d.z, down_raw, 0, -1, -1)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(d.x), @floatFromInt(d.z), self.interest_range) catch {};
                } else |_| {}
            } else {
                // A removed bedroll clears the owner's respawn point.
                self.noteBlockRemoved(d.x, d.y, d.z, id);
                self.world.setBlockWorld(d.x, d.y, d.z, 0) catch continue;
                self.clearBlockHp(d.x, d.y, d.z);
                self.clearBlockRaw(d.x, d.y, d.z);
                self.sim.zombie_ai[d.slot].digging = false;
                if (packages.buildSetBlockBody(&self.body_buf, d.x, d.y, d.z, 0)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(d.x), @floatFromInt(d.z), self.interest_range) catch {};
                } else |_| {}
            }
        } else {
            // MoveHelper dig damage is a damage change like any other: stock
            // replicates it (Block::OnBlockDamaged IL_0457) so the wall visibly
            // cracks while the zombie digs in.
            self.echoBlockDamage(d.x, d.y, d.z, id, total);
        }
    }
}

/// Drain vomit block impacts (ItemActionProjectile.DamageBlock, stock vomit
/// 120). advanceSpit retires the shot on a solid cell and pushes it; this
/// applies the shooter's projectile_block_damage through the same break path
/// the dig drain uses. Consume-owns-drain.
pub fn drainSpitHits(self: *Game) void {
    const n = @min(self.sim.spit_hit_n, self.sim.spit_hit_reqs.len);
    self.sim.spit_hit_n = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const h = self.sim.spit_hit_reqs[i];
        if (!self.sim.alive[h.slot]) continue;
        const raw: f32 = self.sim.class_id[h.slot].projectile_block_damage;
        if (!(raw > 0)) continue;
        const id = self.blockIdAtWorld(h.x, h.y, h.z);
        if (id == 0) continue;
        // The ammo's tagged DamageModifier rows (stock vomit zeroes earth and
        // halves stone) are not folded here: they need the per-hit item query
        // the block path does not run. Recorded, not applied.
        const dmg: u16 = @intCast(@min(@as(u32, @trunc(raw)), 65535));
        if (dmg == 0) continue;
        const max_hp = self.maxDamageForBlock(id);
        const total = self.addBlockDamage(h.x, h.y, h.z, dmg) catch continue;
        if (total < max_hp) {
            self.echoBlockDamage(h.x, h.y, h.z, id, total);
            continue;
        }
        const down_raw = self.downgradeBreakRaw(h.x, h.y, h.z, id);
        if (down_raw != 0) {
            self.noteBlockRemoved(h.x, h.y, h.z, id);
            _ = self.world.setBlockRawWorld(h.x, h.y, h.z, down_raw) catch continue;
            self.noteBlockAdded(h.x, h.y, h.z, world_store.typeId(down_raw));
            self.clearBlockHp(h.x, h.y, h.z);
            self.clearBlockRaw(h.x, h.y, h.z);
            if (packages.buildSetBlockBodyRaw(&self.body_buf, h.x, h.y, h.z, down_raw, 0, -1, -1)) |sb| {
                self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(h.x), @floatFromInt(h.z), self.interest_range) catch {};
            } else |_| {}
        } else {
            self.noteBlockRemoved(h.x, h.y, h.z, id);
            self.world.setBlockWorld(h.x, h.y, h.z, 0) catch continue;
            self.clearBlockHp(h.x, h.y, h.z);
            self.clearBlockRaw(h.x, h.y, h.z);
            if (packages.buildSetBlockBody(&self.body_buf, h.x, h.y, h.z, 0)) |sb| {
                self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(h.x), @floatFromInt(h.z), self.interest_range) catch {};
            } else |_| {}
        }
    }
}

/// Drain sleeper wake requests (RE EntityAlive.ConditionalTriggerSleeperWakeUp:
/// broadcasts NetPackageSleeperWakeup, unreliable, to every client when a
/// sleeper zombie wakes - proximity, noise or damage; protocol-packages.md
/// §6.19). Consume-owns-drain like the dig ring. Broadcast, not interest
/// gated: stock ConnectionManager.SendPackage with toEntityId=-1 reaches all
/// clients, and a distant POI waking matters for a client's minimap/audio.
pub fn drainSleeperWakeups(self: *Game) void {
    const n = @min(self.sim.sleeper_wake_n, self.sim.sleeper_wake_reqs.len);
    self.sim.sleeper_wake_n = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s: u16 = self.sim.sleeper_wake_reqs[i].slot;
        if (!self.sim.alive[s] or !self.sim.mask[s].network_id) continue;
        const nid = self.sim.network_id[s].id;
        // RE EntityAlive.SetSleeperActive (IL=26): a stirred sleeper sends
        // NetPackageSleeperPassiveChange (the client clears IsSleeperPassive
        // and plays the groan); a woken one gets NetPackageSleeperWakeup.
        if (self.sim.sleeper_wake_reqs[i].groan) {
            if (packages.buildSleeperPassiveChangeBody(&self.body_buf, nid)) |body| {
                self.broadcast("NetPackageSleeperPassiveChange", body) catch {};
            } else |_| {}
            continue;
        }
        if (packages.buildSleeperWakeupBody(&self.body_buf, nid)) |body| {
            self.broadcast("NetPackageSleeperWakeup", body) catch {};
        } else |_| {}
    }
}

/// EntityAlive look-at sync (RE protocol-packages.md §5.2.1): broadcasts
/// NetPackageEntityLookAt to tracking players when an awake zombie's look
/// target moves past the stock 0.0016 sqr-delta gate (EntityAlive
/// SetLookPosition, SendPacketToTrackedPlayers). Target = the AI's attack
/// target position, else the investigate spot. Cosmetic head-aim only; no
/// sim authority. The per-slot last-sent state skips re-sends between
/// meaningful target changes.
pub fn tickEntityLookAt(self: *Game) void {
    for (self.sim.kind_groups.slice(.zombie)) |s| {
        if (!self.sim.alive[s] or !self.sim.mask[s].network_id or !self.sim.mask[s].zombie_ai) continue;
        if (!self.sim.mask[s].transform) continue;
        const ai = self.sim.zombie_ai[s];
        if (!ai.alert and !ai.has_spot) continue;
        if (self.sim.mask[s].sleeper and !self.sim.sleeper[s].awake) continue;
        var lx: f32 = 0;
        var ly: f32 = 0;
        var lz: f32 = 0;
        var have = false;
        if (ai.target_id >= 0) {
            if (self.sim.slotOfNetId(ai.target_id)) |t| {
                if (self.sim.alive[t] and self.sim.mask[t].transform) {
                    lx = self.sim.transform[t].x;
                    ly = self.sim.transform[t].y;
                    lz = self.sim.transform[t].z;
                    have = true;
                }
            }
        }
        if (!have and ai.has_spot) {
            lx = ai.spot_x;
            ly = self.sim.transform[s].y;
            lz = ai.spot_z;
            have = true;
        }
        if (!have) continue;
        const st = &self.entity_look_sent[s];
        // Slot recycled onto a new entity: the previous occupant's last-sent
        // target must not gate this one's first look (spawnBase bumped gen).
        if (st.gen != self.sim.network_id[s].gen) st.* = .{ .gen = self.sim.network_id[s].gen };
        const dx = lx - st.x;
        const dy = ly - st.y;
        const dz = lz - st.z;
        if (st.sent and dx * dx + dy * dy + dz * dz < 0.0016) continue;
        st.x = lx;
        st.y = ly;
        st.z = lz;
        st.sent = true;
        if (packages.buildEntityLookAtBody(&self.body_buf, self.sim.network_id[s].id, lx, ly, lz)) |body| {
            self.broadcastNear("NetPackageEntityLookAt", body, self.sim.transform[s].x, self.sim.transform[s].z, self.interest_range) catch {};
        } else |_| {}
    }
}

/// NetPackageSetAttackTarget S2C. Stock fans this out from every server-side
/// attack-target change: `EntityAlive::SetAttackTarget` (IL=70) sends
/// `Setup(entityId, target ? target.entityId : -1)`, and the expiry path in
/// `OnUpdateLive` (IL=363) sends `Setup(entityId, -1)` when attackTargetTime
/// runs out. The client stores it as `attackTargetClient`, which is what
/// `GetAttackTargetLocal` returns for a remote entity (the drone beam and the
/// DynamicMusic threat level read it).
///
/// zdtd picks targets in the sim (`ai.target_id`) and never published them, so
/// remote clients saw every zombie as untargeted. This is the edge detector:
/// stock's per-change sends become a per-tick diff against the last published
/// value, which is the same traffic without mirroring stock's call sites.
pub fn tickAttackTarget(self: *Game) void {
    for (self.sim.kind_groups.slice(.zombie)) |s| {
        if (!self.sim.alive[s] or !self.sim.mask[s].network_id or !self.sim.mask[s].zombie_ai) continue;
        if (!self.sim.mask[s].transform) continue;
        // A sleeping sleeper has no live target to advertise, and waking is
        // its own package (drainSleeperWakeups).
        if (self.sim.mask[s].sleeper and !self.sim.sleeper[s].awake) continue;
        const st = &self.attack_target_sent[s];
        // Slot recycled onto a new entity: the previous occupant's last-sent
        // target must not gate this one's first send (spawnBase bumped gen).
        if (st.gen != self.sim.network_id[s].gen) st.* = .{ .gen = self.sim.network_id[s].gen };
        // Stock's wire value: -1 when there is no target, and equally when the
        // target is gone, since a dead entity is not a target any more.
        var want: i32 = -1;
        const tid = self.sim.zombie_ai[s].target_id;
        if (tid >= 0) {
            if (self.sim.slotOfNetId(tid)) |t| {
                // alive[] is slot occupancy, not vitality: markPlayerDead and
                // markCorpse both keep the slot and only clamp hp to 0, so an
                // alive[] test alone advertised a corpse as the target until
                // the sweep recycled it. No health column keeps the old answer.
                const dead = self.sim.mask[t].health and self.sim.health[t].hp <= 0;
                if (self.sim.alive[t] and !dead) want = tid;
            }
        }
        if (st.sent and st.id == want) continue;
        st.id = want;
        st.sent = true;
        if (packages.buildSetAttackTargetBody(&self.body_buf, self.sim.network_id[s].id, want)) |body| {
            self.broadcastNear("NetPackageSetAttackTarget", body, self.sim.transform[s].x, self.sim.transform[s].z, self.interest_range) catch {};
        } else |_| {}
    }
}

/// NetPackageClientInfo broadcast (RE ConnectionManager.updateClientInfo:
/// 5 s cadence): the per-player list (entityId, ping, admin flag) that drives
/// the player list UI and admin crowns. Ping is 0 (zdtd has no RTT
/// measurement; documented residual), admin = the name is in the permission
/// list.
/// Stock serveradmin.xml hot-reload (AdminTools.InitFileWatcher ->
/// OnFileChanged -> Load, IL=33/5): poll the file's mtime every 5 s and
/// re-apply the XML on change. The .zsv list files stay the runtime-persisted
/// form, so an operator editing serveradmin.xml while the server runs sees
/// the change without a restart (bans, whitelist and admin levels).
pub fn tickServerAdminReload(self: *Game) void {
    if (self.serveradmin_reload_timer > 0) {
        self.serveradmin_reload_timer -= 1;
        return;
    }
    self.serveradmin_reload_timer = 100; // 5 s at 20 TPS
    const path = self.serveradmin_path orelse return;
    const mtime = io_fs.fileMtimeNanos(path) orelse return;
    if (mtime == self.serveradmin_mtime) return;
    self.serveradmin_mtime = mtime;
    // Replace the XML-sourced portion (entries removed from the file must
    // disappear); runtime (.zsv) entries are untouched.
    self.admin_list.clearXml();
    self.whitelist.clearXml();
    self.ban_list.clearXml();
    admin_xml.load(self.allocator, path, &self.admin_list, &self.whitelist, &self.ban_list) catch |err| {
        log.warn("serveradmin.xml reload failed: {s}\n", .{@errorName(err)});
        return;
    };
    log.infoTagged("serveradmin.xml reloaded (mtime {d})\n", .{mtime});
}

pub fn tickClientInfo(self: *Game) void {
    if (self.client_info_timer > 0) {
        self.client_info_timer -= 1;
        return;
    }
    self.client_info_timer = 100; // 5 s at 20 TPS (stock timer value)
    var entries: [game_mod.max_clients]packages.ClientInfoEntry = undefined;
    var n: usize = 0;
    for (&self.clients) |*c| {
        if (!c.joined or c.entity_id <= 0) continue;
        if (n >= entries.len) break;
        // Admin flag: same hit rule as permLevelOf / whitelist (platform
        // composite when present; name only for no-platform sessions).
        const is_admin = self.permissionListHit(&self.admin_list, c);
        entries[n] = .{ .entity_id = c.entity_id, .ping_ms = 0, .admin = is_admin };
        n += 1;
    }
    if (n == 0) return;
    if (packages.buildClientInfoBody(&self.body_buf, entries[0..n])) |body| {
        self.broadcast("NetPackageClientInfo", body) catch {};
    } else |_| {}
}

pub fn pushBloodMoonBonus(self: *Game, stage: i32) void {
    const cfg = self.gamestages.config;
    // No gamestages.xml means no cadence to push. Clamping the absent 0
    // up to 1 would overwrite the director's stock defaults with "bonus
    // on every spawn, unscaled", which is the opposite of the intent.
    if (cfg.loot_bonus_every <= 0) return;
    var every: u32 = @max(1, @as(u32, @intCast(@max(0, cfg.loot_bonus_every))));
    if (self.gamestages.spawnerByName(ecs.aidirector.Director.bloodmoon_spawner)) |sp| {
        if (sp.getStage(stage)) |st| {
            var sum: u32 = 0;
            for (st.spawns) |sg| sum +|= sg.num;
            const maxc: u32 = @max(1, @as(u32, @intCast(@max(0, cfg.loot_bonus_max_count))));
            const cadence: u32 = @max(sum / maxc, @as(u32, @intCast(@max(0, cfg.loot_bonus_every))));
            every = @max(1, cadence);
        }
    }
    const scale: f32 = if (cfg.loot_bonus_scale > 0) cfg.loot_bonus_scale else 1.0;
    self.sim.director.setBloodMoonBonusParams(every, scale);
}

pub fn sampleFlushCounters(self: *Game) void {
    const f = &self.world.flush;
    const q = f.queued.load(.monotonic);
    const w = f.written.load(.monotonic);
    const e = f.errors.load(.monotonic);
    const s = self.world.sync_fallbacks.load(.monotonic);
    const wt = f.waits.load(.monotonic);
    self.harness.counters.add(.chunk_flush_queued, q -| self.flush_seen.queued);
    self.harness.counters.add(.chunk_flush_written, w -| self.flush_seen.written);
    self.harness.counters.add(.chunk_flush_errors, e -| self.flush_seen.errors);
    self.harness.counters.add(.chunk_flush_sync, s -| self.flush_seen.sync);
    self.harness.counters.add(.chunk_flush_waits, wt -| self.flush_seen.waits);
    // Async writes fail off-tick, so persistence_errors would otherwise
    // never see them (saveAll returns before the write happens).
    self.harness.counters.add(.persistence_errors, e -| self.flush_seen.errors);
    self.flush_seen = .{ .queued = q, .written = w, .errors = e, .sync = s, .waits = wt };
}
