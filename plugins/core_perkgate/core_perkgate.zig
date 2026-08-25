// core_perkgate - a perk-spend policy plugin (AGENTS.md rule 29, Wasm-first;
// ADR 0033). Reference module for the on_perk_spend verdict: denies perks
// named `forbidden_*` and logs every spend. The stat deltas stay native (the
// passive-effects VM); this only gates/customizes spending.
//
// Build (zig): see mods/BUILDING.md. Committed as core_perkgate.wasm.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};

export fn on_enable() void {
    out.reset();
    out.put("core_perkgate v1.0 enabled (deny perks named forbidden_*)");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_perkgate shutdown");
    out.logLine(1);
}

export fn on_perk_spend(player: i32, name_ptr: i32, name_len: i32, level: i32, cost: i32) i32 {
    const name: [*]const u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    const n: usize = @intCast(@max(0, name_len));
    const forb = std.mem.startsWith(u8, name[0..n], "forbidden_");
    out.reset();
    out.put("perk spend: player=");
    out.putInt(player);
    out.put(" level=");
    out.putInt(level);
    out.put(" cost=");
    out.putInt(cost);
    out.put(" perk=");
    out.put(name[0..@min(n, common.out_cap)]);
    if (forb) {
        out.put(" DENIED");
        out.logLine(1);
        return -1; // deny the spend
    }
    out.logLine(1);
    return 0; // keep everything else
}
