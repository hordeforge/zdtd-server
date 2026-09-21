//! Dual-host plugin composition: static `PluginHost` first, then `WasmHost`.
//!
//! One place for the ordering rule used across join/tick/C2S/sim hooks:
//! - Verdict (`i32`): first non-zero wins (native gate, else Wasm). Wasm is
//!   not called when the static host already returned a verdict.
//! - Observer (`void`): fire both hosts.
//! - Optional rewrite / deny (`?[]const u8`): first hit wins.
//!
//! Call sites must not open-code `plugins.X` then `wasm_plugins.X`; that
//! duplicated the composition policy across ~20 files. The static host is
//! test scaffolding (ADR 0020); product path is Wasm-only when no static
//! plugins are registered.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;

pub fn playerDamage(g: *Game, attacker: i32, victim: i32, amount: i32) i32 {
    const sv = g.plugins.playerDamage(attacker, victim, amount);
    if (sv != 0) return sv;
    return g.wasm_plugins.playerDamage(attacker, victim, amount);
}

pub fn blockDamage(g: *Game, x: i32, y: i32, z: i32, dmg: i32) i32 {
    const sv = g.plugins.blockDamage(x, y, z, dmg);
    if (sv != 0) return sv;
    return g.wasm_plugins.blockDamage(x, y, z, dmg);
}

pub fn tradePrice(g: *Game, player: i32, item: i32, unit_price: i32) i32 {
    const sv = g.plugins.tradePrice(player, item, unit_price);
    if (sv != 0) return sv;
    return g.wasm_plugins.tradePrice(player, item, unit_price);
}

pub fn perkSpend(g: *Game, player: i32, skill: []const u8, level: i32, cost: i32) i32 {
    const sv = g.plugins.perkSpend(player, skill, level, cost);
    if (sv != 0) return sv;
    return g.wasm_plugins.perkSpend(player, skill, level, cost);
}

pub fn gameEvent(g: *Game, player: i32, event: []const u8, target: i32, var_count: i32) i32 {
    const sv = g.plugins.gameEvent(player, event, target, var_count);
    if (sv != 0) return sv;
    return g.wasm_plugins.gameEvent(player, event, target, var_count);
}

pub fn craftRequest(g: *Game, player: i32, recipe_name: []const u8, times: i32) i32 {
    const sv = g.plugins.craftRequest(player, recipe_name, times);
    if (sv != 0) return sv;
    return g.wasm_plugins.craftRequest(player, recipe_name, times);
}

pub fn lootRoll(g: *Game, list_name: []const u8, rolled: i32) i32 {
    const sv = g.plugins.lootRoll(list_name, rolled);
    if (sv != 0) return sv;
    return g.wasm_plugins.lootRoll(list_name, rolled);
}

pub fn questAccept(g: *Game, player: i32, def_id: i32) i32 {
    const sv = g.plugins.questAccept(player, def_id);
    if (sv != 0) return sv;
    return g.wasm_plugins.questAccept(player, def_id);
}

pub fn questComplete(g: *Game, player: i32, quest_def: i32) i32 {
    const sv = g.plugins.questComplete(player, quest_def);
    if (sv != 0) return sv;
    return g.wasm_plugins.questComplete(player, quest_def);
}

pub fn playerDeath(g: *Game, victim: i32) i32 {
    const sv = g.plugins.playerDeath(victim);
    if (sv != 0) return sv;
    return g.wasm_plugins.playerDeath(victim);
}

pub fn entityKilled(g: *Game, killed: i32, killer: i32) i32 {
    const sv = g.plugins.entityKilled(killed, killer);
    if (sv != 0) return sv;
    return g.wasm_plugins.entityKilled(killed, killer);
}

pub fn playerJoin(g: *Game, peer_slot: u16, entity_id: i32) void {
    g.plugins.playerJoin(peer_slot, entity_id);
    g.wasm_plugins.playerJoin(peer_slot, entity_id);
}

pub fn playerLeave(g: *Game, peer_slot: u16, entity_id: i32) void {
    g.plugins.playerLeave(peer_slot, entity_id);
    g.wasm_plugins.playerLeave(peer_slot, entity_id);
}

pub fn traderEvent(g: *Game, player: i32, trader_entity: i32, kind: i32) void {
    g.plugins.traderEvent(player, trader_entity, kind);
    g.wasm_plugins.traderEvent(player, trader_entity, kind);
}

pub fn buff(g: *Game, entity: i32, name: []const u8, adding: bool) void {
    g.plugins.buff(entity, name, adding);
    g.wasm_plugins.buff(entity, name, adding);
}

pub fn statChanged(g: *Game, player: i32, hp: i32, food: i32, water: i32, stamina: i32, level: i32, xp: i32) void {
    g.plugins.statChanged(player, hp, food, water, stamina, level, xp);
    g.wasm_plugins.statChanged(player, hp, food, water, stamina, level, xp);
}

pub fn evidence(
    g: *Game,
    tick: i32,
    peer_local: i32,
    entity_id: i32,
    detector: i32,
    severity: i32,
    surface: i32,
    observed_bits: i32,
    bound_bits: i32,
) void {
    g.plugins.evidence(tick, peer_local, entity_id, detector, severity, surface, observed_bits, bound_bits);
    g.wasm_plugins.evidence(tick, peer_local, entity_id, detector, severity, surface, observed_bits, bound_bits);
}

pub fn onTick(g: *Game) void {
    g.plugins.onTick();
    g.wasm_plugins.onTick();
}

pub fn shutdown(g: *Game) void {
    g.plugins.shutdown();
    g.wasm_plugins.shutdown();
}

/// First deny wins (static then Wasm). Returns the deny reason, or null to allow.
pub fn playerLoginDeny(g: *Game, peer_slot: u16, name: []const u8, out: []u8) ?[]const u8 {
    if (g.plugins.playerLoginDeny(peer_slot, name, out)) |reason| return reason;
    return g.wasm_plugins.playerLoginDeny(peer_slot, name, out);
}

/// First rewrite wins. Empty rewrite means drop. Null means neither host rewrote.
pub fn chatFilter(g: *Game, sender: i32, msg: []const u8, native_buf: []u8, wasm_buf: []u8) ?[]const u8 {
    if (g.plugins.chatFilter(sender, msg, native_buf)) |f| return f;
    if (g.wasm_plugins.chatFilter(sender, msg, wasm_buf)) |f| return f;
    return null;
}

/// First admin command handler wins.
pub fn adminCommand(g: *Game, cmd: []const u8, out: []u8) ?[]const u8 {
    if (g.plugins.adminCommand(cmd, out)) |reply| return reply;
    return g.wasm_plugins.adminCommand(cmd, out);
}
