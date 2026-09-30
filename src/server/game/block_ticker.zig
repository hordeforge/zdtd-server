//! Block tick scheduler: the `WorldBlockTicker` half of stock's block tick
//! model (RE blocks.md section 7, `World.OnUpdateTick`).
//!
//! A block that wants a later tick registers one through
//! `WorldBlockTicker.AddScheduledBlockUpdate(pos, blockID, ticks)`; the ticker
//! fires `Block.UpdateTick(world, pos, bv, bRandomTick, ticksIfLoaded, rnd)`
//! when the tick count lands. zdtd keeps the queue as a fixed ring drained in
//! insertion order (deterministic, no allocation on the tick path); a full ring
//! drops the newest request and counts it, which fails a crop chain closed
//! rather than growing an unbounded list.
//!
//! `BlockPlantGrowing` (IL=239) is the consumer implemented here, the canonical
//! case from the RE:
//!   1. `Next` air -> nothing to grow into.
//!   2. `CheckPlantAlive` false -> the plant is dead: the cell goes air.
//!   3. random tick -> reschedule only.
//!   4. light below `LightLevelGrow` -> reschedule.
//!   5. the cell above must be air unless `GrowIfAnythinOnTop`.
//!   6. `CanGrowOn` (soil `FertileLevel`) -> swap in `Next`, copy rotation/meta,
//!      bump meta when `IsGrowOnTopEnabled`, reschedule.
//!
//! Not modelled (recorded): stock's block-light channel. `GetLight` and
//! `GetBlockLightValue` are answered by "is the cell open to the sky" (a cell
//! at or above its column's surface reads 15, else 0), so a crop under a roof
//! dies and one outdoors grows; stock's lamp/dynamic light contribution is out
//! of scope until zdtd simulates light.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ecs_world = @import("../../ecs/world.zig");
const world_store = @import("../../world/store.zig");
const assets_blocks = @import("../../assets/blocks.zig");
const packages = @import("../../wire/packages.zig");
const world_explosion = @import("world_explosion.zig");
const invsys = @import("../../ecs/inventory.zig");
const protocol = @import("../../protocol.zig");

/// Scheduled block ticks held at once. A streamed POI farm can register a few
/// hundred plants; the ring is far above that, and a drop is counted rather
/// than silently growing the queue.
pub const tick_queue_cap: usize = 4096;
/// `Block.GetTickRate` default: the reschedule interval in ticks (RE blocks.md
/// section 7).
pub const default_growth_rate: u32 = 10;
/// Random-growth jitter band: `GrowthRate` * [0.5, 1.5] (RE
/// `BlockPlantGrowing.addScheduledTick`, IL=63).
pub const growth_jitter_min: f32 = 0.5;
pub const growth_jitter_max: f32 = 1.5;
/// `BlockTorchHeatMap.UpdateTick` (IL=35) feeds the AI heat map with
/// `HeatMapStrength * 0.4` (blocks.md:799-800). A burning workstation feeds its
/// full strength instead (`TileEntity.emitHeatMapEvent` IL=48), so the two
/// sources carry different scales.
pub const torch_heat_scale: f32 = 0.4;
/// `Block.GetTickRate` for a heat block: UpdateTick reschedules itself every
/// 10 ticks, so a torch reports ten times a second rather than every tick.
pub const heat_tick_rate: u32 = 10;

pub const ScheduledTick = struct {
    due: u64,
    x: i32,
    y: i32,
    z: i32,
    id: u16,
};

/// Register a block tick `delay_ticks` from now. The ring is append-only and
/// drained in order, so the schedule is deterministic for a given run.
pub fn schedule(self: *Game, x: i32, y: i32, z: i32, id: u16, delay_ticks: u32) void {
    if (id == 0) return;
    if (self.block_tick_n >= self.block_tick_q.len) {
        self.harness.counters.inc(.block_tick_drops);
        return;
    }
    self.block_tick_q[self.block_tick_n] = .{
        .due = self.tick_n + delay_ticks,
        .x = x,
        .y = y,
        .z = z,
        .id = id,
    };
    self.block_tick_n += 1;
}

