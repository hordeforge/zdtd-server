//! Domain — extracted from game.zig; helpers take *Game
//! World / claims / block meta / locks. Bodies copied verbatim from game.zig
//! (keeps stock asm.il comments). Persist-owned save/load are intentionally
//! left in persist.zig and not duplicated here:
//!   saveClaims / loadClaims / reclaimForName / saveClock / restoreClock
//!   / saveWeather / restoreWeather / saveBlockMeta / loadBlockMeta
//!   / saveEntities / loadEntities
//! Call as `game_world.registerClaim(g, ...)`.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const world_store = @import("../../world/store.zig");
const packages = @import("../../wire/packages.zig");

const max_land_claims = game_mod.max_land_claims;

/// Combined block-damage verdict: static host first, then Wasm (first non-zero
/// wins; 0 = no plugin vetoes/scales, keep today's behaviour).
fn blockDamageVerdict(self: *Game, x: i32, y: i32, z: i32, dmg: i32) i32 {
    const sv = self.plugins.blockDamage(x, y, z, dmg);
    return if (sv != 0) sv else self.wasm_plugins.blockDamage(x, y, z, dmg);
}

/// Register (or replace) a land claim owned by `owner_entity` at a keystone.
/// Stock placement gates (LandClaimCount / LandClaimDeadZone): a new claim is
/// allowed only when the owner is under the claim count and the keystone is
/// outside the dead zone of every existing claim. Enforcement is refusal to
/// register (the block may still place; the client's own count check usually
/// stops the placement first). DecayMode/OfflineDelay decay amounts stay
/// RE-blocked (GAP row "Land claim rules").
pub fn claimAllowed(self: *Game, owner_entity: i32, x: i32, y: i32, z: i32) bool {
    _ = y; // keystone y does not participate in the 2D dead-zone check
    const dz = self.land_claim_dead_zone;
    var owner_claims: u16 = 0;
    for (self.land_claims[0..self.land_claims_n]) |claim| {
        if (claim.owner_entity == owner_entity) owner_claims += 1;
        if (dz > 0) {
            const dx: i64 = @as(i64, x) - claim.x;
            const ddz: i64 = @as(i64, z) - claim.z;
            if (dx * dx + ddz * ddz < @as(i64, dz) * @as(i64, dz)) return false;
        }
    }
    if (self.land_claim_count > 0 and owner_claims >= self.land_claim_count) return false;
    return true;
}

pub fn registerClaim(self: *Game, x: i32, y: i32, z: i32, owner_entity: i32) void {
    // Capture the stable owner key (login name) so the claim survives a
    // restart; entity ids are reassigned and cannot be persisted.
    var owner_name: [32]u8 = .{0} ** 32;
    var owner_name_len: u8 = 0;
    for (&self.clients) |*c| {
        if (c.entity_id != owner_entity) continue;
        const n = @min(c.name_len, owner_name.len);
        @memcpy(owner_name[0..n], c.name[0..n]);
        owner_name_len = @intCast(n);
        break;
    }
    for (self.land_claims[0..self.land_claims_n]) |*claim| {
        if (claim.x == x and claim.y == y and claim.z == z) {
            claim.owner_entity = owner_entity;
            claim.owner_online = true;
            claim.owner_seen_day = self.sim.director.clock.day;
            claim.owner_name = owner_name;
            claim.owner_name_len = owner_name_len;
            return;
        }
    }
    // Cap: drop new claim rather than grow heap on place path.
    if (self.land_claims_n >= max_land_claims) return;
    self.land_claims[self.land_claims_n] = .{
        .x = x,
        .y = y,
        .z = z,
        .owner_entity = owner_entity,
        .owner_seen_day = self.sim.director.clock.day,
        .owner_name = owner_name,
        .owner_name_len = owner_name_len,
    };
    self.land_claims_n += 1;
}

/// A destroyed keystone no longer protects: drop the claim entirely. The
/// in-memory-only table is a known gap (claims do not persist across a
/// restart); removal still matters for the running session.
pub fn removeClaimAt(self: *Game, x: i32, y: i32, z: i32) void {
    var i: usize = 0;
    while (i < self.land_claims_n) : (i += 1) {
        if (self.land_claims[i].x == x and self.land_claims[i].y == y and self.land_claims[i].z == z) {
            self.land_claims[i] = self.land_claims[self.land_claims_n - 1];
            self.land_claims_n -= 1;
            return;
        }
    }
}

