//! Static plugin host: fixed table, ordered enable/tick/join/shutdown.
//! No dynlib, no Wasm, no heap on the tick path.

const std = @import("std");
const api = @import("api.zig");
const sample_hello = @import("sample_hello.zig");

pub const max_plugins: usize = 8;

pub const PluginHost = struct {
    slots: [max_plugins]*const api.PluginVTable = undefined,
    n: usize = 0,
    enabled: [max_plugins]bool = .{false} ** max_plugins,
    view: api.Host = .{},
    /// When true, register in-tree sample_hello at enableStaticDefaults.
    sample_enabled: bool = true,

    pub fn register(self: *PluginHost, plugin: *const api.PluginVTable) bool {
        if (self.n >= max_plugins) return false;
        // Reject duplicate name (same pointer or same name string).
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.slots[i] == plugin) return false;
            if (std.mem.eql(u8, self.slots[i].name, plugin.name)) return false;
        }
        self.slots[self.n] = plugin;
        self.enabled[self.n] = false;
        self.n += 1;
        return true;
    }

    /// Register built-in static samples (Debug-friendly, zero cost when hooks null).
    pub fn enableStaticDefaults(self: *PluginHost) void {
        if (self.sample_enabled) {
            _ = self.register(&sample_hello.vtable);
        }
        self.enableAll();
    }

    pub fn enableAll(self: *PluginHost) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.enabled[i]) continue;
            self.enabled[i] = true;
            if (self.slots[i].on_enable) |f| f(&self.view);
        }
    }

    pub fn setTick(self: *PluginHost, tick_n: u64) void {
        self.view.tick = tick_n;
    }

    /// Call on_tick for enabled plugins. Null hooks skip (branch only).
    pub fn onTick(self: *PluginHost) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_tick) |f| f(&self.view);
        }
    }

    pub fn playerJoin(self: *PluginHost, peer_slot: u16, entity_id: i32) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_player_join) |f| f(&self.view, peer_slot, entity_id);
        }
    }

    pub fn playerLeave(self: *PluginHost, peer_slot: u16, entity_id: i32) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_player_leave) |f| f(&self.view, peer_slot, entity_id);
        }
    }

    /// Player stat observer (ADR 0034): fired when the survival pass changed
    /// a tracked stat or an XP award landed. Pure observer, void.
    pub fn statChanged(self: *PluginHost, player: i32, hp: i32, food: i32, water: i32, stamina: i32, level: i32, xp: i32) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_stat_changed) |f| f(&self.view, player, hp, food, water, stamina, level, xp);
        }
    }

    pub fn traderEvent(self: *PluginHost, player: i32, trader_entity: i32, kind: i32) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_trader_event) |f| f(&self.view, player, trader_entity, kind);
        }
    }

    /// Event-hook verdicts (T15): first non-zero return across enabled
    /// plugins. 0 keeps today's behaviour; a null hook is skipped.
    pub fn playerDeath(self: *PluginHost, victim: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_player_death) |f| {
                const v = f(&self.view, victim);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    pub fn entityKilled(self: *PluginHost, killed: i32, killer: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_entity_killed) |f| {
                const v = f(&self.view, killed, killer);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    pub fn playerDamage(self: *PluginHost, attacker: i32, victim: i32, amount: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_player_damage) |f| {
                const v = f(&self.view, attacker, victim, amount);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    /// Pre-purchase perk verdict (on_perk_spend, ADR 0033): <0 deny, 0 keep,
    /// >0 scales the skill-point cost by percent.
    pub fn perkSpend(self: *PluginHost, player: i32, skill: []const u8, level: i32, cost: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_perk_spend) |f| {
                const v = f(&self.view, player, skill, level, cost);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    /// Pre-trade price verdict (on_trade_price): <0 deny, 0 keep, >0 percent.
    pub fn tradePrice(self: *PluginHost, player: i32, item: i32, unit_price: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_trade_price) |f| {
                const v = f(&self.view, player, item, unit_price);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    pub fn questAccept(self: *PluginHost, player: i32, def_id: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_quest_accept) |f| {
                const v = f(&self.view, player, def_id);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    pub fn craftRequest(self: *PluginHost, player: i32, recipe_name: []const u8, times: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_craft_request) |f| {
                const v = f(&self.view, player, recipe_name, times);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    pub fn lootRoll(self: *PluginHost, list_name: []const u8, rolled: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_loot_roll) |f| {
                const v = f(&self.view, list_name, rolled);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    pub fn blockDamage(self: *PluginHost, x: i32, y: i32, z: i32, dmg: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_block_damage) |f| {
                const v = f(&self.view, x, y, z, dmg);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    pub fn questComplete(self: *PluginHost, player: i32, quest_def: i32) i32 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_quest_complete) |f| {
                const v = f(&self.view, player, quest_def);
                if (v != 0) return v;
            }
        }
        return 0;
    }

    /// Join gate: first plugin that denies wins.
    pub fn playerLoginDeny(self: *PluginHost, peer_slot: u16, name: []const u8, out: []u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_player_login) |f| {
                if (f(&self.view, peer_slot, name, out)) |reason| return reason;
            }
        }
        return null;
    }

    /// Chat hook: first plugin that rewrites or suppresses wins. The handler
    /// writes the filtered message into `out` and returns it; null means keep
    /// the original, "" means suppress. Validate after — a bad rewrite is
    /// treated as suppress.
    pub fn chatFilter(self: *PluginHost, sender: i32, msg: []const u8, out: []u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_chat) |f| {
                if (f(&self.view, sender, msg, out)) |filtered| return filtered;
            }
        }
        return null;
    }

    /// Admin command hook: first plugin that handles the verb wins. The
    /// handler writes its reply into `out` and returns the written slice; a
    /// null return means not handled.
    pub fn adminCommand(self: *PluginHost, cmd: []const u8, out: []u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_admin_command) |f| {
                if (f(&self.view, cmd, out)) |reply| return reply;
            }
        }
        return null;
    }

    pub fn shutdown(self: *PluginHost) void {
        var i: usize = self.n;
        while (i > 0) {
            i -= 1;
            if (!self.enabled[i]) continue;
            if (self.slots[i].on_shutdown) |f| f(&self.view);
            self.enabled[i] = false;
        }
    }

    pub fn count(self: *const PluginHost) usize {
        return self.n;
    }

    pub fn enabledCount(self: *const PluginHost) usize {
        var c: usize = 0;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.enabled[i]) c += 1;
        }
        return c;
    }
};

