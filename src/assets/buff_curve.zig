//! Buff curve math: value lists, weights, curve parse + evaluation.
//!
//! Split out of assets/buffs.zig (same code, moved verbatim);
//! re-exported so existing `buffs.*` call sites keep working.
//!
const std = @import("std");
const Passive = @import("buffs.zig").Passive;
const max_curve_len: usize = @import("buffs.zig").max_curve_len;
const xml = @import("xml_util.zig");

pub fn firstF32(s: []const u8) f32 {
    const comma = std.mem.findScalar(u8, s, ',') orelse s.len;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, s[0..comma], " \t")) catch 0;
}

/// Parse a comma-separated ModifyCVar value curve (spear-hunter metabolism
/// rows) into a fixed array; level i reads value[i] (1-based).
pub fn parseValueList(s: []const u8) struct { list: [16]f32, n: u8 } {
    var out = [_]f32{0} ** 16;
    var n: u8 = 0;
    if (s.len == 0) return .{ .list = out, .n = 0 };
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const t = std.mem.trim(u8, seg, " \t");
        if (t.len == 0) continue;
        if (n >= out.len) break;
        out[n] = std.fmt.parseFloat(f32, t) catch 0;
        n += 1;
    }
    return .{ .list = out, .n = n };
}

/// Parse a comma-separated `weights=` list into a fixed array (fireOneBuff).
pub fn parseWeights(s: []const u8) [16]f32 {
    var out = [_]f32{0} ** 16;
    if (s.len == 0) return out;
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |seg| {
        if (i >= out.len) break;
        out[i] = std.fmt.parseFloat(f32, std.mem.trim(u8, seg, " \t")) catch 0;
        i += 1;
    }
    return out;
}

/// Count of parsed weights (0 for empty).
pub fn weightsCount(s: []const u8) u8 {
    if (s.len == 0) return 0;
    var n: u8 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        if (std.mem.trim(u8, seg, " \t").len == 0) continue;
        if (n >= 16) break;
        n += 1;
    }
    return n;
}

/// Fill `out` with the comma-separated curve segments of a passive `value`
/// (stock: segment i applies at level i+1). Returns the segment count (0 for
/// an empty value). `out[0]` is always the flat/level-1 value.
pub fn parseCurveValue(s: []const u8, out: *[max_curve_len]f32) u8 {
    var n: u8 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const seg_t = std.mem.trim(u8, seg, " \t");
        if (seg_t.len == 0) continue;
        if (n >= max_curve_len) break;
        out[n] = std.fmt.parseFloat(f32, seg_t) catch 0;
        n += 1;
    }
    return n;
}

