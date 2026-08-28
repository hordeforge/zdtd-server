//! Mod resolution (PRD 0005 / RFC 0005): turn discovered `mod.toml` manifests
//! plus `[mods] disabled` / `blacklist` / legacy `[plugin] modules` into the
//! final load list and the exclusive override-point claim table.
//! Runs once at boot (allocation allowed); the tick path only reads the
//! load-fixed `point_claims` table via WasmHost.

const std = @import("std");
const manifest = @import("manifest.zig");

pub const ResolverError = anyerror;

/// One resolved module in final load order.
pub const ResolvedModule = struct {
    /// Manifest values reference the caller-owned `discovered` list (except
    /// synthetic ones for legacy `[plugin] modules` paths).
    manifest: manifest.Manifest,
    tier: manifest.Tier,
    /// Mod name this module replaces (null for normal modules).
    replaces: ?[]const u8 = null,
    /// Final slot index (load order).
    slot: usize,
};

pub const ResolvedResult = struct {
    /// Load order: discovered mods (sorted by dir name) then legacy explicit
    /// modules. Replaced targets are dropped; replacers take their place.
    modules: []ResolvedModule,
    /// Override-point id -> module slot that exclusively claims it.
    point_claims: std.StringHashMapUnmanaged(usize),
    /// Mod name -> slot (for admin/ops).
    name_to_slot: std.StringHashMapUnmanaged(usize),
    /// Config-only mod: the mode pack (modes/<name>.toml) an enabled loaded
    /// mod activates (null when none). First in load order wins; a second is
    /// error.DuplicateMode. The explicit --mode / [mode] name still wins.
    mode_pack: ?[]const u8 = null,
    /// Synthetic manifests created for legacy [plugin] modules: none of their
    /// fields are owned here (strings point into caller-owned paths), so only
    /// the slice itself is freed.
    synthetic: []manifest.Manifest,

    pub fn deinit(self: *ResolvedResult, a: std.mem.Allocator) void {
        if (self.synthetic.len > 0) a.free(self.synthetic);
        a.free(self.modules);
        self.point_claims.deinit(a);
        self.name_to_slot.deinit(a);
    }
};

