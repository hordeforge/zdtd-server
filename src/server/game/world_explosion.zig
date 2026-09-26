//! World explosion sim: deferred detonation drain, block blast.
//!
//! Split out of server/game/world.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const world_store = @import("../../world/store.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const assets_spawning = @import("../../assets/spawning.zig");
const ecs_components = @import("../../ecs/components.zig");

/// float world position, so the damage is symmetric around the real blast
/// rather than around the cell index the loop iterates - the difference is
/// largest on the diagonals, where the cell index overstates the distance.
/// 0 or less means the block is outside the blast.
pub fn blastFalloff(block_x: i32, block_y: i32, block_z: i32, px: f32, py: f32, pz: f32, radius: f32) f32 {
    const bx = @as(f32, @floatFromInt(block_x)) + 0.5 - px;
    const by = @as(f32, @floatFromInt(block_y)) + 0.5 - py;
    const bz = @as(f32, @floatFromInt(block_z)) + 0.5 - pz;
    const dist = std.math.clamp(@sqrt(bx * bx + by * by + bz * bz) - 0.5, 0, radius);
    return 1.0 - dist / radius;
}

pub fn drainExplosions(self: *Game) void {
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
        const ir: i32 = @ceil(radius);
        const bx: i32 = @floor(ex.x);
        const by: i32 = @floor(ex.y);
        const bz: i32 = @floor(ex.z);
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
                    const falloff = blastFalloff(wx, wy, wz, ex.x, ex.y, ex.z, radius);
                    _ = self.blastBlock(wx, wy, wz, id, block_dmg, falloff, mult, nid);
                }
            }
        }
        // Combat noise so nearby zombies react to the blast.
        self.sim.pushNoise(ex.x, ex.y, ex.z, self.sim.rules.ai.combat_noise_radius);
        // Blast FX (stock GameManager.explode IL_021D sends
        // NetPackageExplosionClient for EVERY explosion, cops included): the
        // client plays the flash/sound at the blast center. Same builder and
        // near-range fan as the C2S ExplosionInitiate relay.
        if (packages.buildExplosionClient(
            self.body_buf[96..288],
            ex.x,
            ex.y,
            ex.z,
            0,
            @trunc(@min(block_dmg, 65535.0)),
            @intCast(@max(1, @as(u32, @trunc(radius)))),
            @trunc(@min(block_dmg, 65535.0)),
            nid,
        )) |fxb| {
            self.broadcastNear("NetPackageExplosionClient", fxb, ex.x, ex.z, self.interest_range) catch {};
        } else |_| {}
    }
}

pub fn blastBlock(
    self: *Game,
    wx: i32,
    wy: i32,
    wz: i32,
    id: u16,
    power: f32,
    falloff: f32,
    category_mult: f32,
    instigator_entity: i32,
) bool {
    if (id == 0 or !(power > 0) or !(falloff > 0) or !(category_mult > 0)) return false;
    // materials.xml CanDestroy=false: stock zeroes the damage scalar for such
    // a block (ItemActionAttack::Hit IL_028A-029D), so a blast never carves it.
    if (!self.maxdamage.canDestroyFor(id)) return false;
    const max_hp = self.maxDamageForBlock(id);
    if (max_hp == 0) return false;
    const resist = @min(@max(self.maxdamage.explosionResistanceFor(id), 0), 1);
    // Land claim leg (stock Explosion::AttackBlocks divides by
    // GetLandProtectionHardnessModifier, IL_03EA): a stranger's blast meets a
    // tougher block inside somebody else's claim.
    const land_mod = self.landProtectionHardnessModifier(wx, wy, wz, instigator_entity);
    if (!(land_mod > 0)) return false;
    var dmg: f32 = undefined;
    if (self.maxdamage.materialHardness(id)) |hardness| {
        if (hardness > 0) {
            dmg = (1.0 - resist) * power * falloff / (hardness * land_mod) * category_mult;
        } else {
            dmg = @as(f32, @floatFromInt(max_hp)) / land_mod;
        }
    } else {
        dmg = (1.0 - resist) * power * falloff / land_mod * category_mult;
    }
    const dmg_u16: u16 = @trunc(@min(@max(dmg, 0), 65535.0));
    if (dmg_u16 == 0) return false;
    const total = self.addBlockDamage(wx, wy, wz, dmg_u16) catch return false;
    if (total < max_hp) {
        // Stock's explosion sends the changed cells as one SetBlockAndDamage
        // batch, damage-only entries included, so a blast that only cracks a
        // block still shows on every client.
        self.echoBlockDamage(wx, wy, wz, id, total);
        return true;
    }
    // Downgrade swap (stock Block.OnBlockDamaged; the explosion routes through
    // DamageBlock): a block with a DowngradeBlock turns into it instead of
    // breaking.
    const down_raw = self.downgradeBreakRaw(wx, wy, wz, id);
    if (down_raw != 0) {
        // The downgrade displaces the old block and lands a new one, same pair
        // as the other downgrade arms: this one cleared neither side.
        self.noteBlockRemoved(wx, wy, wz, id);
        _ = self.world.setBlockRawWorld(wx, wy, wz, down_raw) catch return true;
        self.noteBlockAdded(wx, wy, wz, world_store.typeId(down_raw));
        self.clearBlockHp(wx, wy, wz);
        self.clearBlockRaw(wx, wy, wz);
        if (packages.buildSetBlockBodyRaw(&self.body_buf, wx, wy, wz, down_raw, 0, -1, -1)) |sb| {
            self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(wx), @floatFromInt(wz), self.interest_range) catch {};
        } else |_| {}
        return true;
    }
    // A removed bedroll clears the owner's respawn point.
    self.noteBlockRemoved(wx, wy, wz, id);
    self.world.setBlockWorld(wx, wy, wz, 0) catch return true;
    self.clearBlockHp(wx, wy, wz);
    self.clearBlockRaw(wx, wy, wz);
    if (packages.buildSetBlockBody(&self.body_buf, wx, wy, wz, 0)) |sb| {
        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(wx), @floatFromInt(wz), self.interest_range) catch {};
    } else |_| {}
    return true;
}
