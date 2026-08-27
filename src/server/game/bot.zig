//! Host-side FPS bot manager (ADR 0026). Bots are NOT ECS entities: the only
//! boundary between a bot and the sim is the Wasm sense/command surface
//! (`zdtd.sense` / `zdtd.queue`). The guest brain is unchanged and drives bots
//! through `bot <verb>` commands routed here by game/wasm_host.zig; the ECS
//! owns players, zombies, traders, vehicles, turrets, loot bags and animals
//! only.
//!
//! The BotManager exposes data only — replication knowledge stays in
//! game/replicate.zig, which reads `self.bots.bots` for spawn/pos/remove
//! fan-out against the same interest grid as ECS entities.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;

/// Fixed bot capacity (ADR 0026 MaxBots-style cap; bounded array, no heap).
pub const max_bots: usize = 16;
/// Operator-facing bot-server policy (ADR 0021: config, not parse arms).
/// Filled from `[bots]` in zdtd.toml / a mode pack (merged by main.zig);
/// defaults match the pre-config behaviour exactly. Provenance: PROVENANCE.md
/// §3.7 (zdtd-owned defaults; the headshot multiplier mirrors clanker
/// `HeadshotMultiplier`, the damage floor the old `ecs/command.zig` host).
/// `bot_max_hp` is deliberately NOT here: the wasm guest normalizes hurt
/// against `BOT_MAX_HP` 100 (sense contract), so changing it would skew the
/// guest's retreat/dodge thresholds without a sense-format change.
pub const BotHostConfig = struct {
    shoot_damage: f32 = 12.0,
    headshot_multiplier: f32 = 2.0,
    spawn_spread: f32 = 2.0,
    spawn_y: f32 = 70,
    max_step_up: f32 = 1.5,
    /// Move-arrival tolerance: a bot within this distance of its destination
    /// snaps onto it (anti-oscillation). Config: `[bots] arrival_dist`.
    arrival_dist: f32 = 0.05,
    /// Host fire-range slop added to the weapon range (clanker parity):
    /// `weap.range + slop` is the LOS-gated fire gate. Config:
    /// `[bots] shot_range_slop`.
    shot_range_slop: f32 = 2.0,
    /// Host loadout pool as `tag:damage:range:pellets,tag:...` (up to 8 guns;
    /// default = the builtin bot_weapon_* pool). Empty = builtin pool.
    weapon_profiles: []const u8 = "",
};

/// Historic default config (pre-`[bots]` values; tests and docs reference it).
pub const bot_host_defaults: BotHostConfig = .{};

/// Flat damage a successful `bot shoot` applies to its target (ADR 0026 host
/// floor; the guest already gated the shot on accuracy). Kept as the pistol
/// floor; per-weapon damage overrides it when a Bot carries a weapon (cross-
/// pollinated from clanker WeaponProfile). Config: `[bots] shoot_damage`.
pub const bot_shoot_damage: f32 = bot_host_defaults.shoot_damage;
/// Headshot damage multiplier (cross-pollinated from clanker TryShootBurst
/// HeadshotMultiplier); applied when the guest flags `bot shoot ... head`.
/// Config: `[bots] headshot_multiplier`.
pub const bot_headshot_multiplier: f32 = bot_host_defaults.headshot_multiplier;
/// Default bot max HP (ADR 0026; the brain normalizes hurt against 100).
/// Guest contract — the wasm `BOT_MAX_HP` matches; not config (see
/// BotHostConfig).
pub const bot_max_hp: f32 = 100;