/// Release every claim recorded against `name` and report how many went. The
/// claim record stores the owner's login name (claims.zlc), so `wipeplayer`
/// wiping players.zsv alone would leave that name on disk, still tied to world
/// coordinates. Same release semantics as expireClaims: the keystone stops
/// protecting, nobody inherits it.
pub fn dropClaimsForName(self: *Game, name: []const u8) u32 {
    var dropped: u32 = 0;
    var i: usize = 0;
    while (i < self.land_claims_n) {
        const claim = &self.land_claims[i];
        if (claim.owner_name_len == name.len and std.mem.eql(u8, claim.owner_name[0..claim.owner_name_len], name)) {
            self.land_claims[i] = self.land_claims[self.land_claims_n - 1];
            self.land_claims_n -= 1;
            dropped += 1;
        } else {
            i += 1;
        }
    }
    return dropped;
}

/// Mark every claim owned by `entity` online/offline and refresh the seen
/// day when coming online (expiry base).
pub fn markClaimsForEntity(self: *Game, entity: i32, online: bool) void {
    const day = self.sim.director.clock.day;
    for (self.land_claims[0..self.land_claims_n]) |*claim| {
        if (claim.owner_entity != entity) continue;
        claim.owner_online = online;
        if (online) claim.owner_seen_day = day;
    }
}

/// Day-roll expiry: a claim whose owner has been offline for more than
/// land_claim_expiry_days is released (0 disables).
pub fn expireClaims(self: *Game) void {
    if (self.land_claim_expiry_days == 0) return;
    const day = self.sim.director.clock.day;
    var i: usize = 0;
    while (i < self.land_claims_n) {
        const claim = &self.land_claims[i];
        if (!claim.owner_online and (day - claim.owner_seen_day) > self.land_claim_expiry_days) {
            self.land_claims[i] = self.land_claims[self.land_claims_n - 1];
            self.land_claims_n -= 1;
        } else {
            i += 1;
        }
    }
}

/// MaxDamage from blocks.xml+materials via maxdamage table. Generic floor when unknown.
pub fn maxDamageForBlock(self: *const Game, block_id: u16) u16 {
    if (block_id == 0) return 1;
    if (self.maxdamage.maxDamage(block_id)) |hp| return hp;
    // Table loaded (by_id or name map): fail closed to soft generic, no pin id HP table.
    if (self.maxdamage.by_id.count() > 0 or self.maxdamage.id_by_name.count() > 0) return 100;
    // Offline / empty catalog only: soft defaults by id band (not stock truth).
    if (block_id < 256) return 100;
    if (block_id >= 18000 and block_id < 20000) return 500;
    if (block_id >= 24000) return 50;
    return 500;
}

pub fn packBlockKey(x: i32, y: i32, z: i32) u64 {
    const xu: u64 = @as(u32, @bitCast(x));
    const yu: u64 = @as(u16, @truncate(@as(u32, @bitCast(y))));
    const zu: u64 = @as(u32, @bitCast(z));
    return (xu << 32) | (yu << 16) | (zu & 0xffff);
}

pub fn getBlockHp(self: *const Game, x: i32, y: i32, z: i32) u16 {
    const t = world_store.World.worldToChunk(x, z);
    const c = self.world.chunkAt(t.pos) orelse return 0;
    return c.dmgAt(t.lx, y, t.lz);
}

/// Store absolute BlockValue.damage (stock DamageBlock number line) in the
/// owning chunk's damage plane. The chunk must be materialized (getOrCreate);
/// damage only originates on blocks near players/zombies, i.e. resident chunks.
pub fn setBlockHp(self: *Game, x: i32, y: i32, z: i32, abs: u16) !void {
    const t = world_store.World.worldToChunk(x, z);
    const c = try self.world.getOrCreate(t.pos);
    try c.setDmg(self.world.allocator, t.lx, y, t.lz, abs);
}

/// Apply damage to a block (the single choke point for player dig, zombie
/// chew and admin edits). pub so scenarios can drive the on_block_damage
/// plugin verdict through the real path.
pub fn addBlockDamage(self: *Game, x: i32, y: i32, z: i32, dmg: u16) !u16 {
    // on_block_damage verdict (T15): <0 denies the damage, >0 applies that
    // percent. No plugin exports the hook -> 0 -> today's behaviour.
    var applied = dmg;
    const v = blockDamageVerdict(self, x, y, z, @intCast(dmg));
    if (v < 0) return self.getBlockHp(x, y, z);
    if (v > 0) {
        const scaled: u32 = @as(u32, dmg) * @as(u32, @intCast(v)) / 100;
        applied = @intCast(@min(scaled, 65535));
    }
    const cur = self.getBlockHp(x, y, z);
    const sum: u32 = @as(u32, cur) + applied;
    const abs: u16 = @intCast(@min(sum, 65535));
    try self.setBlockHp(x, y, z, abs);
    return abs;
}

