//! Collision hazards: the `BlockDamage` subclasses (spikes, barbed wire) that
//! hurt an entity standing in their cell.
//!
//! Stock runs this from `ChunkCluster.CheckCollisionWithBlocks`: blocks whose
//! ctor set `IsCheckCollideWithEntity` (BlockDamage IL=3) get
//! `OnEntityCollidedWithBlock` when an entity's collision box meets them. zdtd
//! has no physics step, so the equivalent runs once a tick: an entity whose
//! feet cell holds a hazard takes the block's `Damage` once per CONTACT (a
//! per-slot cell latch replaces stock's colliding-pair event), and the block's
//! own leg follows - `BlockSpikes` retracts into its `SiblingBlock` (or air),
//! `BlockBarbed` increments the cell meta and dies at 15, a plain `BlockDamage`
//! wears by `Damage_received`.
//!
//! The same pass carries the `MovementFactor` slow: stock writes
//! `Entity.motionMultiplier` from the MovementFactor of the block the entity
//! stands on (`BlockDamage.OnEntityCollidedWithBlock` IL_00AA-00DD, recomputed
//! on a standing-block change by `EntityAlive.Update` IL_0243), and the factor
//! itself is the block's material `MovementFactor`.
//!
//! Not modelled (recorded): the damage-type resistance leg (`DamageType` +
//! `CalculateBlockDamage`), `DontDamageOnTouch` and the shrunk collision AABB
//! (an entity used to hit only near the cell centre), and the `PassiveEffects`
//! override that lets an entity's own passives scale the standing factor.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const world_store = @import("../../world/store.zig");
const ecs_world = @import("../../ecs/world.zig");
const assets_blocks = @import("../../assets/blocks.zig");
const packages = @import("../../wire/packages.zig");
const log = @import("../../util/log.zig");

/// One packed cell key for the contact latch (x/z 19 bits each, y 8).
fn cellKey(x: i32, y: i32, z: i32) i64 {
    return (@as(i64, @intCast(x & 0x7FFFF)) << 27) |
        (@as(i64, @intCast(z & 0x7FFFF)) << 8) |
        @as(i64, @intCast(y & 0xFF));
}

/// BlockValue meta nibble (bits 22..25): `BlockBarbed` reads and writes it.
/// `BlockValue.meta` bit field (bits 22..25), the same nibble the deco mirror packs
/// child offsets into.
const meta_shift: u5 = 22;
const meta_mask: u32 = 0xf;
/// `BlockBarbed.OnEntityCollidedWithBlock` destroys the wire at meta 15
/// (IL=51): it survives 15 collisions.
pub const barbed_max_meta: u32 = 15;

/// Per-tick collision pass. Runs on the main thread with the rest of the game
/// rules, so the block store is read directly.
pub fn collisionTick(self: *Game) void {
    var it = self.sim.alive_bits.iterator(.{});
    while (it.next()) |idx| {
        const s: ecs_world.Slot = @intCast(idx);
        if (!self.sim.alive[s] or !self.sim.mask[s].transform or !self.sim.mask[s].kind) continue;
        const kind = self.sim.kind[s];
        // Only the entity kinds stock has a collision box for.
        if (kind != .player and kind != .zombie and kind != .animal) continue;
        if (!self.sim.mask[s].network_id) continue;
        const x: i32 = @floor(self.sim.transform[s].x);
        const y: i32 = @floor(self.sim.transform[s].y);
        const z: i32 = @floor(self.sim.transform[s].z);
        const key = cellKey(x, y, z);
        const id = self.world.blockWorld(x, y, z) catch 0;
        // The block being stood on sets the entity's motion multiplier
        // (`Entity.motionMultiplier`); 1 when nothing sets it. Negative or zero
        // authored values clamp at 0 rather than freezing the entity in place.
        const factor = if (id != 0) (self.maxdamage.materialMovementFactor(id) orelse 1.0) else 1.0;
        self.sim.move_scale[s] = @max(factor, 0.0);
        const def = if (id != 0) self.blocks.byId(id) else null;
        if (def == null or def.?.hazard == .none or def.?.hazard_damage <= 0) {
            self.sim.hazard_cell[s] = -1;
            continue;
        }
        if (self.sim.hazard_cell[s] == key) continue; // already hit this contact
        self.sim.hazard_cell[s] = key;
        _ = self.sim.damageFrom(self.sim.network_id[s].id, @floatFromInt(def.?.hazard_damage), -1);
        applyBlockLeg(self, x, y, z, id, def.?);
    }
}