/// Per-bot weapon profile (cross-pollinated from clanker WeaponProfile.ForGun).
/// Host-enforced damage/range so mixed-loadout bots actually feel different.
pub const BotWeapon = struct {
    damage: f32 = 16,
    range: f32 = 40,
    pellets: u8 = 1,
    // short gun id tag for logs/list (clanker's GunId, truncated)
    tag: [12]u8 = .{0} ** 12,
    tag_len: usize = 0,
};
pub const bot_weapon_pistol: BotWeapon = .{ .damage = 16, .range = 40, .pellets = 1, .tag = .{ 'p', 'i', 's', 't', 'o', 'l', 0, 0, 0, 0, 0, 0 }, .tag_len = 6 };
pub const bot_weapon_shotgun: BotWeapon = .{ .damage = 14, .range = 22, .pellets = 8, .tag = .{ 's', 'h', 'o', 't', 'g', 'u', 'n', 0, 0, 0, 0, 0 }, .tag_len = 7 };
pub const bot_weapon_auto: BotWeapon = .{ .damage = 9, .range = 22, .pellets = 6, .tag = .{ 'a', 'u', 't', 'o', 0, 0, 0, 0, 0, 0, 0, 0 }, .tag_len = 4 };
pub const bot_weapon_ak: BotWeapon = .{ .damage = 16, .range = 55, .pellets = 1, .tag = .{ 'a', 'k', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .tag_len = 2 };
pub const bot_weapon_sniper: BotWeapon = .{ .damage = 42, .range = 90, .pellets = 1, .tag = .{ 's', 'n', 'i', 'p', 'e', 'r', 0, 0, 0, 0, 0, 0 }, .tag_len = 6 };
pub const bot_weapon_smg: BotWeapon = .{ .damage = 9, .range = 35, .pellets = 1, .tag = .{ 's', 'm', 'g', 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .tag_len = 3 };
pub const bot_weapon_magnum: BotWeapon = .{ .damage = 34, .range = 45, .pellets = 1, .tag = .{ 'm', 'a', 'g', 'n', 'u', 'm', 0, 0, 0, 0, 0, 0 }, .tag_len = 6 };
pub const bot_loadout_pool: [6]BotWeapon = .{ bot_weapon_pistol, bot_weapon_shotgun, bot_weapon_ak, bot_weapon_sniper, bot_weapon_auto, bot_weapon_smg };

/// Flat XZ spawn spread used by `bot count` / `bot spawn` fallback so the
/// floor bots do not stack on one cell. Config: `[bots] spawn_spread`.
const bot_spawn_spread: f32 = bot_host_defaults.spawn_spread;
/// Default bot spawn Y when the verb carries only [name] [x z] (flat ground).
/// Config: `[bots] spawn_y`.
const bot_spawn_y: f32 = bot_host_defaults.spawn_y;
/// Horizontal arrival tolerance: move intent clears when within this distance.
/// Sense record byte size (RFC 0001 §3): one fixed 32-byte record per entity.
pub const sense_record_len: usize = 32;
/// Sense kind value for a bot (RFC 0001 §3: 0 player, 1 zombie, 2 bot).
const sense_kind_bot: u8 = 2;
/// Damage-event records in the sense trailer cap (RFC 0001 §3): at most this
/// many 16-byte events follow the entity records. Bounded so the guest's
/// parsing stays fixed-size; overflow events are dropped (flavor, not fidelity).
pub const max_sense_events: usize = 8;
/// Sense event kind for a damage event (RFC 0001 §3: 3 = damage).
pub const sense_kind_damage: u8 = 3;
/// Sense event kind for a bot-info record (RFC 0001 §3: 4 = bot info). The
/// host writes one per live bot each sense pass so the guest can adapt to the
/// bot's host-assigned weapon (range/burst/lead) without a record-layout bump.
pub const sense_kind_bot_info: u8 = 4;
/// Max bot-info records in the sense trailer (one per live bot; cap = slots).
pub const max_sense_info: usize = max_bots;
/// Sense event record byte size (RFC 0001 §3): kind u8 + 3 pad, attacker i32,
/// victim i32, amount f32 — packed, little-endian.
pub const sense_event_len: usize = 16;

/// One sense damage event (RFC 0001 §3). Host-recorded whenever a live bot
/// takes attributed damage, so the guest learns *who* hit it and can
/// retaliate (clanker `Bot.OnDamaged` parity).
pub const SenseEvent = struct {
    attacker: i32 = -1,
    victim: i32 = -1,
    amount: f32 = 0,
};

/// One host-side bot. Pure data — the guest brain never touches this struct
/// directly, only the sense snapshot and queued commands.
pub const Bot = struct {
    net_id: i32 = -1,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    yaw: f32 = 0,
    hp: f32 = 0,
    alive: bool = false,
    dest_x: f32 = 0,
    dest_y: f32 = 0,
    dest_z: f32 = 0,
    speed: f32 = 0,
    move_active: bool = false,
    strafe_p: bool = false,
    /// Per-bot weapon (clanker WeaponProfile diversity, host-enforced)
    weapon: BotWeapon = bot_weapon_pistol,
    /// Move-arrival tolerance from [bots] arrival_dist (set at spawn).
    arrival_dist: f32 = 0.05,
    /// Operator/console display name (bounded, no heap). The stock client needs
    /// an entity_name in the player-mesh spawn body, so bots carry one.
    name: [24]u8 = .{0} ** 24,
    name_len: usize = 0,
    /// Net id of the last entity that damaged this bot (-1 = none). The guest
    /// reads it indirectly via the damage-event sense trailer (retaliation;
    /// clanker `Bot.OnDamaged` aggro-swap parity).
    last_attacker: i32 = -1,
    /// Index into `bot_loadout_pool` (sent to the guest as a kind-4 bot-info
    /// sense record so the brain can adapt range/burst/lead to the weapon).
    weapon_id: u8 = 0,

    /// Set the display name, copying at most name.len-1 bytes (NUL-terminated).
    /// An empty name falls back to the default "Bot".
    fn setName(self: *Bot, name: []const u8) void {
        const n = if (name.len == 0) default_bot_name else name;
        const cap = @min(n.len, self.name.len - 1);
        @memcpy(self.name[0..cap], n[0..cap]);
        self.name[cap] = 0;
        self.name_len = cap;
    }
};

pub const default_bot_name = "Bot";

pub const BotManager = struct {
    /// Operator bot policy (`[bots]` config; defaults = historic behaviour).
    cfg: BotHostConfig = .{},
    /// Deferred zombie-melee damage (ADR 0026 concurrency): the zombie AI
    /// runs on parallel workers, so melee on bots accumulates as fixed-point
    /// (atomic adds, same shape as the ECS dmg_fp) plus an atomic last-
    /// attacker; the main thread drains it into attributed damage after the
    /// AI pass joins (tick -> drainWorkerDamage), so no worker ever mutates
    /// hp/events/last_attacker directly. dmg_scale matches systems.zig.
    dmg_scale: u32 = 100,
    dmg_fp: [max_bots]u32 = .{0} ** max_bots,
    attacker_fp: [max_bots]std.atomic.Value(i32) = [_]std.atomic.Value(i32){std.atomic.Value(i32).init(-1)} ** max_bots,
    /// Fixed slot table; slots are recycled on remove (an !alive slot is free).
    /// MUST be zero-initialized: `spawn` scans `bots[slot].alive` to find a
    /// free slot, and uninitialized memory (Debug allocator 0xAA) reads as
    /// alive=true, making the table look full and `bot count` spawn too few.
    bots: [max_bots]Bot = [_]Bot{.{}} ** max_bots,
    /// Live bot count (spawn ++, remove / kill --). Indexes known_bots bits.
    n: usize = 0,
    /// Remembered population floor (set by `bot count <n>`); tick tops up when
    /// bots die so the floor is self-healing (RFC 0001: keep n alive).
    floor: u32 = 0,
    /// Damage events pending in the sense trailer (RFC 0001 §3). Recorded on
    /// attributed damage to a live bot; drained (and cleared) by
    /// `drainSenseEvents` each sense pass, so they are one-tick flavor.
    events: [max_sense_events]SenseEvent = [_]SenseEvent{.{}} ** max_sense_events,
    ev_n: usize = 0,
    /// Loadout pool from `[bots] weapon_profiles` (parsed at init; empty =
    /// use the builtin `bot_loadout_pool`).
    loadout: [8]BotWeapon = undefined,
    loadout_n: usize = 0,

    /// Parse `cfg.weapon_profiles` ("tag:damage:range:pellets,..") into the
    /// loadout pool. Malformed entries are skipped; empty keeps the builtin
    /// pool. Called once after the config lands (Game.initWithOptions).
    pub fn parseLoadout(self: *BotManager) void {
        self.loadout_n = 0;
        var it = std.mem.splitScalar(u8, self.cfg.weapon_profiles, ',');
        while (it.next()) |entry_raw| {
            if (self.loadout_n >= self.loadout.len) break;
            const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
            if (entry.len == 0) continue;
            var f = std.mem.splitScalar(u8, entry, ':');
            const tag = std.mem.trim(u8, f.next() orelse continue, " \t");
            if (tag.len == 0 or tag.len > 12) continue;
            const dmg = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
            const range = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
            const pellets = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue;
            var w: BotWeapon = .{ .damage = dmg, .range = range, .pellets = pellets };
            @memcpy(w.tag[0..tag.len], tag);
            w.tag_len = tag.len;
            self.loadout[self.loadout_n] = w;
            self.loadout_n += 1;
        }
    }

    /// Allocate a live bot at (x, y, z). Returns its net id, or null when the
    /// table is full. The id comes from the shared sim counter (Game helper),
    /// so it never collides with ECS entity ids. The bot is grounded onto the
    /// terrain surface at (x, z) (`Game.groundHeight`) so it never spawns
    /// floating in or above the ground on real maps.
    pub fn spawn(self: *BotManager, g: *Game, x: f32, y: f32, z: f32, hp: f32) ?i32 {
        _ = y; // grounded onto the terrain surface below (see body)
        if (self.n >= max_bots) return null;
        var slot: usize = 0;
        while (slot < max_bots and self.bots[slot].alive) : (slot += 1) {}
        if (slot >= max_bots) return null;
        const id = g.allocBotNetId();
        const gy = g.groundHeight(@floor(x), @floor(z));
        // Deterministic mixed-loadout pick from pool (clanker LoadoutPool parity)
        var prng: u32 = @as(u32, @bitCast(id)) *% 2654435761 +% @as(u32, @truncate(@as(u64, @bitCast(g.tick_n))));
        prng = prng *% 1103515245 +% 12345;
        const widx: usize = @intCast((prng >> 8 & 0x00ffffff) % bot_loadout_pool.len);
        const pool: []const BotWeapon = if (self.loadout_n > 0) self.loadout[0..self.loadout_n] else &bot_loadout_pool;
        const wsel = pool[widx % pool.len];
        self.bots[slot] = .{
            .net_id = id,
            .x = x,
            .y = gy,
            .z = z,
            .hp = @max(hp, 1),
            .alive = true,
            .weapon = wsel,
            .weapon_id = @intCast(widx),
            .arrival_dist = self.cfg.arrival_dist,
        };
        self.bots[slot].setName(default_bot_name);
        self.n += 1;
        return id;
    }

    /// Spawn with an operator-supplied display name (e.g. `bot spawn Ramone x z`).
    pub fn spawnNamed(self: *BotManager, g: *Game, x: f32, y: f32, z: f32, hp: f32, name: []const u8) ?i32 {
        const id = self.spawn(g, x, y, z, hp) orelse return null;
        if (self.find(id)) |s| self.bots[s].setName(name);
        return id;
    }

    /// Slot of a live bot by net id, or null. O(max_bots) — 16 slots, fine.
    pub fn find(self: *BotManager, net_id: i32) ?usize {
        if (net_id < 0) return null;
        for (self.bots, 0..) |b, i| {
            if (b.alive and b.net_id == net_id) return i;
        }
        return null;
    }

    /// Set a bot's move intent (dest + speed); the host integrates it in tick.
    pub fn move(self: *BotManager, net_id: i32, x: f32, y: f32, z: f32, speed: f32) void {
        const s = self.find(net_id) orelse return;
        const b = &self.bots[s];
        b.dest_x = x;
        b.dest_y = y;
        b.dest_z = z;
        b.speed = speed;
        b.move_active = true;
    }

    /// Set a bot's facing yaw.
    pub fn look(self: *BotManager, net_id: i32, yaw: f32) void {
        const s = self.find(net_id) orelse return;
        self.bots[s].yaw = yaw;
    }

    /// `bot shoot <shooter> <target> [head]`: only a live bot may fire, and only
    /// when the shot is not blocked by solid voxels (RFC 0001 §4 host-LOS gate;
    /// `Game.botLosClear` from the shooter's eye to the target's chest). A live
    /// bot target takes weapon damage (dies at hp <= 0); any other target
    /// resolves through the ECS damage path (guarded against absence). The
    /// optional `head` token applies the headshot multiplier (cross-pollinated
    /// from clanker TryShootBurst HeadshotMultiplier).
    pub fn shoot(self: *BotManager, g: *Game, shooter: i32, target: i32, head: bool) void {
        const ss = self.find(shooter) orelse return;
        const weap = self.bots[ss].weapon;
        const dmg = weap.damage * (if (head) self.cfg.headshot_multiplier else 1.0);

        // Target position for the LOS check: a bot target or an ECS entity.
        var tpos: [3]f32 = undefined;
        if (self.find(target)) |ts| {
            const b = &self.bots[ts];
            tpos = .{ b.x, b.y, b.z };
        } else if (g.sim.slotOfNetId(target)) |es| {
            const t = g.sim.transform[es];
            tpos = .{ t.x, t.y, t.z };
        } else return;

        const p = &self.bots[ss];
        // Host-enforced weapon range (clanker WeaponProfile.Range parity)
        const dx = tpos[0] - p.x;
        const dz = tpos[2] - p.z;
        const dy = (tpos[1] + 1.05) - (p.y + 1.45);
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);
        if (dist > weap.range + self.cfg.shot_range_slop) return;
        const eye: [3]f32 = .{ p.x, p.y + 1.45, p.z };
        const chest: [3]f32 = .{ tpos[0], tpos[1] + 1.05, tpos[2] };
        if (!g.botLosClear(eye, chest)) return;

        if (self.damageFrom(target, dmg, shooter)) return;
        // ECS target (player/zombie/...): damage resolves to no-op on absence.
        // damageFrom attributes the bot as the attacker (zombie revenge target,
        // kill attribution) — `damage` would leave it unattributed.
        // Wasm-first (AGENTS rule 29): a bot damaging a PLAYER passes the
        // on_player_damage plugin verdict (PvP/friendly-fire, damage scaling).
        if (g.sim.slotOfNetId(target)) |es| {
            if (g.sim.mask[es].player) {
                const sv = g.plugins.playerDamage(shooter, target, @intFromFloat(dmg));
                const v = if (sv != 0) sv else g.wasm_plugins.playerDamage(shooter, target, @intFromFloat(dmg));
                if (v < 0) return;
                if (v > 0) {
                    _ = g.sim.damageFrom(target, dmg * @as(f32, @floatFromInt(v)) / 100.0, shooter);
                    return;
                }
            }
        }
        _ = g.sim.damageFrom(target, dmg, shooter);
    }

    /// Apply damage to a live bot by net id (no-op if absent). Returns true when
    /// the target was a bot. Split out so the damage math is unit-testable
    /// without constructing a Game.
    pub fn damageBot(self: *BotManager, target: i32, dmg: f32) bool {
        const ts = self.find(target) orelse return false;
        const b = &self.bots[ts];
        b.hp -= dmg;
        if (b.hp <= 0) {
            b.alive = false;
            self.n -|= 1;
        }
        return true;
    }

    /// Apply damage to a live bot by net id, attributed to `attacker`
    /// (RFC 0001 §3 / ADR 0026: the host attributes every hit so the guest
    /// can retaliate). No-op when the target is absent. Records a damage-event
    /// sense record for the guest and sets the victim's `last_attacker`.
    /// Players and bots both route here (C2S damage path + `shoot`).
    /// Main thread only.
    pub fn damageFrom(self: *BotManager, target: i32, dmg: f32, attacker: i32) bool {
        const ts = self.find(target) orelse return false;
        if (self.ev_n < max_sense_events) {
            self.events[self.ev_n] = .{ .attacker = attacker, .victim = target, .amount = dmg };
            self.ev_n += 1;
        }
        self.bots[ts].last_attacker = attacker;
        return self.damageBot(target, dmg);
    }

    /// Zombie-melee damage from the parallel AI workers (ADR 0026): atomic
    /// fixed-point accumulation only — no hp/event/attacker mutation on the
    /// worker. False when the bot is gone (the melee whiffs). The main thread
    /// drains `drainWorkerDamage` after the AI pass joins.
    pub fn damageFromWorker(self: *BotManager, bot_net: i32, attacker_net: i32, amount: f32) bool {
        const ts = self.find(bot_net) orelse return false;
        const add: u32 = @trunc(amount * @as(f32, @floatFromInt(self.dmg_scale)));
        _ = @atomicRmw(u32, &self.dmg_fp[ts], .Add, add, .monotonic);
        self.attacker_fp[ts].store(attacker_net, .monotonic);
        return true;
    }

    /// Main-thread drain of worker-accumulated zombie melee (called from
    /// `tick`, after the parallel AI pass joins): each slot's fixed-point sum
    /// is applied as attributed damage (event + last_attacker + possible
    /// death). Deterministic order; no atomics needed here.
    pub fn drainWorkerDamage(self: *BotManager) void {
        var i: usize = 0;
        while (i < max_bots) : (i += 1) {
            const fp = self.dmg_fp[i];
            if (fp == 0) continue;
            self.dmg_fp[i] = 0;
            if (!self.bots[i].alive) continue;
            const amount = @as(f32, @floatFromInt(fp)) / @as(f32, @floatFromInt(self.dmg_scale));
            if (!(amount > 0)) continue;
            const attacker = self.attacker_fp[i].swap(-1, .monotonic);
            _ = self.damageFrom(self.bots[i].net_id, amount, attacker);
        }
    }

    /// Copy pending damage events into the sense snapshot trailer starting at
    /// byte `base` (immediately after the entity records) and clear the buffer.
    /// Returns the number of events written (<= `cap`). No heap; stops early
    /// when `out` cannot fit the next event.
    pub fn drainSenseEvents(self: *BotManager, out: []u8, base: usize, cap: usize) usize {
        var written: usize = 0;
        for (self.events[0..self.ev_n]) |ev| {
            if (written >= cap) break;
            const rec = base + written * sense_event_len;
            if (rec + sense_event_len > out.len) break;
            const r = out[rec .. rec + sense_event_len];
            @memset(r, 0);
            r[0] = sense_kind_damage;
            std.mem.writeInt(i32, r[4..8], ev.attacker, .little);
            std.mem.writeInt(i32, r[8..12], ev.victim, .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(ev.amount), .little);
            written += 1;
        }
        self.ev_n = 0;
        return written;
    }

    /// Write one kind-4 bot-info record per live bot into the sense trailer
    /// starting at byte `base` (before the damage events). Returns the number
    /// written (<= `cap`). The guest builds its per-bot weapon map from these
    /// (RFC 0001 §3) so the brain adapts range/burst/lead to the host-assigned
    /// loadout. No heap; stops early when `out` cannot fit the next record.
    pub fn fillSenseBotInfo(self: *BotManager, out: []u8, base: usize, cap: usize) usize {
        var written: usize = 0;
        for (&self.bots) |*b| {
            if (written >= cap) break;
            if (!b.alive) continue;
            const rec = base + written * sense_event_len;
            if (rec + sense_event_len > out.len) break;
            const r = out[rec .. rec + sense_event_len];
            @memset(r, 0);
            r[0] = sense_kind_bot_info;
            r[1] = b.weapon_id;
            std.mem.writeInt(i32, r[4..8], b.net_id, .little);
            written += 1;
        }
        return written;
    }

    /// Despawn one bot by net id (no-op for unknown ids).
    pub fn remove(self: *BotManager, net_id: i32) void {
        const s = self.find(net_id) orelse return;
        self.bots[s] = .{};
        self.n -|= 1;
    }

    /// Despawn every bot.
    pub fn removeAll(self: *BotManager) void {
        for (&self.bots) |*b| b.* = .{};
        self.n = 0;
    }

    /// Population floor: spawn at a small spread until the live count is >= n.
    /// Spawn-only (matches the pre-refactor `bot count` behaviour); a target of
    /// 0 is a no-op. Clamped to max_bots; stops early when the table fills.
    pub fn applyCountFloor(self: *BotManager, g: *Game, n: u32) void {
        const target = @min(n, @as(u32, max_bots));
        self.floor = target;
        // The population floor is two-way: remove extras when over target
        // (RFC 0001 `bot count` = "keep n alive"). `bot count 0` clears all.
        while (self.n > target) {
            var slot: usize = 0;
            while (slot < max_bots and !self.bots[slot].alive) : (slot += 1) {}
            if (slot >= max_bots) break;
            self.bots[slot] = .{};
            self.n -|= 1;
        }
        self.maintainFloor(g);
    }

    /// Spawn bots until the live count reaches the remembered floor. Called by
    /// tick as well as applyCountFloor, so a bot killed in combat is replaced
    /// automatically. No-op when no floor is set (`bot count` never used).
    pub fn maintainFloor(self: *BotManager, g: *Game) void {
        if (self.floor == 0) return;
        var spread: u32 = 1;
        while (self.n < self.floor) : (spread += 1) {
            const ix: f32 = @as(f32, @floatFromInt(spread)) * self.cfg.spawn_spread;
            const iz: f32 = @as(f32, @floatFromInt(spread % 3)) * self.cfg.spawn_spread;
            if (self.spawn(g, ix, self.cfg.spawn_y, iz, bot_max_hp) == null) break;
        }
    }

    /// Parse a `bot <verb>` command and dispatch. Returns true when the command
    /// was any `bot ...` (consumed even when malformed); false otherwise, so
    /// game/wasm_host.zig can fall through to the ECS plugin verbs.
    pub fn handleCommand(self: *BotManager, g: *Game, cmd: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        const verb = it.next() orelse return false;
        if (!std.mem.eql(u8, verb, "bot")) return false;
        const sub = it.next() orelse return true;
        if (std.mem.eql(u8, sub, "spawn")) {
            // bot spawn [name] [x z]: optional display name + numeric x z; the
            // host carries the name for the player-mesh spawn body. y/hp default.
            var tokbuf: [3][]const u8 = undefined;
            var tn: usize = 0;
            while (tn < 3) : (tn += 1) {
                const t = it.next() orelse break;
                tokbuf[tn] = t;
            }
            if (it.next() != null) return true; // more than 2 numeric args
            if (tn < 2) return true;
            const x = std.fmt.parseFloat(f32, tokbuf[tn - 2]) catch return true;
            const z = std.fmt.parseFloat(f32, tokbuf[tn - 1]) catch return true;
            const name: []const u8 = if (tn == 3) tokbuf[0] else default_bot_name;
            _ = self.spawnNamed(g, x, self.cfg.spawn_y, z, bot_max_hp, name);
            return true;
        }
        if (std.mem.eql(u8, sub, "move")) {
            const id = it.next() orelse return true;
            const x = it.next() orelse return true;
            const y = it.next() orelse return true;
            const z = it.next() orelse return true;
            const speed = it.next() orelse return true;
            if (it.next() != null) return true;
            self.move(
                std.fmt.parseInt(i32, id, 10) catch return true,
                std.fmt.parseFloat(f32, x) catch return true,
                std.fmt.parseFloat(f32, y) catch return true,
                std.fmt.parseFloat(f32, z) catch return true,
                std.fmt.parseFloat(f32, speed) catch return true,
            );
            return true;
        }
        if (std.mem.eql(u8, sub, "look")) {
            const id = it.next() orelse return true;
            const yaw = it.next() orelse return true;
            if (it.next() != null) return true;
            self.look(std.fmt.parseInt(i32, id, 10) catch return true, std.fmt.parseFloat(f32, yaw) catch return true);
            return true;
        }
        if (std.mem.eql(u8, sub, "shoot")) {
            const id = it.next() orelse return true;
            const target = it.next() orelse return true;
            // optional trailing "head" token (headshot flag from the guest).
            var head = false;
            if (it.next()) |t| {
                if (std.mem.eql(u8, t, "head")) {
                    head = true;
                } else {
                    return true; // unexpected trailing token
                }
                if (it.next() != null) return true;
            }
            self.shoot(g, std.fmt.parseInt(i32, id, 10) catch return true, std.fmt.parseInt(i32, target, 10) catch return true, head);
            return true;
        }
        if (std.mem.eql(u8, sub, "remove")) {
            const arg = it.next() orelse return true;
            if (std.mem.eql(u8, arg, "all")) {
                if (it.next() != null) return true;
                self.removeAll();
            } else {
                if (it.next() != null) return true;
                self.remove(std.fmt.parseInt(i32, arg, 10) catch return true);
            }
            return true;
        }
        if (std.mem.eql(u8, sub, "count")) {
            const n = it.next() orelse return true;
            if (it.next() != null) return true;
            self.applyCountFloor(g, std.fmt.parseInt(u32, n, 10) catch return true);
            return true;
        }
        return true;
    }

    /// Integrate live bots' move intents. For each bot with move_active, step
    /// x/z toward the destination by at most speed*dt (never overshoot), snap y
    /// to the destination and clear the intent on arrival (horizontal distance
    /// <= arrival_dist). After each step the bot's y is re-grounded onto the
    /// terrain surface so it follows hills instead of floating at a fixed
    /// height. No heap; the ECS is not touched (bots live here only).
    pub fn tick(self: *BotManager, g: *Game, dt: f32) void {
        // Drain worker-accumulated zombie melee first (the AI pass joined):
        // attributed damage lands before the guest's next sense pass.
        self.drainWorkerDamage();
        for (&self.bots) |*b| {
            if (!b.alive or !b.move_active) continue;
            // Wall-aware step: bots cannot phase through solid blocks; they
            // slide along walls. Terrain height is applied inside the step.
            stepMoveCollide(b, g, dt, self.cfg.max_step_up);
        }
        // Self-healing population floor: replace bots killed since the last tick.
        self.maintainFloor(g);
    }

    /// Append Bot sense records after the host's ECS actor records (RFC 0001
    /// §3): one 32-byte record per live bot, starting at byte `base`, capped at
    /// `max_records`. `*n` is the running record count (updated in place); the
    /// caller owns the header and return length. Stops early when the caller's
    /// buffer cannot fit the next record.
    pub fn fillSense(self: *BotManager, out: []u8, base: usize, max_records: usize, n: *usize) void {
        for (&self.bots) |*b| {
            if (n.* >= max_records) return;
            if (!b.alive) continue;
            const rec = base + n.* * sense_record_len;
            if (rec + sense_record_len > out.len) return;
            const r = out[rec .. rec + sense_record_len];
            std.mem.writeInt(i32, r[0..4], b.net_id, .little);
            r[4] = sense_kind_bot;
            r[5] = 0; // self
            r[6] = 1; // alive
            r[7] = 0; // pad
            std.mem.writeInt(u32, r[8..12], @bitCast(b.x), .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(b.y), .little);
            std.mem.writeInt(u32, r[16..20], @bitCast(b.z), .little);
            std.mem.writeInt(u32, r[20..24], @bitCast(b.hp), .little);
            std.mem.writeInt(u32, r[24..28], @bitCast(b.yaw), .little);
            std.mem.writeInt(i32, r[28..32], -1, .little); // target_id
            n.* += 1;
        }
    }
};

/// One move integration step (shared by tick; standalone so the math is
/// unit-testable without a full Game).
fn stepMove(b: *Bot, dt: f32) void {
    const dx = b.dest_x - b.x;
    const dz = b.dest_z - b.z;
    const d2 = dx * dx + dz * dz;
    if (d2 <= b.arrival_dist * b.arrival_dist) {
        // Arrived: snap and clear intent (never overshoot / re-oscillate).
        b.x = b.dest_x;
        b.y = b.dest_y;
        b.z = b.dest_z;
        b.move_active = false;
        return;
    }
    const dist = @sqrt(d2);
    const step_dist = b.speed * dt;
    if (step_dist >= dist) {
        b.x = b.dest_x;
        b.z = b.dest_z;
    } else {
        const inv = step_dist / dist;
        b.x += dx * inv;
        b.z += dz * inv;
    }
    b.y = b.dest_y;
}

/// True when a solid block occupies the bot's standing cells at (x, y, z):
/// the cell the feet sit in and the one above (head). Terrain itself is not a
/// wall here — the caller grounds y onto the surface first — so only true
/// obstacles (walls, cliffs' faces) block.
fn botSolidAt(g: *Game, x: f32, y: f32, z: f32) bool {
    const ix: i32 = @floor(x);
    const iy: i32 = @floor(y);
    const iz: i32 = @floor(z);
    if (g.world.isSolidWorld(ix, iy, iz) catch false) return true;
    if (g.world.isSolidWorld(ix, iy + 1, iz) catch false) return true;
    return false;
}

/// stepMove with wall collision: the bot does not enter a solid cell. When the
/// direct step is blocked it slides along the free axis (x-only then z-only),
/// so it follows walls instead of phasing through them or stopping dead.
/// stepMove with wall/cliff collision: the bot does not enter a solid cell at
/// its body height, and does not climb terrain more than `max_step_up` above
/// its current feet (`[bots] max_step_up`, default 1.5). When the direct step
/// is blocked it slides along the free axis (x-only then z-only), so it
/// follows walls instead of phasing through them or stopping dead. Ground
/// height is re-snapped afterwards.
fn stepMoveCollide(b: *Bot, g: *Game, dt: f32, max_step_up: f32) void {
    const ox = b.x;
    const oz = b.z;
    const dx = b.dest_x - ox;
    const dz = b.dest_z - oz;
    const d2 = dx * dx + dz * dz;
    if (d2 <= b.arrival_dist * b.arrival_dist) {
        b.x = b.dest_x;
        b.y = b.dest_y;
        b.z = b.dest_z;
        b.move_active = false;
        return;
    }
    const dist = @sqrt(d2);
    const step_dist = b.speed * dt;
    const nx = if (step_dist >= dist) b.dest_x else ox + dx * (step_dist / dist);
    const nz = if (step_dist >= dist) b.dest_z else oz + dz * (step_dist / dist);

    const new_ground = g.groundHeight(@floor(nx), @floor(nz));
    const step_up = new_ground - b.y;
    const blocked = (step_up > max_step_up) or botSolidAt(g, nx, b.y, nz);
    if (!blocked) {
        b.x = nx;
        b.z = nz;
    } else {
        // Slide along the free axis.
        const xg = g.groundHeight(@floor(nx), @floor(oz));
        const zg = g.groundHeight(@floor(ox), @floor(nz));
        const x_free = (xg - b.y <= max_step_up) and !botSolidAt(g, nx, b.y, oz);
        const z_free = (zg - b.y <= max_step_up) and !botSolidAt(g, ox, b.y, nz);
        if (x_free) b.x = nx;
        if (z_free) b.z = nz;
    }
    b.y = g.groundHeight(@floor(b.x), @floor(b.z));
}

test "BotManager find/move/look/remove/removeAll on hand-seeded bots" {
    var m: BotManager = .{};
    // Data-only: spawn needs a Game for net ids, so seed two live bots by hand.
    m.bots[0] = .{ .net_id = 100, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.bots[1] = .{ .net_id = 101, .x = 10, .y = 70, .z = 10, .hp = 80, .alive = true };
    m.n = 2;

    try std.testing.expectEqual(@as(?usize, 0), m.find(100));
    try std.testing.expectEqual(@as(?usize, 1), m.find(101));
    try std.testing.expect(m.find(999) == null);
    try std.testing.expect(m.find(-1) == null);

    // move sets intent.
    m.move(100, 4, 71, 0, 2);
    try std.testing.expect(m.bots[0].move_active);
    try std.testing.expectApproxEqAbs(@as(f32, 4), m.bots[0].dest_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), m.bots[0].speed, 0.001);

    // look sets yaw.
    m.look(101, 90);
    try std.testing.expectApproxEqAbs(@as(f32, 90), m.bots[1].yaw, 0.001);

    // Unknown ids are no-ops.
    m.move(999, 1, 1, 1, 1);
    m.look(999, 1);
    m.remove(999);
    try std.testing.expectEqual(@as(usize, 2), m.n);

    // remove frees the slot; removeAll clears everything.
    m.remove(101);
    try std.testing.expectEqual(@as(usize, 1), m.n);
    try std.testing.expect(m.find(101) == null);
    m.removeAll();
    try std.testing.expectEqual(@as(usize, 0), m.n);
    try std.testing.expect(m.find(100) == null);
}

test "BotManager move integration steps toward dest without overshooting" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 100, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.bots[1] = .{ .net_id = 101, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true, .move_active = true, .dest_x = 10, .dest_y = 70, .dest_z = 0, .speed = 4 };
    m.n = 2;

    // stepMove is tick's per-bot integration; exercised directly so the math
    // is testable without constructing a full Game.
    stepMove(&m.bots[1], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), m.bots[1].x, 0.001);
    try std.testing.expect(m.bots[1].move_active);

    // Four more half-second steps (2 m each) land at exactly dest (no
    // overshoot). As in the old ECS tick, an exact landing via the step branch
    // snaps the position but leaves the intent set; the arrival check clears it
    // on the next call (distance now 0).
    stepMove(&m.bots[1], 0.5);
    stepMove(&m.bots[1], 0.5);
    stepMove(&m.bots[1], 0.5);
    stepMove(&m.bots[1], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), m.bots[1].x, 0.001);
    try std.testing.expect(m.bots[1].move_active);
    stepMove(&m.bots[1], 0.5);
    try std.testing.expect(!m.bots[1].move_active);

    // y snaps to dest_y on every step.
    try std.testing.expectApproxEqAbs(@as(f32, 70), m.bots[1].y, 0.001);
    m.bots[1].dest_y = 71;
    m.bots[1].move_active = true;
    stepMove(&m.bots[1], 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 71), m.bots[1].y, 0.001);

    // A bot without move_active never moves.
    const x0 = m.bots[0].x;
    stepMove(&m.bots[0], 1);
    try std.testing.expectApproxEqAbs(x0, m.bots[0].x, 0.001);
}

