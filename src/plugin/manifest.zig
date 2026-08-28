//! Mod manifest parsing (PRD 0005 / RFC 0005): `mod.toml` in a `mods/`
//! directory declares a module's tier, override target, core override-point
//! claims, and extended requires. Parsed at boot by the discovery/resolver
//! pass in `src/plugin/resolver.zig`; nothing here runs on the tick path.
//!
//! Parsing rides the ADR 0021 comptime binder (`util/toml_bind.zig`): the
//! manifest is a plain struct, unknown keys fail loudly, and string lists
//! (points/requires) are comma-separated scalars like `[plugin] modules`.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const toml_bind = @import("../util/toml_bind.zig");

/// Module tier (PRD 0005 R1): core components are native and registered
/// host-side; official mods ship with zdtd; user mods are anything else.
pub const Tier = enum { core, official, user };

/// Native core components (PRD 0005 R4): always on, cannot be disabled or
/// blacklisted via `[mods]`. Names matched by `[mods] disabled`/`blacklist`;
/// an entry naming one is a config error (AC3).
pub const core_components = [_][]const u8{
    "loot",
    "quests",
    "damage",
    "craft",
    "trading",
};

/// Known core override points (PRD 0005 R5). Point ids are the dotted names
/// mods claim in `mod.toml`; each maps to one verdict hook in wasm.zig.
pub const OverridePoint = enum {
    loot_roll,
    quest_payout,
    damage_player_scale,
    craft_request,
    trade_price,

    pub const count = std.meta.tags(OverridePoint).len;

    pub const names = .{ "loot.roll", "quest.payout", "damage.player_scale", "craft.request", "trade.price" };

    pub fn parse(s: []const u8) ?OverridePoint {
        inline for (std.meta.tags(OverridePoint), 0..) |t, i| {
            if (std.mem.eql(u8, s, names[i])) return t;
        }
        return null;
    }

    pub fn wire(self: OverridePoint) []const u8 {
        return @tagName(self);
    }

    /// The Hook name (wasm.zig) that implements this point.
    pub fn hook(self: OverridePoint) []const u8 {
        return switch (self) {
            .loot_roll => "on_loot_roll",
            .quest_payout => "on_quest_complete",
            .damage_player_scale => "on_player_damage",
            .craft_request => "on_craft_request",
            .trade_price => "on_trade_price",
        };
    }
};

