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
/// Flat damage a successful `bot shoot` applies to its target (ADR 0026 host
/// floor; the guest already gated the shot on accuracy).
pub const bot_shoot_damage: f32 = 12.0;
/// Headshot damage multiplier (cross-pollinated from clanker TryShootBurst
/// HeadshotMultiplier); applied when the guest flags `bot shoot ... head`.
pub const bot_headshot_multiplier: f32 = 2.0;
/// Default bot max HP (ADR 0026; the brain normalizes hurt against 100).
pub const bot_max_hp: f32 = 100;

/// Flat XZ spawn spread used by `bot count` / `bot spawn` fallback so the
/// floor bots do not stack on one cell.
const bot_spawn_spread: f32 = 2.0;
/// Default bot spawn Y when the verb carries only [name] [x z] (flat ground).
const bot_spawn_y: f32 = 70;
/// Horizontal arrival tolerance: move intent clears when within this distance.
const arrival_dist: f32 = 0.05;

/// Sense record byte size (BOTS_SPEC §3): one fixed 32-byte record per entity.
pub const sense_record_len: usize = 32;
/// Sense kind value for a bot (BOTS_SPEC §3: 0 player, 1 zombie, 2 bot).
const sense_kind_bot: u8 = 2;

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
    /// Operator/console display name (bounded, no heap). The stock client needs
    /// an entity_name in the player-mesh spawn body, so bots carry one.
    name: [24]u8 = .{0} ** 24,
    name_len: usize = 0,

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
    /// Fixed slot table; slots are recycled on remove (a zeroed slot is free).
    bots: [max_bots]Bot = undefined,
    /// Live bot count (spawn ++, remove / kill --). Indexes known_bots bits.
    n: usize = 0,

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
        const gy = g.groundHeight(@intFromFloat(@floor(x)), @intFromFloat(@floor(z)));
        self.bots[slot] = .{
            .net_id = id,
            .x = x,
            .y = gy,
            .z = z,
            .hp = @max(hp, 1),
            .alive = true,
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
    /// when the shot is not blocked by solid voxels (BOTS_SPEC §4 host-LOS gate;
    /// `Game.botLosClear` from the shooter's eye to the target's chest). A live
    /// bot target takes bot_shoot_damage (dies at hp <= 0); any other target
    /// resolves through the ECS damage path (guarded against absence). The
    /// optional `head` token applies the headshot multiplier (cross-pollinated
    /// from clanker TryShootBurst HeadshotMultiplier).
    pub fn shoot(self: *BotManager, g: *Game, shooter: i32, target: i32, head: bool) void {
        const ss = self.find(shooter) orelse return;
        const dmg = bot_shoot_damage * (if (head) bot_headshot_multiplier else 1.0);

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
        const eye: [3]f32 = .{ p.x, p.y + 1.45, p.z };
        const chest: [3]f32 = .{ tpos[0], tpos[1] + 1.05, tpos[2] };
        if (!g.botLosClear(eye, chest)) return;

        if (self.damageBot(target, dmg)) return;
        // ECS target (player/zombie/...): damage resolves to no-op on absence.
        _ = g.sim.damage(target, dmg);
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
        var spread: u32 = 1;
        while (self.n < target) : (spread += 1) {
            const ix: f32 = @as(f32, @floatFromInt(spread)) * bot_spawn_spread;
            const iz: f32 = @as(f32, @floatFromInt(spread % 3)) * bot_spawn_spread;
            if (self.spawn(g, ix, bot_spawn_y, iz, bot_max_hp) == null) break;
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
            _ = self.spawnNamed(g, x, bot_spawn_y, z, bot_max_hp, name);
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
        for (&self.bots) |*b| {
            if (!b.alive or !b.move_active) continue;
            stepMove(b, dt);
            b.y = g.groundHeight(@intFromFloat(@floor(b.x)), @intFromFloat(@floor(b.z)));
        }
    }

    /// Append Bot sense records after the host's ECS actor records (BOTS_SPEC
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
    if (d2 <= arrival_dist * arrival_dist) {
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
