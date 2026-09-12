//! Mod manifest parsing (PRD 0005 / RFC 0005): `manifest.toml` in a `mods/`
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
/// Max size for a mod's self-contained config.toml (raw pass-through to the
/// guest; larger files fail closed to no config).
pub const max_config_bytes: usize = 4096;
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

/// The queued-command vocabulary a module can issue through `zdtd.queue`
/// (`src/ecs/command.zig` ops plus the host-handled `bot` family, which the
/// BotManager owns per ADR 0026). This is the interception vocabulary for
/// `manifest.toml deny` and the operator `[plugin] deny`/`allow` lists (paper
/// 3.2.3, ADR 0039): the policy is per verb and per module, right-biased so the
/// operator context wins over the module's own declaration.
pub const QueueVerb = enum(u3) {
    spawn,
    despawn,
    damage,
    say,
    glide,
    bot,

    pub const count = @typeInfo(QueueVerb).@"enum".fields.len;

    /// The tag names ARE the operator vocabulary (`spawn`, `bot`, ...), so
    /// there is no parallel string table to drift from the enum.
    pub fn parseVerb(s: []const u8) ?QueueVerb {
        inline for (@typeInfo(QueueVerb).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(QueueVerb, f.name);
        }
        return null;
    }

    /// Index of the verb named `s` in the queued command `s ...`; null when the
    /// first token is not a known verb (unknown commands are dropped by the
    /// caller, so they carry no policy).
    pub fn indexOf(s: []const u8) ?u3 {
        const v = parseVerb(s) orelse return null;
        return @intFromEnum(v);
    }

    pub fn bit(self: QueueVerb) u16 {
        return @as(u16, 1) << @intFromEnum(self);
    }
};

/// One verb is one bit, so a whole policy is a u16.
pub const QueueVerbMask = u16;

/// Parse a comma/space separated verb list into a mask. `bad` receives the
/// first unknown token (for a loud config error), and null is returned then;
/// an empty list is the empty mask.
pub fn queueVerbMask(list: []const u8, bad: *[]const u8) ?QueueVerbMask {
    var mask: QueueVerbMask = 0;
    var it = std.mem.tokenizeAny(u8, list, ", \t");
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        const v = QueueVerb.parseVerb(name) orelse {
            bad.* = name;
            return null;
        };
        mask |= v.bit();
    }
    return mask;
}

/// Write the comma-separated names of `mask` into `buf` (truncating on a tiny
/// buffer) and return the written slice. Used by the boot policy log and tests.
pub fn formatVerbMask(mask: QueueVerbMask, buf: []u8) []const u8 {
    var w: usize = 0;
    inline for (@typeInfo(QueueVerb).@"enum".fields, 0..) |f, i| {
        if (mask & (@as(u16, 1) << i) != 0) {
            if (w != 0 and w < buf.len) {
                buf[w] = ',';
                w += 1;
            }
            for (f.name) |c| {
                if (w >= buf.len) break;
                buf[w] = c;
                w += 1;
            }
        }
    }
    return buf[0..w];
}

/// One `module=verb,verb` entry of an operator policy list (`[plugin] deny` /
/// `allow`). `mask` is the verb mask attributed to `module`.
pub const PolicyEntry = struct {
    module: []const u8 = "",
    mask: QueueVerbMask = 0,
};

/// Cap on operator policy entries (one per module per list). Boot-time only;
/// the parsed table is fixed-size so nothing allocates.
pub const max_policy_entries: usize = 32;

/// Parse `deny = "core_lootgate=damage,say; core_pvp=say"` into `out`. Entries
/// are `;`-separated, each `module=verbs`; verbs may also be space separated.
/// Returns the number written, or null with `bad` set to the offending token
/// (an unknown verb or a malformed pair) so the caller can fail the startup
/// loudly instead of running a policy the operator did not write. More entries
/// than `out` holds is also a `bad` ("too many entries").
pub fn parsePolicyList(list: []const u8, out: []PolicyEntry, bad: *[]const u8) ?usize {
    var n: usize = 0;
    var entries = std.mem.splitScalar(u8, list, ';');
    while (entries.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;
        const eq = std.mem.findScalar(u8, entry, '=') orelse {
            bad.* = entry;
            return null;
        };
        const module = std.mem.trim(u8, entry[0..eq], " \t");
        const verbs = std.mem.trim(u8, entry[eq + 1 ..], " \t");
        if (module.len == 0 or verbs.len == 0) {
            bad.* = entry;
            return null;
        }
        if (n >= out.len) {
            bad.* = "too many [plugin] policy entries";
            return null;
        }
        var bad_verb: []const u8 = "";
        const mask = queueVerbMask(verbs, &bad_verb) orelse {
            bad.* = bad_verb;
            return null;
        };
        out[n] = .{ .module = module, .mask = mask };
        n += 1;
    }
    return n;
}