/// Drain every tick that has come due. Runs on the main thread with the rest of
/// the game rules (the block store is read directly, as the hazard pass does).
pub fn tick(self: *Game) void {
    var i: usize = 0;
    while (i < self.block_tick_n) {
        const t = self.block_tick_q[i];
        if (t.due > self.tick_n) {
            i += 1;
            continue;
        }
        // Swap-remove: the queue is unordered by design (each entry carries its
        // own due tick), so removing the drained entry by moving the tail here
        // keeps the pass allocation-free and O(n).
        self.block_tick_n -= 1;
        self.block_tick_q[i] = self.block_tick_q[self.block_tick_n];
        run(self, t);
    }
}

/// Arm a mine's fuse. `TriggerMine` (IL=99) plays the trigger sound and
/// schedules the block's own update `TriggerDelay * 20` sim ticks out; the
/// tick then detonates (`BlockMine.UpdateTick` IL=8). A cell that already has a
/// fuse burning is left alone, so a second contact cannot double-schedule the
/// same mine.
pub fn armMine(self: *Game, x: i32, y: i32, z: i32, id: u16, def: assets_blocks.BlockDef) void {
    if (mineArmedAt(self, x, y, z, id)) return;
    const delay_ticks: u32 = @intFromFloat(@max(def.trigger_delay, 0) * @as(f32, @floatFromInt(protocol.ticks_per_second)));
    schedule(self, x, y, z, id, delay_ticks);
}

fn mineArmedAt(self: *const Game, x: i32, y: i32, z: i32, id: u16) bool {
    var i: usize = 0;
    while (i < blockTickCount(self)) : (i += 1) {
        const t = blockTickAt(self, i);
        if (t.id == id and t.x == x and t.y == y and t.z == z) return true;
    }
    return false;
}

/// The queue lives on `Game`; these two keep the module's private ring access
/// in one place.
fn blockTickCount(self: *const Game) usize {
    return self.block_tick_n;
}

fn blockTickAt(self: *const Game, i: usize) ScheduledTick {
    return self.block_tick_q[i];
}

/// One due tick: dispatch on the block's class.
fn run(self: *Game, t: ScheduledTick) void {
    const cur = self.world.blockWorld(t.x, t.y, t.z) catch return;
    // The cell changed since it was scheduled (harvested, replaced, collapsed):
    // stock's ticker re-reads the cell and drops a stale entry the same way.
    if (cur != t.id) return;
    const def = self.blocks.byId(t.id) orelse return;
    if (def.mine) {
        mineTick(self, t, def);
        return;
    }
    if (def.heat_strength > 0 and isHeatBlockClass(def.class)) {
        heatTick(self, t, def);
        return;
    }
    if (def.plant_growing) plantTick(self, t, def);
}

/// `BlockTorchHeatMap.UpdateTick` (IL=35): a placed torch/candle/barrel adds
/// `HeatMapStrength * 0.4` to the region's activity for the stock 720-tick
/// duration, then reschedules itself `GetTickRate` ticks out. Rescheduling
/// through the ticker is what keeps the emission at ten a second instead of the
/// every-tick feed that inflated heat (and the scout/wandering spawns it
/// drives) by 25x.
fn heatTick(self: *Game, t: ScheduledTick, def: assets_blocks.BlockDef) void {
    const strength: f32 = def.heat_strength;
    self.sim.director.notifyActivity(
        @floatFromInt(t.x),
        @floatFromInt(t.z),
        strength * torch_heat_scale,
        self.sim.rules.director.heat_event_ticks,
    );
    schedule(self, t.x, t.y, t.z, t.id, heat_tick_rate);
}

/// The always-on heat classes: `BlockTorchHeatMap` and the burning `Light`
/// blocks stock seeds the same way.
pub fn isHeatBlockClass(class: []const u8) bool {
    return std.mem.eql(u8, class, "TorchHeatMap") or std.mem.eql(u8, class, "Light");
}

