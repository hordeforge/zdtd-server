//! Buff tick system: expiry sweep over every buff set.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const World = @import("world.zig").World;
const c = @import("components.zig");
const buff = @import("buff.zig");
const Slot = @import("world.zig").Slot;

/// Tick every buff set in the world. Stock ticks buffs on every entity the
/// client simulates (EntityAlive::OnUpdateEntity, asm.il 445737), so the server
/// must run the same rule on every entity it owns or the two drift.
/// Returns the number of removals written into `out` (saturating).
pub fn systemBuffs(w: *World, out: []buff.Expiry) u8 {
    var n: u8 = 0;
    var removed: [c.max_buffs_per_entity]buff.Removed = undefined;
    var it = w.alive_bits.iterator(.{});
    while (it.next()) |idx| {
        const i: Slot = @intCast(idx);
        if (!w.mask[i].buffs) continue;
        // Entity::bDead skips the started/duration half of the tick (asm.il 735832).
        const dead = w.mask[i].health and w.health[i].hp <= 0;
        const rn = buff.tick(&w.buffs[i], dead, &removed);
        var r: u8 = 0;
        while (r < rn and n < out.len) : (r += 1) {
            out[n] = .{ .entity_id = w.network_id[i].id, .def_id = removed[r].def_id };
            n += 1;
        }
    }
    return n;
}