test "BotManager fillSense writes the fixed 32-byte sense layout" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 100, .x = 1.5, .y = 70.25, .z = -3.5, .yaw = 45, .hp = 60, .alive = true };
    m.bots[1] = .{ .net_id = 101, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 2;

    var out: [16 + 2 * 32]u8 = [_]u8{0} ** (16 + 2 * 32);
    var n: usize = 0;
    m.fillSense(&out, 16, 2, &n);
    try std.testing.expectEqual(@as(usize, 2), n);

    const r0 = out[16..48];
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, r0[0..4], .little));
    try std.testing.expectEqual(@as(u8, 2), r0[4]); // kind bot
    try std.testing.expectEqual(@as(u8, 0), r0[5]); // self
    try std.testing.expectEqual(@as(u8, 1), r0[6]); // alive
    try std.testing.expectEqual(@as(u8, 0), r0[7]); // pad
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), @as(f32, @bitCast(std.mem.readInt(u32, r0[8..12], .little))), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 70.25), @as(f32, @bitCast(std.mem.readInt(u32, r0[12..16], .little))), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -3.5), @as(f32, @bitCast(std.mem.readInt(u32, r0[16..20], .little))), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60), @as(f32, @bitCast(std.mem.readInt(u32, r0[20..24], .little))), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 45), @as(f32, @bitCast(std.mem.readInt(u32, r0[24..28], .little))), 0.001);
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, r0[28..32], .little));

    // Dead bots are skipped.
    m.bots[1].alive = false;
    m.n = 1;
    n = 0;
    m.fillSense(&out, 16, 2, &n);
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "BotManager damageBot applies headshot multiplier and can kill" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 20, .alive = true };
    m.bots[1] = .{ .net_id = 11, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 2;

    // Plain shot: 100 - 12 = 88.
    try std.testing.expect(m.damageBot(11, bot_shoot_damage));
    try std.testing.expectApproxEqAbs(@as(f32, 88), m.bots[1].hp, 0.01);

    // Headshot (multiplier 2x): 88 - 24 = 64.
    try std.testing.expect(m.damageBot(11, bot_shoot_damage * bot_headshot_multiplier));
    try std.testing.expectApproxEqAbs(@as(f32, 64), m.bots[1].hp, 0.01);

    // Lethal headshot kills the 40 hp bot and drops the live count.
    try std.testing.expect(m.damageBot(10, bot_shoot_damage * bot_headshot_multiplier));
    try std.testing.expect(!m.bots[0].alive);
    try std.testing.expectEqual(@as(usize, 1), m.n);

    // Unknown ids are a no-op.
    try std.testing.expect(!m.damageBot(999, bot_shoot_damage));
}