/// Register a placed always-on heat block with the ticker. Called from
/// `noteBlockAdded`, the one place every add routes through.
pub fn noteHeatBlock(self: *Game, x: i32, y: i32, z: i32, id: u16) void {
    const def = self.blocks.byId(id) orelse return;
    if (def.heat_strength <= 0 or !isHeatBlockClass(def.class)) return;
    schedule(self, x, y, z, id, heat_tick_rate);
}

/// `BlockMine.UpdateTick` (IL=8): the fuse ends and the mine detonates. The
/// block itself goes air first (`explode(world, ref, -1)` runs through the
/// SetBlock path in stock), then the authored `ExplosionData` places the block
/// and entity damage with a linear falloff and the client gets the blast FX.
fn mineTick(self: *Game, t: ScheduledTick, def: assets_blocks.BlockDef) void {
    clearCell(self, t.x, t.y, t.z, t.id);
    const cx: f32 = @floatFromInt(t.x);
    const cy: f32 = @floatFromInt(t.y);
    const cz: f32 = @floatFromInt(t.z);
    const r_blocks = @max(def.explosion_radius_blocks, 0);
    if (r_blocks > 0 and def.explosion_block_damage > 0) {
        const ir: i32 = @intFromFloat(@ceil(r_blocks));
        const r2 = r_blocks * r_blocks;
        var dy: i32 = -ir;
        while (dy <= ir) : (dy += 1) {
            var dz: i32 = -ir;
            while (dz <= ir) : (dz += 1) {
                var dx: i32 = -ir;
                while (dx <= ir) : (dx += 1) {
                    const d2f: f32 = @floatFromInt(dx * dx + dy * dy + dz * dz);
                    if (d2f > r2) continue;
                    const wx = t.x + dx;
                    const wy = t.y + dy;
                    const wz = t.z + dz;
                    const id = self.blockIdAtWorld(wx, wy, wz);
                    if (id == 0) continue;
                    const falloff = world_explosion.blastFalloff(wx, wy, wz, cx, cy, cz, r_blocks);
                    _ = self.blastBlock(wx, wy, wz, id, def.explosion_block_damage, falloff, 1.0, -1);
                }
            }
        }
    }
    // Entity leg: `Explosion.AttackEntities` with the same linear falloff. The
    // blast's armour and resist legs are the residual (the block leg runs
    // through `blastBlock`, which owns those).
    const r_ent = @max(def.explosion_radius_entities, 0);
    if (r_ent > 0 and def.explosion_entity_damage > 0) {
        const r2e = r_ent * r_ent;
        var it = self.sim.alive_bits.iterator(.{});
        while (it.next()) |idx| {
            const es: ecs_world.Slot = @intCast(idx);
            if (!self.sim.mask[es].transform or !self.sim.mask[es].health) continue;
            const kind = self.sim.kind[es];
            if (kind == .trader or kind == .loot_bag) continue;
            const nid = self.sim.network_id[es].id;
            if (nid <= 0) continue;
            const tt = self.sim.transform[es];
            const edx = tt.x - cx;
            const edy = tt.y - cy;
            const edz = tt.z - cz;
            const ed2 = edx * edx + edy * edy + edz * edz;
            if (ed2 > r2e) continue;
            const fall = 1.0 - @sqrt(ed2) / r_ent;
            if (fall <= 0) continue;
            var amount = def.explosion_entity_damage * fall;
            if (self.sim.mask[es].player and self.sim.player[es].peer_slot >= 0) {
                amount *= 1.0 - invsys.generalDamageResist(&self.sim, es);
            }
            if (amount <= 0) continue;
            _ = self.sim.damageFrom(nid, amount, -1);
        }
    }
    self.sim.pushNoise(cx, cy, cz, self.sim.rules.ai.combat_noise_radius);
    if (packages.buildExplosionClient(
        self.body_buf[0..192],
        cx,
        cy,
        cz,
        0,
        @trunc(@min(def.explosion_block_damage, 65535.0)),
        @intCast(@max(1, @as(u32, @intFromFloat(@ceil(@max(r_blocks, r_ent)))))),
        @trunc(@min(def.explosion_entity_damage, 65535.0)),
        -1,
    )) |fxb| {
        self.broadcastNear("NetPackageExplosionClient", fxb, cx, cz, self.interest_range) catch {};
    } else |_| {}
}

