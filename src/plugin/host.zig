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
