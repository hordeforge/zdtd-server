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
const wire_binary = @import("../../wire/binary.zig");

const max_land_claims = game_mod.max_land_claims;

/// Combined block-damage verdict: static host first, then Wasm (first non-zero
/// wins; 0 = no plugin vetoes/scales, keep today's behaviour).
fn blockDamageVerdict(self: *Game, x: i32, y: i32, z: i32, dmg: i32) i32 {
    const sv = self.plugins.blockDamage(x, y, z, dmg);
    return if (sv != 0) sv else self.wasm_plugins.blockDamage(x, y, z, dmg);
}

/// Register (or replace) a land claim owned by `owner_entity` at a keystone.
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
    const key = packBlockKey(x, y, z);
    var i: usize = 0;
    while (i < self.block_hp_n) : (i += 1) {
        if (self.block_hp_key[i] == key) return self.block_hp[i];
    }
    return 0;
}

/// Store absolute BlockValue.damage (stock DamageBlock number line).
pub fn setBlockHp(self: *Game, x: i32, y: i32, z: i32, abs: u16) void {
    const key = packBlockKey(x, y, z);
    var i: usize = 0;
    while (i < self.block_hp_n) : (i += 1) {
        if (self.block_hp_key[i] != key) continue;
        self.block_hp[i] = abs;
        return;
    }
    if (self.block_hp_n >= self.block_hp_key.len) {
        var j: usize = 1;
        while (j < self.block_hp_n) : (j += 1) {
            self.block_hp_key[j - 1] = self.block_hp_key[j];
            self.block_hp[j - 1] = self.block_hp[j];
        }
        self.block_hp_n -= 1;
    }
    self.block_hp_key[self.block_hp_n] = key;
    self.block_hp[self.block_hp_n] = abs;
    self.block_hp_n += 1;
}

/// Apply damage to a block (the single choke point for player dig, zombie
/// chew and admin edits). pub so scenarios can drive the on_block_damage
/// plugin verdict through the real path.
pub fn addBlockDamage(self: *Game, x: i32, y: i32, z: i32, dmg: u16) u16 {
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
    self.setBlockHp(x, y, z, abs);
    return abs;
}

pub fn clearBlockHp(self: *Game, x: i32, y: i32, z: i32) void {
    const key = packBlockKey(x, y, z);
    var i: usize = 0;
    while (i < self.block_hp_n) : (i += 1) {
        if (self.block_hp_key[i] != key) continue;
        self.block_hp_n -= 1;
        self.block_hp_key[i] = self.block_hp_key[self.block_hp_n];
        self.block_hp[i] = self.block_hp[self.block_hp_n];
        return;
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