/// `BlockPlantGrowing.UpdateTick` (IL=239).
fn plantTick(self: *Game, t: ScheduledTick, def: assets_blocks.BlockDef) void {
    // 1. Nothing to grow into: the chain ends here.
    const next = self.blocks.byName(def.plant_next) orelse return;
    if (next.id == self.world.terrain_ids.air) return;
    // 2-3. Alive check (`CheckPlantAlive` -> `CanPlantStay`): an unlit or
    // unsupported plant is destroyed, not left standing.
    if (!plantCanStay(self, t.x, t.y, t.z, def)) {
        clearCell(self, t.x, t.y, t.z, t.id);
        return;
    }
    // 4. Light gate: `GetLight(pos + up, LIGHT_TYPE 1) < LightLevelGrow`.
    if (def.light_level_grow != 0 and plantLight(self, t.x, t.y + 1, t.z) < @as(u8, @intCast(@min(def.light_level_grow, 15)))) {
        schedule(self, t.x, t.y, t.z, t.id, delayFor(self, t.x, t.y, t.z, def));
        return;
    }
    // 5. `GrowIfAnythinOnTop`: an ordinary plant needs the cell above clear.
    if (!def.grow_if_anything_on_top) {
        const above = self.world.blockWorld(t.x, t.y + 1, t.z) catch 0;
        if (above != 0) return;
    }
    // 6. Grow: swap in `Next`, keeping rotation/meta (`BlockPlantGrowing`
    // copies the BlockValue and only changes the type, plus the optional
    // meta bump with a cap of 15).
    const cur_raw = self.blockRawAt(t.x, t.y, t.z);
    const meta = (cur_raw >> meta_shift) & meta_mask;
    const bumped = if (def.grow_on_top_enabled and meta < meta_mask) meta + 1 else meta;
    var raw: u32 = (cur_raw & ~@as(u32, 0xffff)) | @as(u32, next.id);
    raw = (raw & ~(meta_mask << meta_shift)) | (bumped << meta_shift);
    commitCell(self, t.x, t.y, t.z, raw, next.id);
    schedule(self, t.x, t.y, t.z, next.id, delayFor(self, t.x, t.y, t.z, def));
}

/// `BlockValue` meta nibble (bits 22..25), the same field the hazard pass and
/// the deco mirror pack.
const meta_shift: u5 = 22;
const meta_mask: u32 = 0xf;

/// `BlockPlant.CanPlantStay` (IL=41): with a `LightLevelStay` configured, both
/// the cell and the cell above must be lit, unless the cell is open to the sky;
/// the final gate is `CanGrowOn` against the block below.
fn plantCanStay(self: *Game, x: i32, y: i32, z: i32, def: assets_blocks.BlockDef) bool {
    if (def.light_level_stay != 0) {
        const need: u8 = @intCast(@min(def.light_level_stay, 15));
        if (plantLight(self, x, y, z) < need and plantLight(self, x, y + 1, z) < need and
            !openSkyAbove(self, x, y, z))
        {
            return false;
        }
    }
    return canGrowOn(self, x, y - 1, z, def);
}

/// `BlockPlant.CanGrowOn` (IL=24): a plant with a `FertileLevel` needs soil
/// whose material is at least that fertile; `FertileLevel` 0 accepts anything.
fn canGrowOn(self: *Game, x: i32, y: i32, z: i32, def: assets_blocks.BlockDef) bool {
    if (def.fertile_level <= 0) return true;
    const soil = self.world.blockWorld(x, y, z) catch 0;
    if (soil == 0) return false;
    const soil_fertile = self.maxdamage.materialFertileLevel(soil) orelse 0;
    return soil_fertile >= def.fertile_level;
}

