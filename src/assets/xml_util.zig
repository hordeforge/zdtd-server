//! Tiny helpers for scanning stock 7DTD XML configs (no full DOM).

const std = @import("std");

/// Strip `<!-- ... -->` comments (including the format-doc block at top of quests.xml).
pub fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < src.len) {
        if (i + 3 < src.len and src[i] == '<' and src[i + 1] == '!' and src[i + 2] == '-' and src[i + 3] == '-') {
            const end = std.mem.indexOfPos(u8, src, i + 4, "-->") orelse {
                // Unclosed comment: drop rest.
                break;
            };
            i = end + 3;
            continue;
        }
        try out.append(allocator, src[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// First `name="value"` after `start` within `hay` (stops at `>`).
pub fn attr(hay: []const u8, start: usize, name: []const u8) ?[]const u8 {
    var end = start;
    var tag_quote: ?u8 = null;
    while (end < hay.len) : (end += 1) {
        const c = hay[end];
        if (tag_quote) |q| {
            if (c == q) tag_quote = null;
        } else if (c == '"' or c == '\'') {
            tag_quote = c;
        } else if (c == '>') {
            break;
        }
    }
    const window = hay[start..end];
    var i: usize = 0;
    while (i < window.len) {
        while (i < window.len and std.ascii.isWhitespace(window[i])) i += 1;
        const key_start = i;
        while (i < window.len and !std.ascii.isWhitespace(window[i]) and window[i] != '=') i += 1;
        const key = window[key_start..i];
        while (i < window.len and std.ascii.isWhitespace(window[i])) i += 1;
        if (i >= window.len or window[i] != '=') {
            continue;
        }
        i += 1;
        while (i < window.len and std.ascii.isWhitespace(window[i])) i += 1;
        if (i >= window.len or (window[i] != '"' and window[i] != '\'')) continue;
        const quote = window[i];
        i += 1;
        const value_start = i;
        while (i < window.len and window[i] != quote) i += 1;
        if (i >= window.len) return null;
        if (std.mem.eql(u8, key, name)) return window[value_start..i];
        i += 1;
    }
    return null;
}

/// Property inside a quest body: `<property name="X" value="Y"/>` or with extra attrs.
pub fn propertyValue(body: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < body.len) {
        const pi = std.mem.indexOfPos(u8, body, i, "<property") orelse break;
        const name_v = attr(body, pi, "name") orelse {
            i = pi + 9;
            continue;
        };
        if (std.mem.eql(u8, name_v, name)) {
            return attr(body, pi, "value");
        }
        i = pi + 9;
    }
    return null;
}

/// First `<passive_effect name="X" ... value="Y"/>` value in an effect_group
/// body (items.xml Distraction* / buffs.xml passives, e.g. decoy's
/// `DistractionRadius` with `operation="base_set"`).
pub fn passiveEffectValue(body: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < body.len) {
        const pi = std.mem.indexOfPos(u8, body, i, "<passive_effect") orelse break;
        const name_v = attr(body, pi, "name") orelse {
            i = pi + 15;
            continue;
        };
        if (std.mem.eql(u8, name_v, name)) {
            return attr(body, pi, "value");
        }
        i = pi + 15;
    }
    return null;
}

pub fn parseU16(s: []const u8) ?u16 {
    return std.fmt.parseInt(u16, s, 10) catch null;
}

pub fn parseU8(s: []const u8) ?u8 {
    return std.fmt.parseInt(u8, s, 10) catch null;
}

pub fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

pub fn parseF32(s: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, s) catch null;
}

/// Leading signed decimal of `s`, ignoring any trailing junk (`"12, 34"` → 12).
/// Malformed XML must not crash the loader: reject instead of overflowing.
pub fn parseI32Prefix(s: []const u8) ?i32 {
    if (s.len == 0) return null;
    var i: usize = 0;
    const neg = s[0] == '-';
    if (neg) i = 1;
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    var v: i32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = std.math.mul(i32, v, 10) catch return null;
        v = std.math.add(i32, v, s[i] - '0') catch return null;
    }
    return if (neg) -v else v;
}

test "parseI32Prefix stops at junk and rejects overflow" {
    try std.testing.expectEqual(@as(?i32, 12), parseI32Prefix("12, 34"));
    try std.testing.expectEqual(@as(?i32, -7), parseI32Prefix("-7"));
    try std.testing.expectEqual(@as(?i32, null), parseI32Prefix("x1"));
    try std.testing.expectEqual(@as(?i32, null), parseI32Prefix("-"));
    try std.testing.expectEqual(@as(?i32, null), parseI32Prefix("99999999999999"));
}

/// One element body between open tag and matching close (or self-closing).
pub const Element = struct {
    /// Index of '<' of the open tag.
    open_at: usize,
    /// Slice between `>` and close tag (empty if self-closing).
    body: []const u8,
    /// Index to resume scan after this element.
    next_i: usize,
};

/// Find next element starting with `open_prefix` (e.g. `"<block "`) after `start`.
/// `close_tag` is e.g. `"</block>"`. Handles self-closing `/>`.
pub fn nextElement(
    hay: []const u8,
    start: usize,
    comptime open_prefix: []const u8,
    comptime close_tag: []const u8,
) ?Element {
    const open_at = std.mem.indexOfPos(u8, hay, start, open_prefix) orelse return null;
    const gt = std.mem.indexOfPos(u8, hay, open_at, ">") orelse return null;
    if (gt > open_at and hay[gt - 1] == '/') {
        return .{
            .open_at = open_at,
            .body = hay[gt + 1 .. gt + 1],
            .next_i = gt + 1,
        };
    }
    const close = std.mem.indexOfPos(u8, hay, gt, close_tag) orelse return null;
    return .{
        .open_at = open_at,
        .body = hay[gt + 1 .. close],
        .next_i = close + close_tag.len,
    };
}

test "strip comments removes doc block" {
    const src =
        \\<!-- fake <quest id="bogus"> -->
        \\<quests starter_quest="a">
        \\<quest id="a"></quest>
        \\</quests>
    ;
    const clean = try stripComments(std.testing.allocator, src);
    defer std.testing.allocator.free(clean);
    try std.testing.expect(std.mem.indexOf(u8, clean, "bogus") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean, "starter_quest") != null);
}

test "attr and propertyValue" {
    const s = "<quest id=\"tier1_clear\" difficulty=\"1\"><property name=\"name_key\" value=\"quest_tier1_clear\"/></quest>";
    try std.testing.expectEqualStrings("tier1_clear", attr(s, 0, "id").?);
    const body_start = std.mem.indexOf(u8, s, ">").? + 1;
    try std.testing.expectEqualStrings("quest_tier1_clear", propertyValue(s[body_start..], "name_key").?);
}

test "attr accepts XML whitespace and quote forms without suffix matches" {
    const s = "<property force_prob=\"wrong\" name = 'ServerPort' value = \"27002\"/>";
    try std.testing.expectEqualStrings("ServerPort", attr(s, 0, "name").?);
    try std.testing.expectEqualStrings("27002", attr(s, 0, "value").?);
    try std.testing.expect(attr(s, 0, "prob") == null);
}

test "attr permits greater-than inside a quoted value" {
    const s = "<property name=\"ServerPassword\" value=\"left>right\"/>";
    try std.testing.expectEqualStrings("left>right", attr(s, 0, "value").?);
}
