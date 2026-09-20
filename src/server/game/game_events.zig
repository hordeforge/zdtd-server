//! gameevents.xml sequence runner (server side).
//!
//! The death and respawn families are the sequences a dedicated server has to
//! execute: `EntityPlayer.HandleClientDeath` runs `game_on_death_*` and the
//! client's respawn flow asks the server for `game_on_respawn_*` through
//! NetPackageGameEventRequest (`GameEventManager::HandleActionClient` IL=416
//! only sends the request; the server branch IL_006B executes it). Running the
//! parsed data here is what keeps respawn stats out of the code: the old
//! funnel hardcoded `hp = 100; max_hp = 100` where
//! `game_on_respawn_default` says `ModifyEntityStat Food/Water/Health/Stamina
//! SetMax` and `game_on_respawn_injured` says Food/Water `Set .5 is_percent`.
//!
//! Fail closed: an unsupported sequence, an unknown buff/stat, or a missing
//! table runs nothing at all (`missing beats fake`).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const assets_gameevents = @import("../../assets/gameevents.zig");
const ecs = @import("../../ecs/root.zig");
const xml = @import("../../assets/xml_util.zig");
const social = @import("social.zig");
const packages = @import("../../wire/packages.zig");

/// Which `game_on_respawn_*` sequence the DeathPenalty stat selects
/// (PlayerMoveController::updateRespawn IL=0E38 switches 0..3). Null for a
/// penalty value outside the enum.
pub fn respawnSequenceName(penalty: u8) ?[]const u8 {
    return switch (penalty) {
        0 => "game_on_respawn_none",
        1 => "game_on_respawn_default",
        2 => "game_on_respawn_injured",
        3 => "game_on_respawn_permanent",
        else => null,
    };
}

/// Which `game_on_death_*` sequence the DeathPenalty stat selects
/// (EntityPlayer::HandleClientDeath IL=71 switches on the same stat the
/// client's respawn does).
pub fn deathSequenceName(penalty: u8) ?[]const u8 {
    return switch (penalty) {
        0 => "game_on_death_none",
        1 => "game_on_death_default",
        2 => "game_on_death_injured",
        3 => "game_on_death_permanent",
        else => null,
    };
}

/// Run one parsed sequence for a player. Returns true when it ran; false when
/// the table is absent, the name is unknown, the sequence is unsupported, or
/// the peer has no live player.
pub fn runGameEventSequence(self: *Game, peer_slot: usize, name: []const u8) bool {
    const seq = self.gameevents.find(name) orelse return false;
    if (!seq.supported) return false;
    const ps = self.sim.playerByPeer(peer_slot) orelse return false;
    if (!self.sim.mask[ps].health) return false;
    // Sequence-level RandomRoll (church-bell LTE 99): fail closed means the
    // sequence does not run, not that the server errors.
    if (seq.has_random_roll and !sequenceRollHolds(self, ps, seq)) return false;
    // Client legs ride one ClientSequenceAction response each, keyed
    // `Name<index>` off the parsed order (SetActionKeyData), which is how stock
    // hands the work back to the client that asked for the sequence
    // (ActionBaseClientAction: the server has no OnPerform for those legs).
    const entity_id = self.sim.network_id[ps].id;
    for (seq.actions, 0..) |a, idx| {
        switch (a.class) {
            .modify_entity_stat => applyStat(self, ps, a),
            .remove_death_buffs => removeDeathBuffs(self, peer_slot, ps, a.exclude_tags),
            .add_buff => {
                if (requirementHolds(self, peer_slot, a)) {
                    applyBuff(self, peer_slot, ps, a.buff_name);
                }
            },
            .modify_cvar => {
                const op = assetOp(a.cvar_op) orelse continue;
                const cl = &self.clients[peer_slot];
                // The store keeps the name pointer, so the arena-owned name
                // from the parsed table is what goes in.
                _ = cl.cvars.apply(a.cvar, op, a.value);
            },
            .spawn_entity => spawnEventGroup(self, ps, a),
            .rage_zombies => rageNearbyZombies(self, ps, a),
            // Item actions and AddXPDeficit have no server-side work; the
            // response above is the whole server leg.
            .remove_items, .add_starting_items, .add_items, .add_xp_deficit => {},
        }
        if (assets_gameevents.isClientAction(a.class)) {
            sendClientSequenceAction(self, peer_slot, name, entity_id, idx);
        }
    }
    return true;
}