/// Stock's block-light read. Without a light channel the answer is the sky
/// exposure: a cell at or above its column's surface reads 15, anything under
/// cover reads 0 (see the module header).
fn plantLight(self: *Game, x: i32, y: i32, z: i32) u8 {
    if (self.plant_light_fn) |f| return f(self.plant_light_ctx, x, y, z);
    return if (openSkyAbove(self, x, y, z)) 15 else 0;
}

/// `World.IsOpenSkyAbove(x, y, z)`: no solid block above the cell. Bounded
/// scan (a roof sits within a couple of dozen cells; the column profile caps at
/// 255), so a plant under a roof reads dark and one in the open reads lit.
fn openSkyAbove(self: *Game, x: i32, y: i32, z: i32) bool {
    var yy = y + 1;
    const cap = @min(yy + sky_scan_cells, 255);
    while (yy <= cap) : (yy += 1) {
        if (self.world.isSolidWorld(x, yy, z) catch false) return false;
    }
    return true;
}

/// Cells the sky-exposure probe walks above a plant cell.
const sky_scan_cells: i32 = 24;

/// `addScheduledTick` (IL=63): the deterministic form uses `GrowthRate`, the
/// random form jitters it by `GrowthDeviation` (a gaussian in stock; zdtd uses
/// the seeded per-position roll) and clamps into [0.5x, 1.5x].
fn delayFor(self: *Game, x: i32, y: i32, z: i32, def: assets_blocks.BlockDef) u32 {
    const base: f32 = if (def.growth_rate > 0) def.growth_rate else @floatFromInt(default_growth_rate);
    if (!def.growth_random or def.growth_deviation <= 0) {
        return @intFromFloat(@max(base, 1.0));
    }
    // Deterministic per (cell, tick): the crop chain stays reproducible for a
    // given seed and schedule, which stock's GameRandom also is per world.
    const cell_seed: u32 = @truncate(@as(u64, @bitCast(@as(i64, x) *% 73856093 ^ @as(i64, z) *% 19349663 ^ @as(i64, y) *% 83492791)));
    var prng = @import("../../util/rng.zig").XorShift32.init(cell_seed ^ @as(u32, @truncate(self.tick_n)));
    const roll = prng.nextFloat() * 2.0 - 1.0; // [-1, 1]
    const jittered = base * (1.0 + def.growth_deviation * roll);
    const lo = base * growth_jitter_min;
    const hi = base * growth_jitter_max;
    return @intFromFloat(@max(@min(jittered, hi), lo));
}

/// Swap a cell's type on the server and echo it, the same write the other
/// server-side block paths use.
fn commitCell(self: *Game, x: i32, y: i32, z: i32, raw: u32, id: u16) void {
    self.noteBlockRemoved(x, y, z, 0);
    self.setBlockRaw(x, y, z, raw);
    self.world.setBlockRawWorld(x, y, z, raw) catch return;
    self.noteBlockAdded(x, y, z, id);
    if (packages.buildSetBlockBodyRaw(&self.body_buf, x, y, z, raw, self.getBlockHp(x, y, z), -1, -1)) |sb| {
        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(x), @floatFromInt(z), self.interest_range) catch {};
    } else |_| {}
}

/// Remove a dead plant (stock `CheckPlantAlive` -> `SetBlockRPC(Air)`).
fn clearCell(self: *Game, x: i32, y: i32, z: i32, id: u16) void {
    self.noteBlockRemoved(x, y, z, id);
    self.world.setBlockWorld(x, y, z, 0) catch return;
    self.clearBlockHp(x, y, z);
    self.clearBlockRaw(x, y, z);
    if (packages.buildSetBlockBody(&self.body_buf, x, y, z, 0)) |sb| {
        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(x), @floatFromInt(z), self.interest_range) catch {};
    } else |_| {}
}

/// Every block added to the world that grows: register its first tick. Called
/// from the one place that owns `OnBlockAdded` consequences, so player
/// placement, prefab stamping and the deco mirror all route through it.
pub fn noteAdded(self: *Game, x: i32, y: i32, z: i32, id: u16) void {
    const def = self.blocks.byId(id) orelse return;
    if (!def.plant_growing) return;
    schedule(self, x, y, z, id, delayFor(self, x, y, z, def));
}