/// Stock curve evaluation (RE PassiveEffect::ModValue, IL=796): the curve
/// Levels are scaled so value[0] sits at level 1 and value[n-1] at
/// `max_level`, and the effect interpolates linearly between neighbours
/// (Mathf.Lerp on the level fraction); a level outside every segment applies
/// nothing (0). The item effect level is the raw ItemValue.Quality
/// (EffectManager.GetValue IL_0393), so 6-value armor curves are per-quality
/// values and 2-value curves interpolate Q1..Q6 (e.g. 8..12.3).
pub fn curveValueAt(level: u8, max_level: u8, curve: []const f32) f32 {
    if (curve.len == 0 or level == 0 or max_level < 2) return 0;
    if (curve.len == 1) return curve[0];
    const l: f32 = @floatFromInt(level);
    const hi: f32 = @floatFromInt(max_level);
    const n = curve.len;
    for (1..n) |i| {
        const l0: f32 = 1.0 + (hi - 1.0) * @as(f32, @floatFromInt(i - 1)) / @as(f32, @floatFromInt(n - 1));
        const l1: f32 = 1.0 + (hi - 1.0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
        if (l >= l0 and l <= l1) {
            const t: f32 = if (l1 > l0) (l - l0) / (l1 - l0) else 0;
            return curve[i - 1] + (curve[i] - curve[i - 1]) * t;
        }
    }
    return 0;
}

/// The axis a passive curve is evaluated on. Stock calls
/// `PassiveEffect.ModifyValue(ea, level, ...)` with the **purchased level** for
/// perk/attribute passives and with `BuffValue.DurationInSeconds` for buff
/// passives (`BuffClass::ModifyValue` IL=105), and the `level=`/`duration=`
/// attributes both fill the same `Levels` array.
pub const Axis = union(enum) {
    /// A purchased progression level (1-based; 0 = not purchased).
    level: u8,
    /// A buff's elapsed duration in seconds.
    duration: f32,
    /// An equipped/held item's quality tier. Unlike `level`, quality 0 is a
    /// real value (an item with no quality tier), so it does not short-circuit:
    /// stock seeds `PassiveEffect.ModValue` with `ItemValue.Quality` and spreads
    /// the value curve across the item's tier axis (`tier=`/quality 1..max),
    /// which is `curveValueAt` rather than the level-anchor interpolator.
    quality: Quality,
};

/// The item-quality axis: the tier value plus the tier count cap the items.xml
/// curve spreads over (stock item quality 1..6, `components.max_quality_tiers`).
pub const Quality = struct { level: u8, max: u8 };

/// Anchor-pair curve evaluation (stock `PassiveEffect.ModValue` over the
/// `level=`/`duration=` anchors): piecewise-linear between (levels[i],
/// values[i]); an axis outside every segment applies nothing (0), matching
/// ModValue's fall-through. Stock pairs the arrays **by shape** rather than by
/// padding them to equal length (`PassiveEffect::ModValue` IL_0016 `bne.un`
/// IL_01D4), so the two unequal shapes are evaluated explicitly:
/// `levels.len >= 2` with a single value holds `values[0]` flat across
/// `levels[0]..levels[1]` (IL_0348), and a single level with two values rolls
/// between them (IL_01D4, stock `RandomRange` / mean when the cached seed is 0,
/// for which the deterministic mean is the sim-safe projection). Every other
/// mismatch applies nothing (IL_057C).
pub fn curveValueAtLevels(axis: f32, levels: []const f32, values: []const f32) f32 {
    if (levels.len == 0 or values.len == 0) return 0;
    if (values.len != levels.len) {
        if (levels.len >= 2 and values.len == 1) {
            return if (axis >= levels[0] and axis <= levels[1]) values[0] else 0;
        }
        if (levels.len == 1 and values.len == 2) {
            return if (@floor(axis) == @floor(levels[0])) (values[0] + values[1]) * 0.5 else 0;
        }
        return 0;
    }
    // Single anchor: stock (PassiveEffect::ModValue IL=161) applies values[0]
    // only when FloorToInt(axis) == FloorToInt(levels[0]); it does not
    // interpolate or extrapolate. This is the shape of every `<book>` passive
    // row and 148 progression rows.
    if (levels.len == 1) {
        return if (@floor(axis) == @floor(levels[0])) values[0] else 0;
    }
    // Highest matching bracket wins (stock scans i = n-1 down to 1, IL_0155).
    var i: usize = levels.len;
    while (i > 1) : (i -= 1) {
        const j = i - 1;
        const l0 = levels[j - 1];
        const l1 = levels[j];
        if (axis >= l0 and axis <= l1) {
            const t: f32 = if (l1 > l0) (axis - l0) / (l1 - l0) else 0;
            return values[j - 1] + (values[j] - values[j - 1]) * t;
        }
    }
    return 0;
}

/// Value of a passive on `axis`. With explicit anchors the value interpolates
/// between the pairs; without them stock's `_levels == null` branch applies a
/// single value flat, averages a two-value row, and applies nothing for more
/// (ModValue IL=3C4).
pub fn curveAtAxis(p: Passive, axis: f32) f32 {
    if (p.curve_levels_len > 0) {
        // The value array keeps its own length: a `level="1,5" value="-1"` row
        // has two anchors and one value, which stock holds flat rather than
        // ramping to 0.
        return curveValueAtLevels(axis, p.curve_levels[0..p.curve_levels_len], p.curve[0..p.curve_len]);
    }
    if (p.curve_len == 0) return p.value;
    if (p.curve_len == 1) return p.curve[0];
    if (p.curve_len == 2) return (p.curve[0] + p.curve[1]) * 0.5;
    return 0;
}

/// Value of a passive at a purchased `level` (1-based). Level 0 (unpurchased)
/// is 0.
pub fn curveAt(p: Passive, level: u8) f32 {
    if (level == 0) return 0;
    return curveAtAxis(p, @floatFromInt(level));
}

/// Parse the explicit `level="a,b,..."` anchors (parallel to the value curve).
pub fn parseCurveLevels(s: []const u8, out: *[max_curve_len]f32) u8 {
    var n: u8 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const seg_t = std.mem.trim(u8, seg, " \t");
        if (seg_t.len == 0) continue;
        if (n >= max_curve_len) break;
        out[n] = std.fmt.parseFloat(f32, seg_t) catch 0;
        n += 1;
    }
    return n;
}

/// Stock's anchor attribute chain (`PassiveEffect::ParsePassiveEffect`): the
/// first non-empty of `level=` (IL_01D3), `tier=` (IL_026C) or `duration=`
/// (IL_0304) fills the same Levels array, because each branch jumps past the
/// ones after it (`br IL_0394`). `tier=` is the items.xml quality axis (633
/// stock rows) and `duration=` the buff elapsed-time axis.
pub fn parseAnchors(body: []const u8, tag: usize, out: *[max_curve_len]f32) u8 {
    for ([_][]const u8{ "level", "tier", "duration" }) |attr_name| {
        const s = xml.attr(body, tag, attr_name) orelse continue;
        const n = parseCurveLevels(s, out);
        if (n > 0) return n;
    }
    return 0;
}

