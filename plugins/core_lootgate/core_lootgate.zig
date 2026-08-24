// core_lootgate — a loot-roll policy plugin (AGENTS.md rule 29, Wasm-first).
// Reference module for the on_loot_roll verdict: it scales every rolled loot
// stack count to 50% (a "half loot" server policy) and logs each roll. The
// policy is the module: enable it via [plugin] modules, no native code.
//
// Verdict semantics: <0 empty the roll, 0 keep, >0 scale the rolled stack
// count by percent. This module returns 50 for every loot list.
//
// Build (zig): see mods/BUILDING.md. Committed as core_lootgate.wasm.

const common = @import("plugin_common");

var out: common.Buf = .{};

export fn on_enable() void {
    out.reset();
    out.put("core_lootgate v1.0 enabled (loot scaled to 50%)");
    out.logLine(1);
}

export fn on_shutdown() void {
    out.reset();
    out.put("core_lootgate shutdown");
    out.logLine(1);
}

export fn on_loot_roll(list_ptr: i32, list_len: i32, rolled: i32) i32 {
    const list: [*]const u8 = @ptrFromInt(@as(usize, @intCast(list_ptr)));
    const n: usize = @intCast(@max(0, list_len));
    out.reset();
    out.put("loot roll: list=");
    out.put(list[0..@min(n, common.out_cap)]);
    out.put(" rolled=");
    out.putInt(rolled);
    out.put(" -> 50%");
    out.logLine(1);
    return 50; // scale every roll to 50%
}

comptime {
    // Declarative dependency check (paper: reactive coeffects): the host
    // rejects the module at load if any listed capability is missing.
    common.exportRequires("on_loot_roll,log");
}