pub fn clearBlockHp(self: *Game, x: i32, y: i32, z: i32) void {
    const t = world_store.World.worldToChunk(x, z);
    const c = self.world.chunkAt(t.pos) orelse return;
    c.clearDmg(t.lx, y, t.lz);
}

/// Drain this tick's Demolition explode requests (RE entity-ai.md
/// EntityZombieCop): the cop dies with the blast (SetDead, no loot), nearby
/// entities take radius-falloff damage, and blocks in the sphere take
/// explosion_block_damage through the single addBlockDamage choke point
/// (breaking when max hp is exceeded). Consume-owns-drain, like the noise
/// ring. Runs after the sim AI pass each tick (Game.step).
pub fn drainExplosions(self: *Game) void {
    const ecs_components = @import("../../ecs/components.zig");
    const n = @min(self.sim.explode_n, ecs_components.explode_cap);
    self.sim.explode_n = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s: u16 = self.sim.explode_reqs[i].slot; // Slot = u16
        if (!self.sim.alive[s] or !self.sim.mask[s].transform or !self.sim.mask[s].network_id) continue;
        const ex = self.sim.transform[s];
        const nid = self.sim.network_id[s].id;
        // Per-entity blast params (spawnZombieDef copies the class's
        // <property class="Explosion"> block onto class_id so the kind-default
        // table row never hides it), then the preloaded class_table row, then
        // the Rules floor. Read before destroy.
        const ci = self.sim.class_id[s];
        const ct = self.sim.class_table[ci.id];
        const radius: f32 = if (ci.explosion_radius > 0)
            ci.explosion_radius
        else if (ct.explosion_radius > 0)
            ct.explosion_radius
        else
            self.sim.rules.ai.explosion_radius;
        const radius_e: f32 = if (ci.explosion_radius_e > 0)
            ci.explosion_radius_e
        else if (ct.explosion_radius_e > 0)
            ct.explosion_radius_e
        else
            radius;
        const ent_dmg: f32 = if (ci.explosion_entity_dmg > 0)
            ci.explosion_entity_dmg
        else if (ct.explosion_entity_dmg > 0)
            ct.explosion_entity_dmg
        else
            self.sim.rules.ai.explosion_entity_damage;
        const block_dmg: f32 = if (ci.explosion_block_dmg > 0)
            ci.explosion_block_dmg
        else if (ct.explosion_block_dmg > 0)
            ct.explosion_block_dmg
        else
            self.sim.rules.ai.explosion_block_damage;
        const bonus_cat = if (ci.explosion_bonus_n > 0) ci.explosion_bonus_cat else ct.explosion_bonus_cat;
        const bonus_mult = if (ci.explosion_bonus_n > 0) ci.explosion_bonus_mult else ct.explosion_bonus_mult;
        const bonus_n: u8 = if (ci.explosion_bonus_n > 0) ci.explosion_bonus_n else ct.explosion_bonus_n;
        const r2 = radius * radius;
        // The cop dies with the blast (RE: SetDead after ExplosionServer).
        self.sim.destroy(s);
        // Entity AoE: linear falloff from the epicentre (players, zombies,
        // animals; falling blocks and vehicles are not damaged).
        const r2e = radius_e * radius_e;
        const kinds = [_]ecs_components.Kind{ .player, .zombie, .animal };
        for (kinds) |kind| {
            for (self.sim.kind_groups.slice(kind)) |t| {
                if (!self.sim.alive[t] or !self.sim.mask[t].transform or !self.sim.mask[t].network_id) continue;
                const dx = self.sim.transform[t].x - ex.x;
                const dz = self.sim.transform[t].z - ex.z;
                const dy = self.sim.transform[t].y - ex.y;
                const d2 = dx * dx + dy * dy + dz * dz;
                if (d2 > r2e) continue;
                const falloff: f32 = 1.0 - @sqrt(d2) / radius_e;
                _ = self.sim.damageFrom(self.sim.network_id[t].id, ent_dmg * falloff, nid);
            }
        }
        // Block AoE: blocks in the sphere (bounded by the radius) take
        // falloff block damage through the choke point, scaled by the class's
        // DamageBonus material multipliers (stock cop: earth category → 0, so
        // terrain survives the blast); break like the chew.
        const ir: i32 = @intFromFloat(@ceil(radius));
        const bx: i32 = @intFromFloat(@floor(ex.x));
        const by: i32 = @intFromFloat(@floor(ex.y));
        const bz: i32 = @intFromFloat(@floor(ex.z));
        var dy2: i32 = -ir;
        while (dy2 <= ir) : (dy2 += 1) {
            var dz2: i32 = -ir;
            while (dz2 <= ir) : (dz2 += 1) {
                var dx2: i32 = -ir;
                while (dx2 <= ir) : (dx2 += 1) {
                    const d2f: f32 = @floatFromInt(dx2 * dx2 + dy2 * dy2 + dz2 * dz2);
                    if (d2f > r2) continue;
                    const wx = bx + dx2;
                    const wy = by + dy2;
                    const wz = bz + dz2;
                    const id = self.blockIdAtWorld(wx, wy, wz);
                    if (id == 0) continue;
                    var mult: f32 = 1;
                    if (self.maxdamage.categoryForBlock(id)) |cat| {
                        var bi: u8 = 0;
                        while (bi < bonus_n) : (bi += 1) {
                            if (std.mem.eql(u8, cat, bonus_cat[bi])) {
                                mult = bonus_mult[bi];
                                break;
                            }
                        }
                    }
                    if (mult == 0) continue; // category immune to this blast
                    const falloff: f32 = 1.0 - @sqrt(d2f) / radius;
                    const dmg: u16 = @intFromFloat(block_dmg * falloff * mult);
                    if (dmg == 0) continue;
                    const max_hp = self.maxDamageForBlock(id);
                    const total = self.addBlockDamage(wx, wy, wz, dmg) catch continue;
                    if (total >= max_hp) {
                        self.world.setBlockWorld(wx, wy, wz, 0) catch continue;
                        self.clearBlockHp(wx, wy, wz);
                        self.clearBlockRaw(wx, wy, wz);
                        if (packages.buildSetBlockBody(&self.body_buf, wx, wy, wz, 0)) |sb| {
                            self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(wx), @floatFromInt(wz), self.interest_range) catch {};
                        } else |_| {}
                    }
                }
            }
        }
        // Combat noise so nearby zombies react to the blast.
        self.sim.pushNoise(ex.x, ex.y, ex.z, self.sim.rules.ai.combat_noise_radius);
    }
}