/// Known core override points (PRD 0005 R5). Point ids are the dotted names
/// mods claim in `manifest.toml`; each maps to one verdict hook in wasm.zig.
pub const OverridePoint = enum {
    loot_roll,
    quest_payout,
    damage_player_scale,
    craft_request,
    trade_price,

    pub const count = @typeInfo(OverridePoint).@"enum".fields.len;

    /// The manifest vocabulary is dotted while the enum tags are underscored,
    /// so this table is NOT redundant with `@tagName` (unlike QueueVerb), and
    /// `wire()` must use it rather than the tag.
    pub const names = [_][]const u8{ "loot.roll", "quest.payout", "damage.player_scale", "craft.request", "trade.price" };

    pub fn parsePoint(s: []const u8) ?OverridePoint {
        inline for (@typeInfo(OverridePoint).@"enum".fields, 0..) |f, i| {
            if (std.mem.eql(u8, s, names[i])) return @field(OverridePoint, f.name);
        }
        return null;
    }

    /// The point's operator-facing name (what a manifest claims and a log
    /// should print): the dotted name, not the underscored enum tag.
    pub fn wire(self: OverridePoint) []const u8 {
        return names[@intFromEnum(self)];
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

/// Parsed `manifest.toml`. Binder-backed: only declared fields bind; unknown keys
/// abort with `error.UnknownTomlKey` (fail-closed, RFC 0005 N2).
pub const Manifest = struct {
    pub const toml_label = "manifest.toml";
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
    /// Comma-separated queued-command verbs this module may NOT issue
    /// (interception, paper 3.2.3 / ADR 0039). A declaration of intent the host
    /// enforces for the module; the operator's `[plugin] deny`/`allow` lists
    /// apply over it, right-biased. Unknown verb names fail the manifest.
    deny: ?[]const u8 = null,
    /// Mod names this module requires to be loaded (binder scalar list).
    requires: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Optional icon path (relative to the mod dir, e.g. `icon = "icon.png"`).
    /// Metadata only: the host never loads or renders it (the webui module
    /// list may serve it); the standard is the folder ships `icon.png`.
    icon: ?[]const u8 = null,
    /// Config-only mods carry a preset file path (relative to the mod dir,
    /// e.g. `preset = "preset.toml"`) instead of a wasm module: enabling the mod
    /// activates the preset (its gameplay keys and [rules.*] override the built-
    /// in defaults, like --preset). The explicit --preset / [preset] name wins.
    preset: ?[]const u8 = null,
    /// False = do not auto-load via discovery (default true). Demo gates
    /// ship with `enabled = false` so a fresh boot stays stock. `[mods]
    /// enabled` forces a mod on despite this flag.
    enabled: ?bool = null,

    /// Directory the manifest was found in (set by discovery; not a toml key).
    dir: []const u8 = "",
    /// Raw `<dir>/config.toml` (the plugin's own default config; optional).
    /// Passed through to the guest verbatim via the zdtd.config import - the
    /// host does not impose a schema, each plugin parses its own. "" when the
    /// file is absent or larger than `max_config_bytes` (fail closed: a
    /// plugin that needs config sees none rather than a truncated blob).
    config: []const u8 = "",

    /// Validate after binding: required fields, tier spelling, known points.
    /// Returns a loud message on failure (fail-closed at load).
    pub fn validate(self: *const Manifest) ?[]const u8 {
        if (self.name == null) return "missing required key 'name'";
        if (self.wasm == null and self.preset == null) {
            return "missing required key 'wasm' (or 'preset' for a config-only mod)";
        }
        // A mod may be a plugin (wasm), a config carrier (preset only), or
        // both (ADR 0037 parachute: wasm behavior + its own rules/authority
        // preset). Only the config-only form forbids the plugin fields.
        if (self.preset != null and self.wasm == null and (self.override != null or self.points != null or self.requires != null)) {
            return "'preset' (config-only mod) cannot combine with 'override'/'points'/'requires' (nothing to load or replace)";
        }
        if (self.icon) |ic| {
            // Same rule as preset: a relative path inside the mod dir only.
            var ok = ic.len > 0 and ic.len <= 128;
            if (ic.len > 0 and (ic[0] == '/' or ic[0] == '\\')) ok = false;
            if (std.mem.find(u8, ic, "..") != null) ok = false;
            if (!ok) return "invalid 'icon' path (must be a relative path inside the mod dir, no '..')";
        }
        if (self.preset) |pr| {
            // Relative path inside the mod dir only: no absolute paths, no
            // parent traversal (a preset must stay self-contained in the mod
            // folder). Empty or oversized is a load error.
            var ok = pr.len > 0 and pr.len <= 128;
            if (pr.len > 0 and (pr[0] == '/' or pr[0] == '\\')) ok = false;
            if (std.mem.find(u8, pr, "..") != null) ok = false;
            if (!ok) return "invalid 'preset' path (must be a relative path inside the mod dir, no '..')";
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
                if (OverridePoint.parsePoint(p_t) == null) {
                    return "unknown override point in 'points' (known: loot.roll, quest.payout, damage.player_scale, craft.request, trade.price)";
                }
            }
        }
        if (self.deny) |list| {
            var bad: []const u8 = "";
            if (queueVerbMask(list, &bad) == null) {
                return "unknown queued verb in 'deny' (known: spawn, despawn, damage, say, glide, bot)";
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

/// Parse a manifest.toml from `dir_path` into a Manifest. All strings are duped
/// through `a`; call `free` to release. `dir` is set to `dir_path`.
pub fn bindManifest(a: std.mem.Allocator, dir_path: []const u8) !Manifest {
    const path = try std.fs.path.join(a, &.{ dir_path, "manifest.toml" });
    defer a.free(path);
    const bytes = try io_fs.readFileAll(a, path);
    defer a.free(bytes);

    var m: Manifest = .{};
    try toml_bind.bind(Manifest, &m, bytes, a);
    if (m.validate()) |msg| {
        std.debug.print("zdtd: mods: invalid manifest.toml at '{s}': {s}\n", .{ dir_path, msg });
        return error.InvalidManifest;
    }
    m.dir = try a.dupe(u8, dir_path);
    // Optional self-contained config: raw text passed to the guest verbatim.
    // A missing or oversized file is not a load error (config is optional;
    // fail closed to no config, never a truncated blob).
    const cfg_path = try std.fs.path.join(a, &.{ dir_path, "config.toml" });
    defer a.free(cfg_path);
    if (io_fs.fileExists(cfg_path)) {
        const cfg = try io_fs.readFileAll(a, cfg_path);
        if (cfg.len <= max_config_bytes) m.config = cfg;
    }
    return m;
}

/// Free all duped strings in a Manifest (not the struct itself).
pub fn free(a: std.mem.Allocator, m: *const Manifest) void {
    a.free(m.dir);
    a.free(m.name.?);
    if (m.config.len > 0) a.free(m.config);
    if (m.version) |v| a.free(v);
    if (m.wasm) |w| a.free(w);
    if (m.preset) |pr| a.free(pr);
    if (m.icon) |ic| a.free(ic);
    if (m.tier) |t| a.free(t);
    if (m.override) |o| a.free(o);
    if (m.points) |p| a.free(p);
    if (m.claim_mode) |c| a.free(c);
    if (m.deny) |d| a.free(d);
    if (m.requires) |r| a.free(r);
    if (m.description) |d| a.free(d);
}

/// Discover every `mods/<name>/manifest.toml` under `root` (e.g. "mods"), sorted
/// by directory name for deterministic resolution (sim rule 22). Directories
/// without manifest.toml are skipped silently. Caller owns the slice + each
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
        // Only directories that contain manifest.toml are mods.
        const manifest_path = try std.fs.path.join(a, &.{ dir_path, "manifest.toml" });
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

test "queued verb policy: mask parse, format, and the operator list grammar" {
    // The interception vocabulary (paper 3.2.3 / ADR 0039): a policy is one
    // bit per verb, parsed once at boot and checked per queued command.
    var bad: []const u8 = "";
    const m = queueVerbMask("say, damage glide", &bad) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        QueueVerb.say.bit() | QueueVerb.damage.bit() | QueueVerb.glide.bit(),
        m,
    );
    // An unknown verb is a config error, named for the operator.
    try std.testing.expectEqual(@as(?QueueVerbMask, null), queueVerbMask("say,teleport", &bad));
    try std.testing.expectEqualStrings("teleport", bad);
    // Empty list = no policy; formatting round-trips the names.
    try std.testing.expectEqual(@as(?QueueVerbMask, 0), queueVerbMask("", &bad));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("damage,say,glide", formatVerbMask(m, &buf));

    // `module=verbs; module2=verbs` operator grammar.
    var out: [max_policy_entries]PolicyEntry = undefined;
    const n = parsePolicyList("core_lootgate=damage,say; core_pvp=say", &out, &bad) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("core_lootgate", out[0].module);
    try std.testing.expectEqual(QueueVerb.damage.bit() | QueueVerb.say.bit(), out[0].mask);
    try std.testing.expectEqualStrings("core_pvp", out[1].module);
    try std.testing.expectEqual(QueueVerb.say.bit(), out[1].mask);
    // Malformed pair and unknown verb both fail with the offending token.
    try std.testing.expectEqual(@as(?usize, null), parsePolicyList("core_lootgate", &out, &bad));
    try std.testing.expectEqualStrings("core_lootgate", bad);
    try std.testing.expectEqual(@as(?usize, null), parsePolicyList("m=teleport", &out, &bad));
    try std.testing.expectEqualStrings("teleport", bad);
    // Whitespace-only entries are skipped, not errors.
    try std.testing.expectEqual(@as(?usize, 1), parsePolicyList(" ; m=say ; ", &out, &bad));
}
