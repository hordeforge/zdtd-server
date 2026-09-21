//! Dig system: zombie block-chew cadence pushing DigRequests.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const query = @import("query.zig");


/// MoveHelper dig cadence (RE entity-ai.md DigUpdate IL=261): each digging AI
/// counts windup/attack ticks and pushes a DigRequest every `dig_windup_ticks`
/// (stock fires the attack after the 18-tick windup, then every 4+14 = 18);
/// the budget runs down to DigStop. A dug block that is already gone ends the
/// dig so the zombie walks on. Both values are `rules.ai` (dig_windup_ticks /
/// dig_budget_ticks) so a mode can pace zombie block-chew.
pub fn systemDigUpdate(w: *World) void {
    const solid_fn = w.solid_fn;
    for (query.groupSlice(w, .zombie)) |s| {
        if (!w.alive[s] or !w.mask[s].zombie_ai) continue;
        const ai = &w.zombie_ai[s];
        if (!ai.digging) continue;
        if (ai.dig_for_ticks == 0) {
            ai.digging = false;
            continue;
        }
        if (solid_fn) |sf| {
            if (!sf(w.solid_ctx, ai.dig_x, ai.dig_y, ai.dig_z)) {
                ai.digging = false;
                continue;
            }
        }
        ai.dig_for_ticks -= 1;
        ai.dig_ticks +%= 1;
        if (ai.dig_ticks >= w.rules.ai.dig_windup_ticks) {
            ai.dig_ticks = 0;
            w.pushDig(s, ai.dig_x, ai.dig_y, ai.dig_z);
        }
    }
}