/// Resolve `discovered` (from `manifest.discover`) plus legacy explicit paths.
/// `disabled` and `blacklist` come from `[mods]` config (already split).
/// The caller owns `discovered` and frees it after use; the result's modules
/// reference the same manifest values.
pub fn resolve(
    a: std.mem.Allocator,
    discovered: []const manifest.Manifest,
    explicit_paths: []const []const u8,
    disabled: []const []const u8,
    blacklist: []const []const u8,
    enabled: []const []const u8,
) ResolverError!ResolvedResult {
    var disabled_set: std.StringHashMapUnmanaged(void) = .empty;
    defer disabled_set.deinit(a);
    for (disabled) |n| try disabled_set.put(a, n, {});
    var blacklist_set: std.StringHashMapUnmanaged(void) = .empty;
    defer blacklist_set.deinit(a);
    for (blacklist) |n| try blacklist_set.put(a, n, {});
    // `[mods] enabled`: force-load these discovered mods despite their
    // `enabled = false` manifest flag (config-only mods ship off by default
    // so a fresh boot stays stock; the operator opts in here).
    var enabled_set: std.StringHashMapUnmanaged(void) = .empty;
    defer enabled_set.deinit(a);
    for (enabled) |n| try enabled_set.put(a, n, {});

    // Core-component protection (R4/AC3): a disabled/blacklisted entry naming
    // a core component is a config error, fail-closed.
    for (disabled) |n| {
        for (manifest.core_components) |cc| {
            if (std.mem.eql(u8, n, cc)) return error.DisabledCore;
        }
    }
    for (blacklist) |n| {
        for (manifest.core_components) |cc| {
            if (std.mem.eql(u8, n, cc)) return error.DisabledCore;
        }
    }

    // Pass 0: name -> discovered index; core-component protection (R4) is
    // validated by the caller (config binder) against the core registry.
    var name_index: std.StringHashMapUnmanaged(usize) = .empty;
    defer name_index.deinit(a);
    for (discovered, 0..) |dm, i| try name_index.put(a, dm.name.?, i);

    // Collect mods that actually load: skip disabled, reject blacklisted,
    // resolve override edges (target dropped, replacer kept).
    var load = std.ArrayList(ResolvedModule).empty;
    defer load.deinit(a);
    var replaced: std.StringHashMapUnmanaged(void) = .empty;
    defer replaced.deinit(a);

    // First mark every override target as replaced (a target replaced twice is
    // a DuplicateClaim: two mods override the same mod).
    for (discovered) |m| {
        const t = m.override orelse continue;
        if (blacklist_set.contains(t)) return error.BlacklistedTarget;
        if (replaced.contains(t)) return error.DuplicateClaim;
        try replaced.put(a, t, {});
    }
    // Override target must exist among discovered or explicit paths; else the
    // replacer cannot load.
    for (discovered) |m| {
        const t = m.override orelse continue;
        if (!name_index.contains(t)) return error.UnknownOverrideTarget;
    }

    // A blacklisted name is also vetoed as a `requires` dependency (ADR 0032
    // decision 3): nothing that pulls in a blacklisted mod can load.
    for (discovered) |m| {
        const reqs = m.requires orelse continue;
        var rit = std.mem.splitScalar(u8, reqs, ',');
        while (rit.next()) |r_raw| {
            const r = std.mem.trim(u8, r_raw, " \t");
            if (r.len == 0) continue;
            if (blacklist_set.contains(r)) return error.BlacklistedTarget;
        }
    }

    for (discovered) |m| {
        if (m.override != null) continue; // replacers appended below
        // Config-only mods (mode = "<pack>") are not wasm modules: they only
        // activate a mode pack (collected below) and never enter the load
        // list, so the Wasm loader never sees a null wasm path.
        if (m.mode != null) continue;
        // `enabled = false` in mod.toml: not auto-loaded (demo gates ship
        // off); explicit [plugin] modules paths still load, and `[mods]
        // enabled` forces the mod on.
        if (m.enabled) |en| {
            if (!en and !enabled_set.contains(m.name.?)) continue;
        }
        if (disabled_set.contains(m.name.?)) continue; // skip with info log (caller logs)
        if (blacklist_set.contains(m.name.?)) return error.BlacklistedTarget;
        if (replaced.contains(m.name.?)) continue; // target of an override: dropped
        try load.append(a, .{
            .manifest = m,
            .tier = tierOf(m.tier),
            .replaces = m.override,
            .slot = load.items.len,
        });
    }
    // Append the replacers (their targets were dropped above).
    for (discovered) |m| {
        if (m.override == null) continue;
        if (m.mode != null) continue; // config-only mods never replace modules
        if (m.enabled) |en| {
            if (!en and !enabled_set.contains(m.name.?)) continue;
        }
        if (disabled_set.contains(m.name.?)) continue;
        if (blacklist_set.contains(m.name.?)) return error.BlacklistedTarget;
        try load.append(a, .{
            .manifest = m,
            .tier = tierOf(m.tier),
            .replaces = m.override,
            .slot = load.items.len,
        });
    }

    // Exclusive point claims: first claimant wins the point; a second is a
    // boot error naming both (R8). Slots are the final load order.
    var claims: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer claims.deinit(a);
    for (load.items) |rm| {
        const pts = rm.manifest.points orelse continue;
        var it = std.mem.splitScalar(u8, pts, ',');
        while (it.next()) |p_raw| {
            const p = std.mem.trim(u8, p_raw, " \t");
            if (p.len == 0) continue;
            if (claims.contains(p)) return error.DuplicateClaim;
            try claims.put(a, p, rm.slot);
        }
    }

    var name_to_slot: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer name_to_slot.deinit(a);
    for (load.items) |rm| try name_to_slot.put(a, rm.manifest.name.?, rm.slot);

    // Config-only mod: at most one enabled mod may activate a mode pack
    // (modes/<name>.toml). First in load order wins; a second is ambiguous.
    // Config-only mods never enter `load` (no wasm to load), so scan the
    // discovered set with the same enabled/disabled/override gates.
    var mode_pack: ?[]const u8 = null;
    for (discovered) |m| {
        const mo = m.mode orelse continue;
        if (m.enabled) |en| {
            if (!en and !enabled_set.contains(m.name.?)) continue;
        }
        if (disabled_set.contains(m.name.?)) continue;
        if (blacklist_set.contains(m.name.?)) return error.BlacklistedTarget;
        if (replaced.contains(m.name.?)) continue;
        if (mode_pack != null) return error.DuplicateMode;
        mode_pack = mo;
    }

    // Legacy [plugin] modules: synthesized user mods, appended after discovery.
    var synthetic = std.ArrayList(manifest.Manifest).empty;
    defer synthetic.deinit(a);
    for (explicit_paths) |path| {
        var dup = false;
        for (load.items) |rm| {
            if (std.mem.eql(u8, rm.manifest.wasm.?, path)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const fake = manifest.Manifest{
            .name = path,
            .version = null,
            .wasm = path,
            .tier = null,
            .override = null,
            .points = null,
            .claim_mode = null,
            .requires = null,
            .description = null,
            .enabled = null,
            .dir = "",
        };
        try synthetic.append(a, fake);
        try load.append(a, .{
            .manifest = fake,
            .tier = .user,
            .slot = load.items.len,
        });
        try name_to_slot.put(a, path, load.items.len - 1);
    }

    return ResolvedResult{
        .modules = try load.toOwnedSlice(a),
        .point_claims = claims,
        .name_to_slot = name_to_slot,
        .mode_pack = mode_pack,
        .synthetic = try synthetic.toOwnedSlice(a),
    };
}

fn tierOf(t: ?[]const u8) manifest.Tier {
    if (t) |s| {
        if (std.mem.eql(u8, s, "official")) return .official;
    }
    return .user;
}

// Tests
const testing = std.testing;

fn mk(name: []const u8, wasm: []const u8, tier: ?[]const u8, override: ?[]const u8, points: ?[]const u8) manifest.Manifest {
    return .{
        .name = name,
        .version = null,
        .wasm = wasm,
        .tier = tier,
        .override = override,
        .points = points,
        .claim_mode = null,
        .requires = null,
        .description = null,
        .enabled = null,
        .dir = "",
    };
}

test "resolve keeps official mods in dir order" {
    const mods = [_]manifest.Manifest{
        mk("fps_bot", "fps_bot.wasm", "official", null, null),
        mk("mcp", "mcp.wasm", "official", null, null),
    };
    var r = try resolve(testing.allocator, &mods, &.{}, &.{}, &.{}, &.{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.modules.len);
    try testing.expectEqualStrings("fps_bot", r.modules[0].manifest.name.?);
    try testing.expectEqual(.official, r.modules[0].tier);
    try testing.expectEqualStrings("mcp", r.modules[1].manifest.name.?);
}

test "resolve disabled skips mod" {
    const mods = [_]manifest.Manifest{ mk("a", "a.wasm", null, null, null), mk("b", "b.wasm", null, null, null) };
    var r = try resolve(testing.allocator, &mods, &.{}, &.{"a"}, &.{}, &.{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.modules.len);
    try testing.expectEqualStrings("b", r.modules[0].manifest.name.?);
}

test "resolve rejects disabling a core component" {
    const mods = [_]manifest.Manifest{};
    try testing.expectError(
        error.DisabledCore,
        resolve(testing.allocator, &mods, &.{}, &.{"loot"}, &.{}, &.{}),
    );
    try testing.expectError(
        error.DisabledCore,
        resolve(testing.allocator, &mods, &.{}, &.{}, &.{"quests"}, &.{}),
    );
}

test "resolve blacklist rejects mod and vetoes replacers" {
    const mods = [_]manifest.Manifest{mk("bad", "bad.wasm", null, null, null)};
    try testing.expectError(
        error.BlacklistedTarget,
        resolve(testing.allocator, &mods, &.{}, &.{}, &.{"bad"}, &.{}),
    );
}

test "resolve blacklist vetoes requires dependencies" {
    var needy = mk("needy", "needy.wasm", null, null, null);
    needy.requires = "dep";
    const mods = [_]manifest.Manifest{ mk("dep", "dep.wasm", null, null, null), needy };
    try testing.expectError(
        error.BlacklistedTarget,
        resolve(testing.allocator, &mods, &.{}, &.{}, &.{"dep"}, &.{}),
    );
    // Without the blacklist entry the same set resolves.
    var r = try resolve(testing.allocator, &mods, &.{}, &.{}, &.{}, &.{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.modules.len);
}

test "resolve override drops target, keeps replacer" {
    const mods = [_]manifest.Manifest{
        mk("fps_bot", "fps_bot.wasm", "official", null, null),
        mk("mybot", "mybot.wasm", "user", "fps_bot", null),
    };
    var r = try resolve(testing.allocator, &mods, &.{}, &.{}, &.{}, &.{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.modules.len);
    try testing.expectEqualStrings("mybot", r.modules[0].manifest.name.?);
    try testing.expectEqualStrings("fps_bot", r.modules[0].replaces.?);
}

test "resolve two replacers for one target fails" {
    const mods = [_]manifest.Manifest{
        mk("fps_bot", "fps_bot.wasm", "official", null, null),
        mk("a", "a.wasm", "user", "fps_bot", null),
        mk("b", "b.wasm", "user", "fps_bot", null),
    };
    try testing.expectError(error.DuplicateClaim, resolve(testing.allocator, &mods, &.{}, &.{}, &.{}, &.{}));
}

test "resolve duplicate point claim fails" {
    const mods = [_]manifest.Manifest{
        mk("a", "a.wasm", null, null, "loot.roll"),
        mk("b", "b.wasm", null, null, "loot.roll"),
    };
    try testing.expectError(error.DuplicateClaim, resolve(testing.allocator, &mods, &.{}, &.{}, &.{}, &.{}));
}

test "resolve exclusive point claim maps slot" {
    const mods = [_]manifest.Manifest{
        mk("gate", "gate.wasm", null, null, "loot.roll,quest.payout"),
    };
    var r = try resolve(testing.allocator, &mods, &.{}, &.{}, &.{}, &.{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.point_claims.get("loot.roll").?);
    try testing.expectEqual(@as(usize, 0), r.point_claims.get("quest.payout").?);
    try testing.expect(r.point_claims.get("craft.request") == null);
}

test "resolve explicit [plugin] modules appended as user mods" {
    const mods = [_]manifest.Manifest{};
    var r = try resolve(testing.allocator, &mods, &.{"mods/foo.wasm"}, &.{}, &.{}, &.{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.modules.len);
    try testing.expectEqualStrings("mods/foo.wasm", r.modules[0].manifest.name.?);
    try testing.expectEqual(.user, r.modules[0].tier);
}

test "resolve activates a mode pack from an enabled config-only mod" {
    // Config-only mods (mode = "pack", no wasm) ship enabled=false so a fresh
    // boot stays stock; `[mods] enabled` forces them on and activates the
    // pack, which overrides the built-in defaults like --mode.
    var cfg = mk("infinite_world", "", "user", null, null);
    cfg.mode = "infinite";
    cfg.enabled = false;
    const mods = [_]manifest.Manifest{cfg};
    // Off by default: not auto-loaded, no mode pack.
    var r0 = try resolve(testing.allocator, &mods, &.{}, &.{}, &.{}, &.{});
    defer r0.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r0.modules.len);
    try testing.expect(r0.mode_pack == null);
    // [mods] enabled forces it on; the mode pack activates. Config-only mods
    // are not wasm modules, so they never enter the load list.
    var r1 = try resolve(testing.allocator, &mods, &.{}, &.{}, &.{}, &.{"infinite_world"});
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r1.modules.len);
    try testing.expectEqualStrings("infinite", r1.mode_pack.?);
    // Two enabled config mods each with a mode: ambiguous, fail closed.
    var c2 = mk("other", "", "user", null, null);
    c2.mode = "other";
    const mods2 = [_]manifest.Manifest{ cfg, c2 };
    try testing.expectError(error.DuplicateMode, resolve(testing.allocator, &mods2, &.{}, &.{}, &.{}, &.{ "infinite_world", "other" }));
}