/// One `ClientSequenceAction` (response type 12) telling the client to run the
/// action at `index` of `seq_name`. Keyed `Name<index>`, stock's root action key.
fn sendClientSequenceAction(self: *Game, peer_slot: usize, seq_name: []const u8, entity_id: i32, index: usize) void {
    const cl = &self.clients[peer_slot];
    const peer = cl.peer orelse return;
    var key_buf: [96]u8 = undefined;
    // Stock keys a root action `<sequenceName><index>` and a nested one
    // `<parentKey>:<index>` (BaseAction::SetActionKeyData IL=23). The parsed
    // sequences here are flat, so the root form is the one that matters.
    const key = std.fmt.bufPrint(&key_buf, "{s}{d}", .{ seq_name, index }) catch return;
    if (packages.buildGameEventSequenceAction(self.body_buf[200..456], seq_name, entity_id, key)) |body| {
        self.sendGame(peer, "NetPackageGameEventResponse", body) catch {
            self.harness.counters.inc(.net_send_errors);
        };
    } else |_| {}
}

const assets_cvars = @import("../../assets/cvars.zig");
const rng_util = @import("../../util/rng.zig");

/// `<property name="operation">` of a ModifyCVar action.
fn assetOp(name: []const u8) ?assets_cvars.Operation {
    if (std.ascii.eqlIgnoreCase(name, "set")) return .set;
    if (std.ascii.eqlIgnoreCase(name, "setvalue")) return .setvalue;
    if (std.ascii.eqlIgnoreCase(name, "add")) return .add;
    if (std.ascii.eqlIgnoreCase(name, "subtract")) return .subtract;
    if (std.ascii.eqlIgnoreCase(name, "multiply")) return .multiply;
    if (std.ascii.eqlIgnoreCase(name, "divide")) return .divide;
    if (std.ascii.eqlIgnoreCase(name, "percent_add")) return .percent_add;
    if (std.ascii.eqlIgnoreCase(name, "percent_subtract")) return .percent_subtract;
    return null;
}

/// Sequence-level RandomRoll (same FastLerp compare as requirements.RandomRoll).
fn sequenceRollHolds(self: *Game, ps: ecs.Slot, seq: *const assets_gameevents.Sequence) bool {
    const seed: u32 = @truncate(@as(u64, @bitCast(@as(i64, self.sim.network_id[ps].id))) ^ self.tick_n ^ 0x9e3779b9);
    var rng = rng_util.XorShift32.init(seed);
    const f = @as(f32, @floatFromInt(rng.next() >> 8)) / 16777216.0;
    const rolled = seq.roll_min + (seq.roll_max - seq.roll_min) * f;
    return switch (seq.roll_op) {
        .gt => rolled > seq.roll_value,
        .gte => rolled >= seq.roll_value,
        .lt => rolled < seq.roll_value,
        .lte => rolled <= seq.roll_value,
        .equals => rolled == seq.roll_value,
        .not_equals => rolled != seq.roll_value,
        .unknown => false,
    };
}

