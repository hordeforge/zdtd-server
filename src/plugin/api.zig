//! Static plugin hook types for in-tree test scaffolding only (ADR 0020).
//! Product plugins are Wasm modules (`wasm.zig`); this table is not a shipping
//! native ABI. No dynlib, no stock IModApi.

const std = @import("std");
const util_log = @import("../util/log.zig");

/// zdtd plugin API version (ADR 0020; engineering).
pub const plugin_api_version: u32 = 1;

pub const LogLevel = enum(u8) {
    debug,
    info,
    warn,
    err,
};

/// Narrow host view passed into hooks. No raw `*Game`.
pub const Host = struct {
    version: u32 = plugin_api_version,
    tick: u64 = 0,
    log_fn: *const fn (LogLevel, []const u8) void = defaultLog,

    pub fn log(self: Host, level: LogLevel, msg: []const u8) void {
        self.log_fn(level, msg);
    }
};

fn defaultLog(level: LogLevel, msg: []const u8) void {
    const tag: []const u8 = switch (level) {
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "err",
    };
    // debug/info are boot chatter (`sample_hello enabled`); warn/err must
    // survive `--quiet` like every other server warning.
    switch (level) {
        .debug, .info => util_log.info("zdtd plugin [{s}]: {s}\n", .{ tag, msg }),
        .warn, .err => std.debug.print("zdtd plugin [{s}]: {s}\n", .{ tag, msg }),
    }
}

/// Static plugin vtable. Null hooks are skipped (zero cost beyond a null check).
/// Event hooks follow the Wasm verdict convention (see wasm.zig): a return
/// below 0 denies the outcome, 0 keeps behaviour, above 0 adjusts as a percent.
pub const PluginVTable = struct {
    name: []const u8,
    on_enable: ?*const fn (*const Host) void = null,
    on_tick: ?*const fn (*const Host) void = null,
    on_player_join: ?*const fn (*const Host, peer_slot: u16, entity_id: i32) void = null,
    on_player_leave: ?*const fn (*const Host, peer_slot: u16, entity_id: i32) void = null,
    /// Trader event observer (kind 0 open / 1 buy / 2 sell). Announcements
    /// react through a plugin; the trade has already executed.
    on_trader_event: ?*const fn (*const Host, player: i32, trader_entity: i32, kind: i32) void = null,
    /// Player stat observer (on_stat_changed, ADR 0034): fired once per
    /// player per tick when the survival/effects pass changed any tracked
    /// stat (hp/food/water/stamina) and on XP awards (level/XP). Pure
    /// observer - the sim stays the authority; plugins react/announce.
    on_stat_changed: ?*const fn (*const Host, player: i32, hp: i32, food: i32, water: i32, stamina: i32, level: i32, xp: i32) void = null,
    /// Evidence observer (on_evidence, T21): the guard's evidence-ring event,
    /// streamed read-only (floats as f32 bits, severity post-ceiling). Never
    /// a gate: the host already applied the T20 severity ceiling and the
    /// return is discarded.
    on_evidence: ?*const fn (*const Host, tick: i32, peer_local: i32, entity_id: i32, detector: i32, severity: i32, surface: i32, observed_bits: i32, bound_bits: i32) void = null,
    on_shutdown: ?*const fn (*const Host) void = null,
    on_player_death: ?*const fn (*const Host, victim: i32) i32 = null,
    on_entity_killed: ?*const fn (*const Host, killed: i32, killer: i32) i32 = null,
    on_player_damage: ?*const fn (*const Host, attacker: i32, victim: i32, amount: i32) i32 = null,
    on_quest_accept: ?*const fn (*const Host, player: i32, def_id: i32) i32 = null,
    on_craft_request: ?*const fn (*const Host, player: i32, recipe_name: []const u8, times: i32) i32 = null,
    on_loot_roll: ?*const fn (*const Host, list_name: []const u8, rolled: i32) i32 = null,
    on_block_damage: ?*const fn (*const Host, x: i32, y: i32, z: i32, dmg: i32) i32 = null,
    on_quest_complete: ?*const fn (*const Host, player: i32, quest_def: i32) i32 = null,
    /// Pre-trade price verdict (on_trade_price): <0 deny, 0 keep, >0 percent.
    on_trade_price: ?*const fn (*const Host, player: i32, item: i32, unit_price: i32) i32 = null,
    /// Pre-purchase perk verdict (on_perk_spend, ADR 0033): <0 denies the
    /// spend, 0 keeps, >0 scales the skill-point cost by percent. The stat
    /// deltas stay native (the passive-effects VM); this gates/customizes
    /// spending only.
    on_perk_spend: ?*const fn (*const Host, player: i32, skill: []const u8, level: i32, cost: i32) i32 = null,
    /// Pre-fire GameEvent verdict (on_game_event, ADR 0035): <0 denies the
    /// event (no response), 0 keeps the stock APPROVED ack, >0 keeps it too
    /// (first non-keep wins). `var_count` is the request's variables count.
    on_game_event: ?*const fn (*const Host, player: i32, event: []const u8, target: i32, var_count: i32) i32 = null,
    /// Admin command hook: receives the full console line (verb + args), writes
    /// a reply into `out` and returns the written slice. Null return means not
    /// handled — the next plugin is tried, then core reports unknown.
    on_admin_command: ?*const fn (*const Host, cmd: []const u8, out: []u8) ?[]const u8 = null,
    /// Chat hook: after core validation (rate limit, UTF-8), before broadcast.
    /// Return null to let core broadcast as-is, a slice of `out` to replace the
    /// message (validate again), or an empty slice "" to suppress it. Plugins
    /// must not bypass the stock wire — only the chat body is filtered.
    /// `sender` is the authenticated entity id.
    on_chat: ?*const fn (*const Host, sender: i32, msg: []const u8, out: []u8) ?[]const u8 = null,
    /// Join gate: after PlayerLogin name sanitized, before ban/whitelist and
    /// spawn. Return null to allow, a slice of `out` as the deny reason to
    /// reject (first non-null wins). Plugins cannot forge identity.
    on_player_login: ?*const fn (*const Host, peer_slot: u16, name: []const u8, out: []u8) ?[]const u8 = null,
};

test "host log dispatches level and message to log_fn" {
    const Cap = struct {
        var level: ?LogLevel = null;
        var msg: ?[]const u8 = null;
        fn capture(l: LogLevel, m: []const u8) void {
            level = l;
            msg = m;
        }
    };
    Cap.level = null;
    Cap.msg = null;
    var h: Host = .{ .log_fn = Cap.capture };
    try std.testing.expectEqual(@as(u32, plugin_api_version), h.version);
    h.log(.warn, "ping");
    try std.testing.expectEqual(LogLevel.warn, Cap.level.?);
    try std.testing.expectEqualStrings("ping", Cap.msg.?);
}