test "BotManager damageFrom attributes, records events, and can kill" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.bots[1] = .{ .net_id = 11, .x = 0, .y = 70, .z = 0, .hp = 30, .alive = true };
    m.n = 2;

    // Attributed hit: hp drops, last_attacker records the shooter, an event is queued.
    try std.testing.expect(m.damageFrom(10, 12, 555));
    try std.testing.expectApproxEqAbs(@as(f32, 88), m.bots[0].hp, 0.01);
    try std.testing.expectEqual(@as(i32, 555), m.bots[0].last_attacker);
    try std.testing.expectEqual(@as(usize, 1), m.ev_n);
    try std.testing.expectEqual(@as(i32, 555), m.events[0].attacker);
    try std.testing.expectEqual(@as(i32, 10), m.events[0].victim);
    try std.testing.expectApproxEqAbs(@as(f32, 12), m.events[0].amount, 0.01);

    // Unknown targets are no-ops (no event, no state).
    try std.testing.expect(!m.damageFrom(999, 5, 555));
    try std.testing.expectEqual(@as(usize, 1), m.ev_n);

    // Lethal attributed hit kills and still events.
    try std.testing.expect(m.damageFrom(11, 30, 555));
    try std.testing.expect(!m.bots[1].alive);
    try std.testing.expectEqual(@as(usize, 1), m.n);
    try std.testing.expectEqual(@as(usize, 2), m.ev_n);
}