/// `SpawnEntity`: pick `spawn_count` names from the stock entity group and
/// spawn them in an arc `[min_distance, max_distance]` from the player. The
/// church-bell horde (SleeperGSList x4, aggressive WanderingHorde) uses this.
fn spawnEventGroup(self: *Game, ps: ecs.Slot, a: assets_gameevents.Action) void {
    if (a.entity_group.len == 0 or a.spawn_count == 0) return;
    if (!self.sim.mask[ps].transform) return;
    const px = self.sim.transform[ps].x;
    const py = self.sim.transform[ps].y;
    const pz = self.sim.transform[ps].z;
    const player_id = self.sim.network_id[ps].id;
    const stage: i32 = @max(0, self.partyStageAround(px, pz, self.sleeper_party_radius));
    const stage_spawn = self.gamestages.sleeperEntityGroup(a.entity_group, stage);
    var rng = rng_util.XorShift32.initFromNetId(
        @bitCast(@as(u32, @truncate(self.sim.director.clock.worldTimeBits())) ^ @as(u32, @bitCast(player_id))),
    );
    const min_d = a.min_distance;
    const max_d = if (a.max_distance > min_d) a.max_distance else min_d;
    var n: u8 = 0;
    while (n < a.spawn_count) : (n += 1) {
        const def = self.resolveSleeperClass(a.entity_group, stage_spawn, rng.next());
        const ang = @as(f32, @floatFromInt(rng.nextBounded(6283))) / 1000.0;
        const span = max_d - min_d;
        const dist = min_d + if (span > 0)
            @as(f32, @floatFromInt(rng.nextBounded(1000))) / 1000.0 * span
        else
            0;
        const ox = px + @cos(ang) * dist;
        const oz = pz + @sin(ang) * dist;
        const oy = self.sim.groundY(ox, oz) orelse py;
        const nid = self.sim.spawnZombieDef(ox, oy, oz, def.max_hp, self.entityClassOf(def)) orelse continue;
        if (!a.aggressive) continue;
        if (self.sim.slotOfNetId(nid)) |zs| {
            if (self.sim.mask[zs].zombie_ai) {
                self.sim.zombie_ai[zs].state = .chase;
                self.sim.zombie_ai[zs].target_id = player_id;
                self.sim.zombie_ai[zs].alert = true;
            }
        }
    }
}

/// `RageZombies`: send nearby zombies into chase and scale their chase speed
/// by `speed_percent` (church-bell phase 2 is 1.5). Duration is not timed yet.
fn rageNearbyZombies(self: *Game, ps: ecs.Slot, a: assets_gameevents.Action) void {
    if (!self.sim.mask[ps].transform) return;
    const px = self.sim.transform[ps].x;
    const pz = self.sim.transform[ps].z;
    const player_id = self.sim.network_id[ps].id;
    const scale = if (a.speed_percent > 0) a.speed_percent else 1;
    // Cover the bell spawn ring plus a little margin so phase-1 spawns rage.
    const range_sq: f32 = 40 * 40;
    for (self.sim.kind_groups.slice(.zombie)) |zs| {
        if (!self.sim.alive[zs] or !self.sim.mask[zs].transform or !self.sim.mask[zs].zombie_ai) continue;
        const dx = self.sim.transform[zs].x - px;
        const dz = self.sim.transform[zs].z - pz;
        if (dx * dx + dz * dz > range_sq) continue;
        self.sim.zombie_ai[zs].state = .chase;
        self.sim.zombie_ai[zs].target_id = player_id;
        self.sim.zombie_ai[zs].alert = true;
        if (self.sim.mask[zs].class_id) {
            if (self.sim.class_id[zs].chase_speed > 0)
                self.sim.class_id[zs].chase_speed *= scale;
            if (self.sim.class_id[zs].chase_speed_day > 0)
                self.sim.class_id[zs].chase_speed_day *= scale;
        }
    }
}

