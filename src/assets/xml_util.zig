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
    const end = std.mem.indexOfPos(u8, hay, start, ">") orelse hay.len;
    const window = hay[start..end];
    var needle_buf: [64]u8 = undefined;
    if (name.len + 2 > needle_buf.len) return null;
    @memcpy(needle_buf[0..name.len], name);
    needle_buf[name.len] = '=';
    const needle = needle_buf[0 .. name.len + 1];
    const ai = std.mem.indexOf(u8, window, needle) orelse return null;
    var p = window[ai + needle.len ..];
    while (p.len > 0 and (p[0] == ' ' or p[0] == '\t')) p = p[1..];
    if (p.len == 0 or p[0] != '"') return null;
    p = p[1..];
    const q = std.mem.indexOfScalar(u8, p, '"') orelse return null;
    return p[0..q];
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