/// The block's own leg after the collision damage, mirroring
/// `BlockDamage.OnEntityCollidedWithBlock` (IL=126) and its two overrides.
fn applyBlockLeg(self: *Game, x: i32, y: i32, z: i32, id: u16, def: assets_blocks.BlockDef) void {
    switch (def.hazard) {
        .spikes => {
            // `BlockSpikes.OnEntityCollidedWithBlock` (IL=38): a non-air
            // SiblingBlock replaces the cell (type swap, damage 0), else air.
            const sib = if (def.hazard_sibling.len > 0)
                (self.maxdamage.idByName(def.hazard_sibling) orelse 0)
            else
                0;
            if (sib != 0) {
                const cur = self.blockRawAt(x, y, z);
                const raw: u32 = (cur & ~@as(u32, 0xffff)) | @as(u32, sib);
                writeCellRaw(self, x, y, z, raw, sib);
            } else {
                clearCell(self, x, y, z, id);
            }
        },
        .barbed => {
            // `BlockBarbed.OnEntityCollidedWithBlock` (IL=51): increment the
            // cell meta; at 15 the wire is gone, otherwise commit the word.
            const cur = self.blockRawAt(x, y, z);
            const meta = (cur >> meta_shift) & meta_mask;
            if (meta + 1 >= barbed_max_meta) {
                clearCell(self, x, y, z, id);
                return;
            }
            const raw = (cur & ~(meta_mask << meta_shift)) | ((meta + 1) << meta_shift);
            writeCellRaw(self, x, y, z, raw, id);
        },
        .damage => {
            // Plain BlockDamage: the collision wears the block by
            // `Damage_received` (`CalculateBlockDamage` + DamageBlock).
            if (def.hazard_damage_received <= 0) return;
            const max_hp = self.maxDamageForBlock(id);
            const total = self.addBlockDamage(x, y, z, @intCast(@min(def.hazard_damage_received, 65535))) catch return;
            if (max_hp == 0 or total < max_hp) {
                if (max_hp != 0) self.echoBlockDamage(x, y, z, id, total);
                return;
            }
            const down_raw = self.downgradeBreakRaw(x, y, z, id);
            if (down_raw != 0) {
                self.noteBlockRemoved(x, y, z, id);
                self.world.setBlockRawWorld(x, y, z, down_raw) catch return;
                self.noteBlockAdded(x, y, z, world_store.typeId(down_raw));
                self.clearBlockHp(x, y, z);
                self.clearBlockRaw(x, y, z);
                if (packages.buildSetBlockBodyRaw(&self.body_buf, x, y, z, down_raw, 0, -1, -1)) |sb| {
                    self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(x), @floatFromInt(z), self.interest_range) catch {};
                } else |_| {}
                return;
            }
            clearCell(self, x, y, z, id);
        },
        .none => {},
    }
}

/// Write a cell's raw BlockValue and echo it to nearby clients.
fn writeCellRaw(self: *Game, x: i32, y: i32, z: i32, raw: u32, id: u16) void {
    self.setBlockRaw(x, y, z, raw);
    self.world.setBlockRawWorld(x, y, z, raw) catch return;
    self.echoBlockDamage(x, y, z, id, self.getBlockHp(x, y, z));
    if (packages.buildSetBlockBodyRaw(&self.body_buf, x, y, z, raw, self.getBlockHp(x, y, z), -1, -1)) |sb| {
        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(x), @floatFromInt(z), self.interest_range) catch {};
    } else |_| {}
}

/// Remove a hazard cell (air) and echo it.
fn clearCell(self: *Game, x: i32, y: i32, z: i32, id: u16) void {
    self.noteBlockRemoved(x, y, z, id);
    self.world.setBlockWorld(x, y, z, 0) catch return;
    self.clearBlockHp(x, y, z);
    self.clearBlockRaw(x, y, z);
    if (packages.buildSetBlockBody(&self.body_buf, x, y, z, 0)) |sb| {
        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(x), @floatFromInt(z), self.interest_range) catch {};
    } else |_| {}
    _ = log;
}