/// `ModifyEntityStat`: `SetMax` sets the stat to its current maximum, `Set`
/// writes the literal value (or `value` x max when `is_percent`). Health is
/// clamped to its max the way the stat write in stock is.
fn applyStat(self: *Game, ps: ecs.Slot, a: assets_gameevents.Action) void {
    var h = self.sim.health[ps];
    const max_v: f32 = switch (a.stat) {
        .health => h.max_hp,
        .food => h.food_max,
        .water => h.water_max,
        .stamina => h.stamina_max,
        .unknown => return,
    };
    const v: f32 = if (a.op == .set_max)
        max_v
    else if (a.is_percent)
        max_v * a.value
    else
        a.value;
    const clamped = @max(0, v);
    switch (a.stat) {
        .health => h.hp = @min(clamped, h.max_hp),
        .food => h.food = @min(clamped, h.food_max),
        .water => h.water = @min(clamped, h.water_max),
        .stamina => h.stamina = @min(clamped, h.stamina_max),
        .unknown => return,
    }
    self.sim.health[ps] = h;
    // Stat writes replicate through the dirty hp bit (the survival pass folds
    // food/water/stamina into the same stat update as hp).
    self.sim.markDirty(ps, .{ .hp = true });
}

/// `RemoveDeathBuffs`: drop every active buff whose class is `remove_on_death`,
/// minus the tag exclusion the injured sequence declares
/// (`exclude_tags="deathpenalty_injured"`). Removals are relayed, or the icon
/// stays on every HUD (RE buffs.md:194).
fn removeDeathBuffs(self: *Game, peer_slot: usize, ps: ecs.Slot, exclude_tags: []const u8) void {
    const set = self.sim.buffsMut(ps);
    // The set is a fixed slot array with no live count: walk it and skip the
    // free slots. `remove` clears the slot in place, so the index keeps its
    // meaning after a removal.
    for (&set.slots) |*e| {
        if (!e.active or !e.remove_on_death) continue;
        if (exclude_tags.len > 0) {
            if (self.buffs.byId(e.def_id)) |def| {
                if (tagExcluded(def.tags, exclude_tags)) continue;
            }
        }
        const def_id = e.def_id;
        _ = ecs.buff.remove(set, def_id);
        if (self.buffs.byId(def_id)) |def| {
            social.relayBuff(self, self.sim.network_id[ps].id, def.name, false, -1, peer_slot) catch {};
        }
    }
}

/// True when the buff's tag list carries any tag of the exclusion list
/// (`<tags value=...>` on the buff vs `exclude_tags=` on the action). Both are
/// comma lists; the compare is exact per tag, like stock FastTags.
fn tagExcluded(list: []const u8, query: []const u8) bool {
    var q = std.mem.splitScalar(u8, query, ',');
    while (q.next()) |tag| {
        const t = std.mem.trim(u8, tag, " \t");
        if (t.len > 0 and xml.tagListContains(list, t)) return true;
    }
    return false;
}

fn requirementHolds(self: *Game, peer_slot: usize, a: assets_gameevents.Action) bool {
    if (!a.has_requirement) return true;
    const cl = &self.clients[peer_slot];
    const v = cl.cvars.get(a.req_cvar);
    return switch (a.req_op) {
        .gt => v > a.req_value,
        .gte => v >= a.req_value,
        .lt => v < a.req_value,
        .lte => v <= a.req_value,
        .equals => v == a.req_value,
        .not_equals => v != a.req_value,
        .unknown => false,
    };
}

fn applyBuff(self: *Game, peer_slot: usize, ps: ecs.Slot, buff_name: []const u8) void {
    const def_id = self.buffs.indexOfName(buff_name) orelse return;
    const def = self.buffs.byId(def_id) orelse return;
    const set = self.sim.buffsMut(ps);
    const res = ecs.buff.add(set, .{
        .def_id = def_id,
        .duration = def.duration,
        .stack_type = def.stack_type,
        .update_rate_ticks = def.update_rate_ticks,
        .remove_on_death = def.remove_on_death,
    }, ecs.buff.duration_from_class, -1, 0, 0, 0);
    if (res == .no_slot) return;
    social.relayBuff(self, self.sim.network_id[ps].id, def.name, true, -1, peer_slot) catch {};
}