test "BotManager drainSenseEvents writes the 16-byte trailer layout and clears" {
    var m: BotManager = .{};
    m.events[0] = .{ .attacker = 7, .victim = 10, .amount = 12.5 };
    m.events[1] = .{ .attacker = -1, .victim = 11, .amount = 42 };
    m.ev_n = 2;

    var out: [128]u8 = [_]u8{0xAA} ** 128;
    const written = m.drainSenseEvents(&out, 16, max_sense_events);
    try std.testing.expectEqual(@as(usize, 2), written);

    const e0 = out[16..32];
    try std.testing.expectEqual(@as(u8, 3), e0[0]); // kind damage
    try std.testing.expectEqual(@as(u8, 0), e0[1]); // pad
    try std.testing.expectEqual(@as(i32, 7), std.mem.readInt(i32, e0[4..8], .little));
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, e0[8..12], .little));
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), @as(f32, @bitCast(std.mem.readInt(u32, e0[12..16], .little))), 0.001);

    const e1 = out[32..48];
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, e1[4..8], .little));
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, e1[8..12], .little));

    // The buffer is cleared: a second drain writes nothing.
    try std.testing.expectEqual(@as(usize, 0), m.drainSenseEvents(&out, 16, max_sense_events));

    // Cap: at most `cap` events are written and the tail is untouched. Fill
    // the buffer through damageFrom (which itself caps at max_sense_events).
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 1;
    for (0..max_sense_events) |i| {
        try std.testing.expect(m.damageFrom(10, 1, @intCast(i)));
    }
    try std.testing.expectEqual(@as(usize, max_sense_events), m.ev_n);
    // Overflow events are dropped (the array is full, not grown).
    try std.testing.expect(m.damageFrom(10, 1, 99));
    try std.testing.expectEqual(@as(usize, max_sense_events), m.ev_n);
    var out2: [512]u8 = [_]u8{0xBB} ** 512;
    const capped = m.drainSenseEvents(&out2, 16, max_sense_events);
    try std.testing.expectEqual(@as(usize, max_sense_events), capped);
    try std.testing.expectEqual(@as(u8, 0xBB), out2[16 + max_sense_events * sense_event_len]);
}

