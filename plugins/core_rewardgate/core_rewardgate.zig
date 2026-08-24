// core_rewardgate — quest-reward scaling via the on_quest_complete verdict
// (AGENTS.md rule 29, Wasm-first).
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_quest_complete(player: i32, quest_def: i32) -> i32
//     <0  withhold the payout; >0 pay that percent of items/exp/coins (150 = 1.5x)
//
// Default policy: 150 (1.5x rewards on every quest). Specialize per quest_def
// for per-quest rules.
//
// Build (zig): see mods/BUILDING.md. Committed as core_rewardgate.wasm.

const common = @import("plugin_common");

var out: common.Buf = .{};

export fn on_enable() void {
    out.reset();
    out.put("core_rewardgate v1.0 enabled (1.5x quest rewards)");
    out.logLine(0);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_rewardgate shutdown");
    out.logLine(0);
}

export fn on_quest_complete(player: i32, quest_def: i32) i32 {
    _ = player;
    _ = quest_def;
    return 150; // 1.5x rewards on every quest
}
