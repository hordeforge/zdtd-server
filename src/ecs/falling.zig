//! Falling-block system: stability-collapse groups fall, crush, die.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const c = @import("components.zig");
const inventory = @import("inventory.zig");
const query = @import("query.zig");


/// Stability-collapse groups (RE entity-ai.md EntityFallingBlock landing):
/// the group falls under the stock gravity integrator and dies on ground
/// contact - cells are never re-placed (the collapse already aired them).
/// The land probe reuses the solid_fn hook (same chunk reads as the AI LOS).
///
/// Crush damage (RE entity-ai.md EntityFallingBlock.OnUpdateEntity IL=344):
/// every other tick, entities inside the block's bounds take
/// FastMin(massKg * |vy| * 0.05, 40) reduced by the target's armor
/// mitigation (passive 164 analog), up to 3 hits per entity.
pub fn systemFallingBlocks(w: *World, dt: f32) void {
    const solid_fn = w.solid_fn orelse return;
    const g = w.rules.ai.gravity;
    // Stock getHeadPosition() offsets (entityclasses heights are not parsed;
    // the skip gate is "faller center below the target's head").
    const head_y = [_]f32{ 1.7, 1.8, 1.0 };
    const kinds = [_]c.Kind{ .player, .zombie, .animal };
    // Landing destroy() shifts the live group; snapshot so every faller this
    // tick still gets a gravity/land pass (same pattern as systemDespawnFar).
    var fall_slots: [max_entities]Slot = undefined;
    const fall_n = query.copyKindInto(w, .falling_block, &fall_slots);
    for (fall_slots[0..fall_n]) |s| {
        if (!w.alive[s] or !w.mask[s].falling or !w.mask[s].transform) continue;
        const f = &w.falling[s];
        f.tick +%= 1;
        // Crush pass every other tick while falling fast enough
        // (stock skips when vel.y >= -0.8).
        if (f.mass_kg > 0 and f.vy < -0.8 and (f.tick & 1) == 0) {
            var minx: i32 = std.math.maxInt(i32);
            var maxx: i32 = std.math.minInt(i32);
            var miny: i32 = std.math.maxInt(i32);
            var maxy: i32 = std.math.minInt(i32);
            var minz: i32 = std.math.maxInt(i32);
            var maxz: i32 = std.math.minInt(i32);
            for (f.cells[0..f.n]) |cell| {
                minx = @min(minx, cell.x);
                maxx = @max(maxx, cell.x);
                miny = @min(miny, cell.y);
                maxy = @max(maxy, cell.y);
                minz = @min(minz, cell.z);
                maxz = @max(maxz, cell.z);
            }
            const faller_y = w.transform[s].y;
            const b_bot: f32 = @as(f32, @floatFromInt(miny)) - 0.5;
            const b_top: f32 = @as(f32, @floatFromInt(maxy)) + 0.2;
            // Bounds mirror stock ExpandBounds(box, 0, 0.2, 0) around the
            // carried cells; the victim's box [feet, head] must overlap.
            for (kinds, head_y) |kind, hh| {
                for (w.kind_groups.slice(kind)) |t| {
                    if (!w.alive[t] or !w.mask[t].transform or !w.mask[t].network_id) continue;
                    const tp = w.transform[t];
                    const vx = tp.x;
                    const vy = tp.y;
                    const vz = tp.z;
                    if (vx < @as(f32, @floatFromInt(minx)) - 0.5 or vx > @as(f32, @floatFromInt(maxx)) + 0.5) continue;
                    if (vz < @as(f32, @floatFromInt(minz)) - 0.5 or vz > @as(f32, @floatFromInt(maxz)) + 0.5) continue;
                    if (vy + hh < b_bot or vy > b_top) continue;
                    // Skip when the faller has sunk below the target's head.
                    if (faller_y < vy + hh) continue;
                    const nid = w.network_id[t].id;
                    if (hitCount(f, nid) >= c.falling_hit_cap) continue;
                    // FastMin(massKg * |vy| * 0.05, 40), int-truncated like
                    // the stock conv.i4; players reduce it by armor
                    // mitigation (passive 164 is the armor reduction path).
                    const raw: f32 = @min(f.mass_kg * -f.vy * 0.05, 40.0);
                    var dmg: f32 = @floatFromInt(@as(i32, @trunc(raw)));
                    if (kind == .player) {
                        // GeneralDamageResist covers every damage type (stock
                        // EntityAlive::DamageEntity), so it joins the crush
                        // before the armor leg.
                        dmg *= 1.0 - inventory.generalDamageResist(w, t);
                        // peer_slot is i32 and defaults to -1 for a player
                        // entity with no attached peer; @intCast traps on it.
                        const ps = w.player[t].peer_slot;
                        if (ps >= 0) {
                            const mit = inventory.armorMitigation(w, @intCast(ps));
                            dmg *= 1.0 - mit;
                        }
                    }
                    if (dmg <= 0) continue;
                    const dr = w.damageFrom(nid, dmg, -1);
                    _ = dr;
                    recordHit(f, nid);
                }
            }
        }
        // Lowest cell decides contact: when the cell directly below any cell
        // is solid, the group has landed.
        var landed = false;
        for (f.cells[0..f.n]) |cell| {
            if (solid_fn(w.solid_ctx, cell.x, cell.y - 1, cell.z)) {
                landed = true;
                break;
            }
        }
        if (landed) {
            // Fall-event debris drops (RE EntityFallingBlock landing
            // DropItemsOnEvent IL): the Game rolls each carried cell's
            // `<drop event="Fall">` rows at the landing position before the
            // entity is destroyed.
            if (w.fall_land_fn) |hook| hook(w.fall_land_ctx, f.cells[0..f.n]);
            w.destroy(s);
            continue;
        }
        f.vy = (f.vy + g * dt) * 0.98;
        f.vy = @max(f.vy, w.rules.ai.fall_max_vy);
        const t = &w.transform[s];
        const dy: f32 = f.vy * dt;
        t.y += dy;
        t.x += f.vx * dt;
        t.z += f.vz * dt;
        // The carried cells ride the entity: keep them in sync so the next
        // tick's land probe reads the updated heights. A singular block's
        // cell is the floor of its transform (the spawn dy0 offset must not
        // leak into the fall pace); a group's cells each move by the entity
        // delta from their own positions.
        if (f.n == 1) {
            f.cells[0].x = @floor(t.x);
            f.cells[0].y = @floor(t.y);
            f.cells[0].z = @floor(t.z);
        } else {
            for (f.cells[0..f.n]) |*cell| {
                cell.x = @floor(@as(f32, @floatFromInt(cell.x)) + f.vx * dt);
                cell.z = @floor(@as(f32, @floatFromInt(cell.z)) + f.vz * dt);
                cell.y = @floor(@as(f32, @floatFromInt(cell.y)) + dy);
            }
        }
    }
}