test "BotManager fillSenseBotInfo writes one kind-4 record per live bot" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 100, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true, .weapon_id = 3 };
    m.bots[1] = .{ .net_id = 101, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true, .weapon_id = 1 };
    m.bots[2] = .{ .net_id = 102, .x = 0, .y = 70, .z = 0, .hp = 0, .alive = false }; // skipped
    m.n = 2;

    var out: [128]u8 = [_]u8{0xAA} ** 128;
    const written = m.fillSenseBotInfo(&out, 16, max_sense_info);
    try std.testing.expectEqual(@as(usize, 2), written);

    const rec0 = out[16..32];
    try std.testing.expectEqual(@as(u8, 4), rec0[0]); // kind bot-info
    try std.testing.expectEqual(@as(u8, 3), rec0[1]); // weapon_id sniper
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, rec0[4..8], .little));
    const rec1 = out[32..48];
    try std.testing.expectEqual(@as(u8, 1), rec1[1]); // weapon_id shotgun
    try std.testing.expectEqual(@as(i32, 101), std.mem.readInt(i32, rec1[4..8], .little));

    // Cap respected; tail untouched.
    var out2: [128]u8 = [_]u8{0xBB} ** 128;
    try std.testing.expectEqual(@as(usize, 1), m.fillSenseBotInfo(&out2, 16, 1));
    try std.testing.expectEqual(@as(u8, 0xBB), out2[32]);
}