test "host registers sample and enables once" {
    sample_hello.resetForTest();
    var h: PluginHost = .{};
    h.enableStaticDefaults();
    try std.testing.expectEqual(@as(usize, 1), h.count());
    try std.testing.expectEqual(@as(usize, 1), h.enabledCount());
    // Second enableAll is a no-op for already-enabled slots.
    h.enableAll();
    try std.testing.expectEqual(@as(usize, 1), h.enabledCount());
    h.setTick(42);
    h.onTick(); // sample has null on_tick
    h.playerJoin(0, 100); // sample has null on_player_join
    h.shutdown();
    try std.testing.expectEqual(@as(usize, 0), h.enabledCount());
}

test "host rejects duplicate and caps" {
    var h: PluginHost = .{ .sample_enabled = false };
    const p: api.PluginVTable = .{ .name = "a" };
    try std.testing.expect(h.register(&p));
    try std.testing.expect(!h.register(&p));
    // Fill remaining with distinct static names (max_plugins - 1 more).
    const names = [_][]const u8{ "b", "c", "d", "e", "f", "g", "h" };
    try std.testing.expectEqual(max_plugins - 1, names.len);
    var extras: [names.len]api.PluginVTable = undefined;
    for (&extras, names) |*slot, n| {
        slot.* = .{ .name = n };
        try std.testing.expect(h.register(slot));
    }
    const overflow: api.PluginVTable = .{ .name = "overflow" };
    try std.testing.expect(!h.register(&overflow));
    try std.testing.expectEqual(max_plugins, h.count());
}