pub fn setBlockRaw(self: *Game, x: i32, y: i32, z: i32, raw: u32) void {
    const key = packBlockKey(x, y, z);
    var i: usize = 0;
    while (i < self.block_raw_n) : (i += 1) {
        if (self.block_raw_key[i] == key) {
            self.block_raw[i] = raw;
            return;
        }
    }
    if (self.block_raw_n >= self.block_raw_key.len) {
        var j: usize = 1;
        while (j < self.block_raw_n) : (j += 1) {
            self.block_raw_key[j - 1] = self.block_raw_key[j];
            self.block_raw[j - 1] = self.block_raw[j];
        }
        self.block_raw_n -= 1;
    }
    self.block_raw_key[self.block_raw_n] = key;
    self.block_raw[self.block_raw_n] = raw;
    self.block_raw_n += 1;
}

/// Stored BlockValue.rawData for a cell, or 0 when the block was placed
/// without meta (the sparse store only holds cells that carry it).
pub fn blockRawAt(self: *const Game, x: i32, y: i32, z: i32) u32 {
    const key = packBlockKey(x, y, z);
    var i: usize = 0;
    while (i < self.block_raw_n) : (i += 1) {
        if (self.block_raw_key[i] == key) return self.block_raw[i];
    }
    return 0;
}

pub fn clearBlockRaw(self: *Game, x: i32, y: i32, z: i32) void {
    const key = packBlockKey(x, y, z);
    var i: usize = 0;
    while (i < self.block_raw_n) : (i += 1) {
        if (self.block_raw_key[i] != key) continue;
        self.block_raw_n -= 1;
        self.block_raw_key[i] = self.block_raw_key[self.block_raw_n];
        self.block_raw[i] = self.block_raw[self.block_raw_n];
        return;
    }
}

