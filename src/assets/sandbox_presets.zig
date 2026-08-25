//! GameDifficulty preset ladder, computed at comptime from the stock
//! `Data/Sandbox/sandbox_presets` TextAsset (embedded as
//! `assets/sandbox_presets.xml`). The asset ships bundled in the stock
//! client's `7DaysToDie_Data/data.unity3d`, not as a dedi file; it was
//! extracted with UnityPy and committed to the research repo
//! (`7dtd-engine-research/tools/sandbox/sandbox_presets.xml`, evidence
//! sandbox-options.md §3). The six Difficulty presets carry SandboxCodes
//! (codec §3: 'A' + 3-letter base-26 option-id/value-index groups); decoding
//! them yields the per-difficulty damage multipliers consumed by stock
//! `ItemActionAttack.difficultyModifier` (IL=44) via
//! `UpdateInGameValuesWithSandboxOptions` (option 17 IncomingDamage, 42
//! EntityIncomingDamage). Never hardcode these values: they derive from the
//! embedded XML, so a modded/re-extracted preset file flows through.

const std = @import("std");
const sandbox = @import("sandbox.zig");

const src = @embedFile("sandbox_presets.xml");

/// One GameDifficulty tier (document order = difficulty index 0..5:
/// Scavenger, Adventurer, Nomad, Warrior, True Survivalist, Insane).
pub const DifficultyPreset = struct {
    name: []const u8,
    /// Preset SandboxCode ("" = all defaults = Nomad).
    code: []const u8,
    /// Option 17 IncomingDamage: zombie -> player damage multiplier.
    incoming_damage: f32,
    /// Option 42 EntityIncomingDamage: player -> zombie (1.0 on every tier).
    entity_incoming_damage: f32,
    /// Option 0 RangedDamage (client-side attack percent; the dedi never
    /// re-scales the claimed C2S strength).
    ranged_damage: f32,
    /// Option 1 MeleeDamage, same client-side leg.
    melee_damage: f32,
};

/// Value of one sandbox option at the preset's code (default 1.0 when the
/// option is absent from the code or the code is empty).
fn damageFor(code: []const u8, option: []const u8) f32 {
    if (code.len == 0) return 1.0;
    var groups: [sandbox.max_groups]sandbox.Group = undefined;
    const n = sandbox.decode(code, &groups);
    for (groups[0..n]) |g| {
        const o = sandbox.findOption(g.option_id) orelse continue;
        if (!std.mem.eql(u8, o.name, option)) continue;
        const set = sandbox.findSet(o.set_name) orelse continue;
        return sandbox.valueF(o, set, g.index);
    }
    return 1.0;
}

/// One quoted attribute value: find `key="` and return up to the closing
/// quote. Comptime-safe (pure slice ops over the embedded XML).
fn attrValue(s: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, key)) |k| {
        const vstart = k + key.len;
        if (vstart >= s.len) return null;
        if (s[vstart] != '"') {
            i = k + 1;
            continue;
        }
        const vend = std.mem.indexOfScalarPos(u8, s, vstart + 1, '"') orelse return null;
        return s[vstart + 1 .. vend];
    }
    return null;
}

/// The six difficulty presets in GameDifficulty order (0 = Scavenger .. 5 =
/// Insane), parsed at comptime from the embedded stock XML.
pub const difficulty: [6]DifficultyPreset = blk: {
    @setEvalBranchQuota(100_000);
    var out: [6]DifficultyPreset = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (n < out.len) {
        const pi = std.mem.indexOfPos(u8, src, i, "<preset ") orelse break;
        const pe = std.mem.indexOfPos(u8, src, pi, "/>") orelse break;
        const tag = src[pi .. pe + 2];
        if (attrValue(tag, "category=")) |cat| {
            if (std.mem.eql(u8, cat, "Difficulty")) {
                const name = attrValue(tag, "name=") orelse break;
                const code = attrValue(tag, "code=") orelse "";
                out[n] = .{
                    .name = name,
                    .code = code,
                    .incoming_damage = damageFor(code, "IncomingDamage"),
                    .entity_incoming_damage = damageFor(code, "EntityIncomingDamage"),
                    .ranged_damage = damageFor(code, "RangedDamage"),
                    .melee_damage = damageFor(code, "MeleeDamage"),
                };
                n += 1;
            }
        }
        i = pi + 8;
    }
    break :blk out;
};

test "difficulty ladder parses from the embedded preset XML" {
    // Golden values from the stock client TextAsset decode
    // (research sandbox-options.md §3; extract_preset_codes.py). The
    // ladder feeds `[rules.difficulty] incoming_damage_0..5` defaults.
    try std.testing.expectEqual(@as(usize, 6), difficulty.len);
    try std.testing.expectEqualStrings("Scavenger", difficulty[0].name);
    try std.testing.expectEqualStrings("Adventurer", difficulty[1].name);
    try std.testing.expectEqualStrings("Nomad", difficulty[2].name);
    try std.testing.expectEqualStrings("Warrior", difficulty[3].name);
    try std.testing.expectEqualStrings("True Survivalist", difficulty[4].name);
    try std.testing.expectEqualStrings("Insane", difficulty[5].name);
    // IncomingDamage ladder (zombie -> player).
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), difficulty[0].incoming_damage, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), difficulty[1].incoming_damage, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), difficulty[2].incoming_damage, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), difficulty[3].incoming_damage, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), difficulty[4].incoming_damage, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), difficulty[5].incoming_damage, 1e-4);
    // EntityIncomingDamage never appears in a difficulty code: 1.0 everywhere.
    for (difficulty) |d| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), d.entity_incoming_damage, 1e-4);
    }
    // Ranged/MeleeDamage ladder (client-side attack percent).
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), difficulty[0].ranged_damage, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), difficulty[5].melee_damage, 1e-4);
}