test "host chat filter hook first handler wins and suppress" {
    var h: PluginHost = .{ .sample_enabled = false };
    const p1: api.PluginVTable = .{
        .name = "c1",
        .on_chat = &struct {
            fn f(_: *const api.Host, _: i32, msg: []const u8, _: []u8) ?[]const u8 {
                if (std.mem.find(u8, msg, "bad") != null) return "";
                return null;
            }
        }.f,
    };
    const p2: api.PluginVTable = .{
        .name = "c2",
        .on_chat = &struct {
            fn f(_: *const api.Host, _: i32, msg: []const u8, out: []u8) ?[]const u8 {
                const s = "hi";
                _ = msg;
                @memcpy(out[0..s.len], s);
                return out[0..s.len];
            }
        }.f,
    };
    try std.testing.expect(h.register(&p1));
    try std.testing.expect(h.register(&p2));
    h.enableAll();
    var out: [64]u8 = undefined;
    // "hello" reaches p2 (p1 only blocks "bad") -> rewritten to "hi".
    try std.testing.expectEqualStrings("hi", h.chatFilter(1, "hello", &out).?);
    try std.testing.expectEqualStrings("", h.chatFilter(1, "bad word", &out).?);
    // c2 rewrites but only reached when c1 passes.
    try std.testing.expectEqualStrings("hi", h.chatFilter(1, "ok", &out).?);
}

test "host admin command hook first handler wins" {
    var h: PluginHost = .{ .sample_enabled = false };
    const p1: api.PluginVTable = .{
        .name = "p1",
        .on_admin_command = &struct {
            fn f(_: *const api.Host, cmd: []const u8, out: []u8) ?[]const u8 {
                if (!std.mem.startsWith(u8, cmd, "ping")) return null;
                const s = "pong\n";
                @memcpy(out[0..s.len], s);
                return out[0..s.len];
            }
        }.f,
    };
    const p2: api.PluginVTable = .{
        .name = "p2",
        .on_admin_command = &struct {
            fn f(_: *const api.Host, _: []const u8, out: []u8) ?[]const u8 {
                const s = "p2\n";
                @memcpy(out[0..s.len], s);
                return out[0..s.len];
            }
        }.f,
    };
    try std.testing.expect(h.register(&p1));
    try std.testing.expect(h.register(&p2));
    h.enableAll();
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("pong\n", h.adminCommand("ping", &out).?);
    // p1 does not handle "other", so p2 wins.
    try std.testing.expectEqualStrings("p2\n", h.adminCommand("other", &out).?);
}

test "host perkSpend verdict: deny, keep, and percent-scale first-wins" {
    var h: PluginHost = .{ .sample_enabled = false };
    // Static lifetime: PluginHost keeps the vtable pointer.
    const gate = api.PluginVTable{
        .name = "perkgate",
        .on_perk_spend = struct {
            fn f(_: *const api.Host, player: i32, skill: []const u8, level: i32, cost: i32) i32 {
                if (std.mem.eql(u8, skill, "perkForbidden")) return -1; // deny
                if (std.mem.eql(u8, skill, "perkCostly")) return 150; // scale cost x1.5
                _ = player;
                _ = level;
                _ = cost;
                return 0; // keep everything else
            }
        }.f,
    };
    try std.testing.expect(h.register(&gate));
    h.enableAll();
    try std.testing.expectEqual(@as(i32, -1), h.perkSpend(1, "perkForbidden", 1, 1));
    try std.testing.expectEqual(@as(i32, 150), h.perkSpend(1, "perkCostly", 2, 1));
    try std.testing.expectEqual(@as(i32, 0), h.perkSpend(1, "perkFine", 1, 1));
    h.shutdown();
}

// Test capture (module scope: the nested vtable fn cannot close over locals).
var stat_last: [7]i32 = .{0} ** 7;

test "host stat-changed observer fires with the player snapshot" {
    var h: PluginHost = .{ .sample_enabled = false };
    stat_last = .{0} ** 7;
    const obs = api.PluginVTable{
        .name = "statobs",
        .on_stat_changed = struct {
            fn f(_: *const api.Host, player: i32, hp: i32, food: i32, water: i32, stamina: i32, level: i32, xp: i32) void {
                stat_last = .{ player, hp, food, water, stamina, level, xp };
            }
        }.f,
    };
    try std.testing.expect(h.register(&obs));
    h.enableAll();
    h.statChanged(100, 50, 40, 30, 20, 5, 12345);
    try std.testing.expectEqual(@as(i32, 100), stat_last[0]);
    try std.testing.expectEqual(@as(i32, 50), stat_last[1]);
    try std.testing.expectEqual(@as(i32, 40), stat_last[2]);
    try std.testing.expectEqual(@as(i32, 5), stat_last[5]);
    h.shutdown();
}
