// core_damagegate — incoming-player-damage scaling via the on_player_damage
// verdict (AGENTS.md rule 29, Wasm-first). The verdict is wired in the C2S
// melee path (c2s/misc.zig), the ECS zombie-melee path (applyDeferredDamage
// via World.player_damage_verdict_fn), the survival tick (drowning, radiation,
// starvation, game/tick.zig) and the explosion path (c2s/blocks.zig), so a
// module shapes ALL damage directed at players without touching the sim
// directly.
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_player_damage(attacker: i32, victim: i32, amount: i32) -> i32
//     <0  deny the hit entirely (victim keeps hp)
//      0  keep stock damage
//     >0  apply that percent of the damage (50 = half)
//
// Default policy: 50 (half incoming player damage). attacker == -1 means the
// attacker is unknown or environmental (zombie melee via the ECS deferred
// path, drowning, radiation, starvation) — those are scaled too.
//
// Build (zig): see mods/BUILDING.md. Committed as core_damagegate.wasm.

const common = @import("plugin_common");

var out: common.Buf = .{};

export fn on_enable() void {
    out.reset();
    out.put("core_damagegate v1.0 enabled (0.5x incoming player damage)");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_damagegate shutdown");
    out.logLine(0);
}

export fn on_player_damage(attacker: i32, victim: i32, amount: i32) i32 {
    _ = attacker;
    _ = victim;
    _ = amount;
    return 50; // half incoming player damage
}