/// Parsed `mod.toml`. Binder-backed: only declared fields bind; unknown keys
/// abort with `error.UnknownTomlKey` (fail-closed, RFC 0005 N2).
pub const Manifest = struct {
    pub const toml_label = "mod.toml";
    pub const allow_root = true;

    /// Mod name (required). Also matched by `[mods] disabled`/`blacklist`.
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    /// .wasm file path relative to the mod directory (required).
    wasm: ?[]const u8 = null,
    /// "official" | "user". "core" in a mod dir is a load error.
    tier: ?[]const u8 = null,
    /// Mod name this module replaces entirely (PRD 0005 R7).
    override: ?[]const u8 = null,
    /// Comma-separated point ids this module claims (binder scalar; no
    /// arrays). Callers iterate with `std.mem.splitScalar(u8, pts, ',')`.
    points: ?[]const u8 = null,
    /// Reserved future composition mode; "chain" is rejected at load (RFC
    /// 0005 3.3). Defaults to exclusive.
    claim_mode: ?[]const u8 = null,
    /// Mod names this module requires to be loaded (binder scalar list).
    requires: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Config-only mods carry a mode pack name (modes/<name>.toml) instead of
    /// a wasm module: enabling the mod activates the pack (its gameplay keys
    /// and [rules.*] override the built-in defaults, like --mode). The
    /// explicit --mode / [mode] name still wins over this.
    mode: ?[]const u8 = null,
    /// False = do not auto-load via discovery (default true). Demo gates
    /// ship with `enabled = false` so a fresh boot stays stock. `[mods]
    /// enabled` forces a mod on despite this flag.
    enabled: ?bool = null,

    /// Directory the manifest was found in (set by discovery; not a toml key).
    dir: []const u8 = "",

    /// Validate after binding: required fields, tier spelling, known points.
    /// Returns a loud message on failure (fail-closed at load).
    pub fn validate(self: *const Manifest) ?[]const u8 {
        if (self.name == null) return "missing required key 'name'";
        if (self.wasm == null and self.mode == null) {
            return "missing required key 'wasm' (or 'mode' for a config-only mod)";
        }
        if (self.wasm != null and self.mode != null) {
            return "'wasm' and 'mode' are mutually exclusive (a mod is either a plugin or a config carrier)";
        }
        if (self.mode != null and (self.override != null or self.points != null or self.requires != null)) {
            return "'mode' (config-only mod) cannot combine with 'override'/'points'/'requires' (nothing to load or replace)";
        }
        if (self.mode) |mo| {
            // Same rule as server/mode.zig isValidModeName (plugin must not
            // import server; kept in sync by the resolver test).
            var ok = mo.len > 0 and mo.len <= 64;
            for (mo) |c| {
                const c_ok = (c >= 'a' and c <= 'z') or
                    (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9') or
                    c == '_';
                if (!c_ok) ok = false;
            }
            if (!ok) return "invalid 'mode' name (use [A-Za-z0-9_] only)";
        }
        if (self.tier) |t| {
            if (!std.mem.eql(u8, t, "official") and !std.mem.eql(u8, t, "user")) {
                return "tier must be 'official' or 'user' (core components are native and registered host-side)";
            }
        }
        if (self.points) |pts| {
            var it = std.mem.splitScalar(u8, pts, ',');
            while (it.next()) |p| {
                const p_t = std.mem.trim(u8, p, " \t");
                if (p_t.len == 0) continue;
                if (OverridePoint.parse(p_t) == null) {
                    return "unknown override point '{s}' (known: loot.roll, quest.payout, damage.player_scale, craft.request, trade.price)";
                }
            }
        }
        if (self.claim_mode) |cm| {
            if (!std.mem.eql(u8, cm, "exclusive")) {
                return "claim_mode must be 'exclusive' ('chain' is reserved, not yet supported)";
            }
        }
        return null;
    }
};

/// Parse a mod.toml from `dir_path` into a Manifest. All strings are duped
/// through `a`; call `free` to release. `dir` is set to `dir_path`.
pub fn bindManifest(a: std.mem.Allocator, dir_path: []const u8) !Manifest {
    const path = try std.fs.path.join(a, &.{ dir_path, "mod.toml" });
    defer a.free(path);
    const bytes = try io_fs.readFileAll(a, path);
    defer a.free(bytes);

    var m: Manifest = .{};
    try toml_bind.bind(Manifest, &m, bytes, a);
    if (m.validate()) |msg| {
        std.debug.print("zdtd: mods: invalid mod.toml at '{s}': {s}\n", .{ dir_path, msg });
        return error.InvalidManifest;
    }
    m.dir = try a.dupe(u8, dir_path);
    return m;
}

/// Free all duped strings in a Manifest (not the struct itself).
pub fn free(a: std.mem.Allocator, m: *const Manifest) void {
    a.free(m.dir);
    a.free(m.name.?);
    if (m.version) |v| a.free(v);
    if (m.wasm) |w| a.free(w);
    if (m.mode) |mo| a.free(mo);
    if (m.tier) |t| a.free(t);
    if (m.override) |o| a.free(o);
    if (m.points) |p| a.free(p);
    if (m.claim_mode) |c| a.free(c);
    if (m.requires) |r| a.free(r);
    if (m.description) |d| a.free(d);
}

/// Discover every `mods/<name>/mod.toml` under `root` (e.g. "mods"), sorted
/// by directory name for deterministic resolution (sim rule 22). Directories
/// without mod.toml are skipped silently. Caller owns the slice + each
/// manifest (free each, then free the slice). Non-directory entries (files
/// like mods/BUILDING.md, plugin_common.zig) are not mods and are ignored.
pub fn discover(a: std.mem.Allocator, root: []const u8) ![]Manifest {
    if (!io_fs.dirExists(root)) return &.{};
    const names = try io_fs.listDirNames(a, root);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }

    var out = std.ArrayList(Manifest).empty;
    errdefer {
        for (out.items) |m| free(a, &m);
        out.deinit(a);
    }
    for (names) |name| {
        const dir_path = try std.fs.path.join(a, &.{ root, name });
        defer a.free(dir_path);
        // Only directories that contain mod.toml are mods.
        const manifest_path = try std.fs.path.join(a, &.{ dir_path, "mod.toml" });
        defer a.free(manifest_path);
        if (!io_fs.fileExists(manifest_path)) continue;
        const m = bindManifest(a, dir_path) catch |err| {
            std.debug.print("zdtd: mods: skipping '{s}': {s}\n", .{ dir_path, @errorName(err) });
            continue;
        };
        try out.append(a, m);
    }
    return out.toOwnedSlice(a);
}