test "BotManager worker melee accumulates atomically and drains attributed" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.bots[1] = .{ .net_id = 11, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 2;

    // Two zombies hit bot 10 in the same parallel pass: atomic fixed-point
    // accumulation, no hp/event mutation on the "worker".
    try std.testing.expect(m.damageFromWorker(10, 500, 12.5));
    try std.testing.expect(m.damageFromWorker(10, 501, 7.25));
    try std.testing.expect(m.damageFromWorker(11, 502, 200.0));
    try std.testing.expect(!m.damageFromWorker(999, 1, 5)); // gone: whiff
    try std.testing.expectEqual(@as(f32, 100), m.bots[0].hp); // not yet applied
    try std.testing.expectEqual(@as(usize, 0), m.ev_n);

    // Main-thread drain: summed damage attributed to the last attacker.
    m.drainWorkerDamage();
    try std.testing.expectApproxEqAbs(@as(f32, 100 - 19.75), m.bots[0].hp, 0.01);
    try std.testing.expectEqual(@as(i32, 501), m.bots[0].last_attacker); // last writer wins
    try std.testing.expectEqual(@as(usize, 2), m.ev_n); // one event per drained bot
    try std.testing.expectEqual(@as(i32, 501), m.events[0].attacker);
    try std.testing.expectEqual(@as(i32, 502), m.events[1].attacker);
    // Bot 11 took the 200 hit too (lethal: hp goes <= 0, alive false).
    try std.testing.expect(m.bots[1].hp <= 0);
    try std.testing.expect(!m.bots[1].alive);

    // Idempotent: a second drain applies nothing.
    const hp = m.bots[0].hp;
    m.drainWorkerDamage();
    try std.testing.expectEqual(hp, m.bots[0].hp);
    try std.testing.expectEqual(@as(usize, 2), m.ev_n);
}

test "BotManager fillSense appends after existing ECS actor records" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 1;
    var out: [256]u8 = undefined;
    @memset(&out, 0xAA); // host_buf-style unwritten tail (would leak as garbage)

    // Two ECS actor records already occupy offsets 16 and 48; base is the
    // header end (16) and `n` is the running record count. Regression: the bot
    // must land at record index 2 (offset 80), NOT at a doubled offset (144),
    // which would leave a garbage gap and push it past the copied region.
    var n: usize = 2;
    m.fillSense(&out, 16, 8, &n);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u8, 2), out[80 + 4]); // kind bot at the right slot
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, out[80..84], .little));
    // The gap record (offset 48+4, the pre-existing actor slot) is untouched.
    try std.testing.expectEqual(@as(u8, 0xAA), out[48 + 4]);
}