/// Voxel line-of-sight between two world points, used to gate `bot shoot`
/// (RFC 0001 §4: the host rejects an LOS-blocked shot). Samples
/// `World.isSolidWorld` every 0.5 blocks along the line; returns false when a
/// solid block intersects. Chunk-probe errors (unloaded / I/O) fail OPEN
/// (treated as clear) so a bot is not permanently silenced across a chunk
/// border; the guest brain already gates the shot on its own accuracy rolls.
pub fn botLosClear(self: *Game, from: [3]f32, to: [3]f32) bool {
    const dx = to[0] - from[0];
    const dy = to[1] - from[1];
    const dz = to[2] - from[2];
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    if (dist < 0.5) return true;
    const step: f32 = 0.5;
    const n = @as(usize, @intFromFloat(@floor(dist / step)));
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const t = (@as(f32, @floatFromInt(i)) * step) / dist;
        const ix: i32 = @intFromFloat(@floor(from[0] + dx * t));
        const iy: i32 = @intFromFloat(@floor(from[1] + dy * t));
        const iz: i32 = @intFromFloat(@floor(from[2] + dz * t));
        if (self.world.isSolidWorld(ix, iy, iz) catch continue) return false;
    }
    return true;
}

/// Ground/surface Y a bot stands on at world (x, z) — chunk heightAt + 1,
/// matching the Wasm `heightAtWorld` callback (hooks.zig). Materializes the
/// chunk on demand; falls back to y=61 when the probe errors (same fallback as
/// the Wasm hook). Backs bot spawn grounding and move-time y tracking so bots
/// follow terrain instead of floating at a fixed spawn height.
pub fn groundHeight(self: *Game, x: i32, z: i32) f32 {
    const t = world_store.World.worldToChunk(x, z);
    self.terrain_mu.lock();
    defer self.terrain_mu.unlock();
    const ch = self.world.getOrCreate(t.pos) catch return 61;
    return @as(f32, @floatFromInt(ch.heightAt(t.lx, t.lz))) + 1.0;
}

/// True when a solid block occupies the standing cells at `p`: the cell the
/// feet sit in and the one above (head). Chunk-probe errors fail OPEN (treated
/// as clear) so a cover search is not blocked by an unloaded chunk border.
fn coverSolidAt(self: *Game, p: [3]f32) bool {
    const ix: i32 = @intFromFloat(@floor(p[0]));
    const iy: i32 = @intFromFloat(@floor(p[1]));
    const iz: i32 = @intFromFloat(@floor(p[2]));
    if (self.world.isSolidWorld(ix, iy, iz) catch false) return true;
    if (self.world.isSolidWorld(ix, iy + 1, iz) catch false) return true;
    return false;
}

/// A nearby point that is not visible from `threat` — Doom 3 idAASFindCover /
/// clanker `BotBrain.FindCover` port for the `zdtd.query` "cover" verb
/// (RFC 0001 §3). Samples 8 directions at `dist` (default 10 m), grounds each
/// candidate, keeps the ones that are reachable (not solid at body height) and
/// NOT LOS-clear from the threat's eye, and returns the valid candidate
/// nearest to `from` (prefer nearer cover). Null when nothing qualifies.
pub fn findCover(self: *Game, from: [3]f32, threat: [3]f32, dist: f32) ?[3]f32 {
    var best: ?[3]f32 = null;
    var best_score: f32 = -1;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const ang = @as(f32, @floatFromInt(i)) * std.math.pi / 4.0;
        const cx = from[0] + @cos(ang) * dist;
        const cz = from[2] + @sin(ang) * dist;
        const cy = self.groundHeight(@intFromFloat(@floor(cx)), @intFromFloat(@floor(cz)));
        const cand: [3]f32 = .{ cx, cy, cz };
        // Reachable: not inside solid at feet/head height.
        if (coverSolidAt(self, cand)) continue;
        // Must actually hide: the line from the threat's eye to the
        // candidate's chest is blocked (that is the point of cover).
        const threat_eye: [3]f32 = .{ threat[0], threat[1] + 1.45, threat[2] };
        const cand_chest: [3]f32 = .{ cx, cy + 1.05, cz };
        if (botLosClear(self, threat_eye, cand_chest)) continue;
        const ddx = cx - from[0];
        const ddz = cz - from[2];
        const score = 10.0 - @sqrt(ddx * ddx + ddz * ddz) * 0.2;
        if (score > best_score) {
            best_score = score;
            best = cand;
        }
    }
    return best;
}
