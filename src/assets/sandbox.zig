//! Sandbox code codec + stock option/value-set lookup (RE sandbox-options §3).
//!
//! The stock dedicated server serializes its 165 sandbox options into one
//! short string, the sandbox code (`EnumGamePrefs.SandboxCode` 296), which an
//! operator pastes into `serverconfig.xml`. The client decodes it itself from
//! the GameStats(71) echo; the server decodes it here to apply the operator's
//! gameplay tuning (XP, block damage, blood moon, day length, ...) instead of
//! stock defaults. Decode is a single init-time pass, so this module has no
//! hot-path cost. Value-set and option tables are stock data, generated into
//! `sandbox_data.zig` from the IL census (see its header).
//!
//! Non-goals: the sandbox settings UI, presets editing, and per-option display
//! strings (client surface).

const std = @import("std");
const data = @import("sandbox_data.zig");

pub const Kind = data.Kind;
pub const ValueSet = data.ValueSet;
pub const Option = data.Option;
pub const value_sets = data.value_sets;
pub const options = data.options;

/// A decoded code group: option enum id + selected value-set index.
pub const Group = struct {
    option_id: u16,
    index: u8,
};

/// Upper bound on decoded groups: 165 options + version char (one group per
/// non-default option, so a code can never carry more than 165).
pub const max_groups = 165;

/// Decode a sandbox code into (option, index) groups.
///
/// Format (RE sandbox-options §3): `code := <version char> ( <option: 2
/// letters> <valueIndex: 1 letter> )*`. Option = base-26 of the two letters
/// (`"AA"` = 0), index = `'A'` = 0 .. `'Z'` = 25. A code whose first char is
/// not `'A'` is rejected (stock leaves every option at default); a trailing
/// partial group (1-2 chars) is ignored, exactly like stock's whole-triplet
/// read. Returns the number of groups decoded.
pub fn decode(code: []const u8, out: []Group) usize {
    if (code.len < 1 or code[0] != 'A') return 0;
    var n: usize = 0;
    var i: usize = 1;
    while (i + 2 < code.len and n < out.len) : (i += 3) {
        const c0 = code[i];
        const c1 = code[i + 1];
        const c2 = code[i + 2];
        if (c0 < 'A' or c0 > 'Z' or c1 < 'A' or c1 > 'Z' or c2 < 'A' or c2 > 'Z') continue;
        out[n] = .{
            .option_id = (@as(u16, c0 - 'A') * 26) + @as(u16, c1 - 'A'),
            .index = c2 - 'A',
        };
        n += 1;
    }
    return n;
}

/// Look up a value set by name (init-time only; linear over 65 entries).
pub fn findSet(name: []const u8) ?*const ValueSet {
    for (&value_sets) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// Look up an option by SandboxOptions enum id.
pub fn findOption(id: u16) ?*const Option {
    for (&options) |*o| {
        if (o.id == id) return o;
    }
    return null;
}

/// Look up an option by SandboxOptions enum member name (stable across the
/// wire; used by the config apply table instead of raw ids).
pub fn optionByName(name: []const u8) ?*const Option {
    for (&options) |*o| {
        if (std.mem.eql(u8, o.name, name)) return o;
    }
    return null;
}

/// Value of a float option at a code index; an out-of-range index falls back
/// to the option default (RE sandbox-options §1.2 membership semantics).
pub fn valueF(o: *const Option, set: *const ValueSet, index: u8) f32 {
    if (set.kind == .float and index < set.floats.len) return set.floats[index];
    return o.default_f;
}

/// Value of an int option at a code index; out-of-range falls back to default.
pub fn valueI(o: *const Option, set: *const ValueSet, index: u8) i32 {
    if (set.kind == .int and index < set.ints.len) return set.ints[index];
    return o.default_i;
}

/// Value of a bool option at a code index; only index 1 is "true".
pub fn valueB(o: *const Option, index: u8) bool {
    if (index == 1) return true;
    return o.default_i != 0;
}

test "decode rejects wrong version char" {
    var groups: [max_groups]Group = undefined;
    try std.testing.expectEqual(@as(usize, 0), decode("B", &groups));
    try std.testing.expectEqual(@as(usize, 0), decode("", &groups));
    // Version char alone = default game.
    try std.testing.expectEqual(@as(usize, 0), decode("A", &groups));
}

test "decode stock Adventurer code (RE sandbox-options §3)" {
    var groups: [max_groups]Group = undefined;
    const n = decode("AAAJABJACJADJARFBNC", &groups);
    try std.testing.expectEqual(@as(usize, 6), n);
    // AA J -> option 0 (RangedDamage), index 9
    try std.testing.expectEqual(@as(u16, 0), groups[0].option_id);
    try std.testing.expectEqual(@as(u16, 9), groups[0].index);
    // AR F -> option 17 (IncomingDamage), index 5
    try std.testing.expectEqual(@as(u16, 17), groups[4].option_id);
    try std.testing.expectEqual(@as(u16, 5), groups[4].index);
    // BN C -> option 39 (ZombieFeralSense), index 2
    try std.testing.expectEqual(@as(u16, 39), groups[5].option_id);
    try std.testing.expectEqual(@as(u16, 2), groups[5].index);
}

test "decode ignores trailing partial group" {
    var groups: [max_groups]Group = undefined;
    const n = decode("AACJ", &groups); // option 2, index 9, then 'J' dangling
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 2), groups[0].option_id);
}

test "decode skips non-letter group chars" {
    var groups: [max_groups]Group = undefined;
    const n = decode("AA1JACJ", &groups);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 2), groups[0].option_id);
}

test "stock option ids and defaults (RE sandbox-options §2.1)" {
    try std.testing.expectEqual(@as(usize, 165), options.len);
    try std.testing.expectEqual(@as(usize, 65), value_sets.len);
    const bd = optionByName("BlockDamage").?;
    try std.testing.expectEqual(@as(u16, 2), bd.id);
    const dmg = findSet(bd.set_name).?;
    try std.testing.expectEqual(@as(f32, 1.5), valueF(bd, dmg, 9)); // Adventurer
    try std.testing.expectEqual(@as(f32, 1.0), valueF(bd, dmg, 99)); // invalid -> default
    const bmf = optionByName("BloodMoonFrequency").?;
    const fset = findSet(bmf.set_name).?;
    try std.testing.expectEqual(@as(i32, 7), valueI(bmf, fset, 7));
    try std.testing.expectEqual(@as(i32, 7), valueI(bmf, fset, 30)); // out of range -> default
    try std.testing.expectEqual(@as(i32, 14), valueI(bmf, fset, 11));
}

test "bool options decode from index" {
    const shb = optionByName("ShowHealthBars").?;
    try std.testing.expectEqual(false, valueB(shb, 0));
    try std.testing.expectEqual(true, valueB(shb, 1));
    try std.testing.expectEqual(false, valueB(shb, 5)); // invalid -> default (false)
}