/// Stock entityHits lookup (capped at falling_hit_cap per entity).
fn hitCount(f: *const c.FallingBlocks, nid: i32) u8 {
    var i: usize = 0;
    while (i < f.hit_n) : (i += 1) {
        if (f.hit_ids[i] == nid) return f.hit_counts[i];
    }
    return 0;
}

/// Record a crush hit; evict the oldest entry when the fixed table is full.
fn recordHit(f: *c.FallingBlocks, nid: i32) void {
    var i: usize = 0;
    while (i < f.hit_n) : (i += 1) {
        if (f.hit_ids[i] == nid) {
            f.hit_counts[i] +%= 1;
            return;
        }
    }
    if (f.hit_n < c.falling_hits_tracked) {
        f.hit_ids[f.hit_n] = nid;
        f.hit_counts[f.hit_n] = 1;
        f.hit_n += 1;
    } else {
        // Table full: drop the oldest so a new victim can still be counted.
        std.mem.copyForwards(i32, f.hit_ids[0 .. f.hit_n - 1], f.hit_ids[1..f.hit_n]);
        std.mem.copyForwards(u8, f.hit_counts[0 .. f.hit_n - 1], f.hit_counts[1..f.hit_n]);
        f.hit_ids[f.hit_n - 1] = nid;
        f.hit_counts[f.hit_n - 1] = 1;
    }
}
