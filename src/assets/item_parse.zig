//! Item XML row readers: action-class, cvar/progression/exp scans,
//! bool props, stats bodies, and rounding.
//!
//! Split out of assets/items.zig (same code, moved verbatim; private fns
//! made pub); used by the table loader in items.zig.
//!
const std = @import("std");
const xml = @import("xml_util.zig");
const components = @import("../ecs/components.zig");
const items_start_here = @import("items.zig").items_start_here;
const ItemTable = @import("items.zig").ItemTable;
const loadFromPath = @import("items.zig").loadFromPath;
const paths = @import("paths.zig");

pub fn itemActionClassIs(body: []const u8, want: []const u8) bool {
    // Prefer nested <property class="Action0"> ... Class=Eat
    var i: usize = 0;
    while (i < body.len) {
        const pi = std.mem.findPos(u8, body, i, "<property") orelse break;
        const cn = xml.attr(body, pi, "class") orelse {
            i = pi + 9;
            continue;
        };
        if (!(std.mem.startsWith(u8, cn, "Action"))) {
            i = pi + 9;
            continue;
        }
        // Find end of this property class block: next </property> after nested props.
        const rest = body[pi..];
        // Search Class value within next 400 bytes of this Action block.
        const window = if (rest.len > 500) rest[0..500] else rest;
        if (xml.propertyValue(window, "Class")) |cls| {
            if (std.mem.eql(u8, cls, want)) return true;
        }
        i = pi + 9;
    }
    return false;
}

/// First effect_group ModifyCVar add for cvar name (e.g. $foodAmountAdd).
pub fn firstCvarAdd(body: []const u8, cvar: []const u8) ?f32 {
    var i: usize = 0;
    while (i < body.len) {
        const ti = std.mem.findPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.findPos(u8, body, ti, "/>") orelse (std.mem.findPos(u8, body, ti, ">") orelse break);
        const win = body[ti .. end + 2];
        const cv = xml.attr(win, 0, "cvar") orelse {
            i = ti + 10;
            continue;
        };
        if (!std.mem.eql(u8, cv, cvar)) {
            i = ti + 10;
            continue;
        }
        const op = xml.attr(win, 0, "operation") orelse {
            i = ti + 10;
            continue;
        };
        if (!(std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "set"))) {
            i = ti + 10;
            continue;
        }
        if (xml.attr(win, 0, "value")) |v| {
            return xml.parseF32(v);
        }
        i = ti + 10;
    }
    return null;
}

/// First `AddProgressionLevel` triggered_effect: (progression_name, level).
/// Magazines ship `level="1"` (add 1, clamped to class max). Absolute
/// `SetProgressionLevel` rows are collected separately via
/// `collectProgressionSetMax`.
pub fn firstProgressionAdd(body: []const u8) ?struct { []const u8, u8 } {
    var i: usize = 0;
    while (i < body.len) {
        const ti = std.mem.findPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.findPos(u8, body, ti, "/>") orelse (std.mem.findPos(u8, body, ti, ">") orelse break);
        const win = body[ti .. end + 2];
        const action = xml.attr(win, 0, "action") orelse {
            i = ti + 10;
            continue;
        };
        if (!std.mem.eql(u8, action, "AddProgressionLevel")) {
            i = ti + 10;
            continue;
        }
        const pname = xml.attr(win, 0, "progression_name") orelse {
            i = ti + 10;
            continue;
        };
        const raw = xml.attr(win, 0, "level") orelse "1";
        const lvl = xml.parseI32Prefix(raw) orelse 1;
        if (lvl <= 0) {
            i = ti + 10;
            continue;
        }
        const add: u8 = @intCast(@min(lvl, 255));
        return .{ pname, add };
    }
    return null;
}

/// Collect `SetProgressionLevel` names with `level="-1"` (RE minevents.md
/// IL=104: set ProgressionClass.MaxLevel). Stock ships only `-1`; other
/// levels are omitted rather than guessed. Arena owns the returned names.
pub fn collectProgressionSetMax(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    // Names live in the items arena; only the list storage needs teardown on error.
    errdefer names.deinit(arena);
    var i: usize = 0;
    while (i < body.len) {
        const ti = std.mem.findPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.findPos(u8, body, ti, "/>") orelse (std.mem.findPos(u8, body, ti, ">") orelse break);
        const win = body[ti .. end + 2];
        const action = xml.attr(win, 0, "action") orelse {
            i = ti + 10;
            continue;
        };
        if (!std.mem.eql(u8, action, "SetProgressionLevel")) {
            i = ti + 10;
            continue;
        }
        const pname = xml.attr(win, 0, "progression_name") orelse {
            i = ti + 10;
            continue;
        };
        const raw = xml.attr(win, 0, "level") orelse {
            i = ti + 10;
            continue;
        };
        const lvl = xml.parseI32Prefix(raw) orelse {
            i = ti + 10;
            continue;
        };
        if (lvl != -1) {
            i = ti + 10;
            continue;
        }
        try names.append(arena, try arena.dupe(u8, pname));
        i = ti + 10;
    }
    if (names.items.len == 0) {
        names.deinit(arena);
        return &.{};
    }
    return try names.toOwnedSlice(arena);
}

/// First `GiveExp` triggered_effect exp amount. Magazines ship 50.
/// Cvar-backed GiveExp is not modelled (stock magazines use a literal).
pub fn firstGiveExp(body: []const u8) u16 {
    var i: usize = 0;
    while (i < body.len) {
        const ti = std.mem.findPos(u8, body, i, "triggered_effect") orelse break;
        const end = std.mem.findPos(u8, body, ti, "/>") orelse (std.mem.findPos(u8, body, ti, ">") orelse break);
        const win = body[ti .. end + 2];
        const action = xml.attr(win, 0, "action") orelse {
            i = ti + 10;
            continue;
        };
        if (!std.mem.eql(u8, action, "GiveExp")) {
            i = ti + 10;
            continue;
        }
        const raw = xml.attr(win, 0, "exp") orelse {
            i = ti + 10;
            continue;
        };
        const n = xml.parseI32Prefix(raw) orelse 0;
        if (n <= 0) {
            i = ti + 10;
            continue;
        }
        return @intCast(@min(n, 65535));
    }
    return 0;
}

/// Builtin ECS catalog (stable small ids for sim/save).
/// Stock's clamp on a sandbox-scaled stack (ItemClass.get_MaxCount IL_003F).
pub const max_scaled_stack: i32 = 30000;

/// `Utils::FastRoundToInt` (IL=1616): `(int)Math.Round((double)f)`, i.e. .NET's
/// default midpoint-to-even rounding - not away-from-zero. A 7.5 product is 8
/// and a 6.5 product is 6, which matters because the stock MaxStackSize
/// multipliers include .25/.5/.75/1.25/1.5/1.75/2.5.
pub fn fastRoundToInt(v: f32) i32 {
    const f = @floor(v);
    if (v - f == 0.5) {
        // Midpoint: the even neighbour wins.
        const even: f32 = if (@mod(f, 2.0) == 0) f else f + 1;
        return @trunc(even);
    }
    return @round(v);
}

pub fn boolProp(v: []const u8) ?bool {
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "true") or std.mem.eql(u8, t, "1")) return true;
    if (std.ascii.eqlIgnoreCase(t, "false") or std.mem.eql(u8, t, "0")) return false;
    return null;
}

pub fn itemStatsBody(body: []const u8) ?[]const u8 {
    const si = std.mem.findPos(u8, body, 0, "<stats") orelse return null;
    const gt = std.mem.findPos(u8, body, si, ">") orelse return null;
    if (gt == si or body[gt - 1] == '/') return null;
    const close = std.mem.findPos(u8, body, gt, "</stats>") orelse return null;
    return body[gt + 1 .. close];
}

/// `<items max_quality_tier="N">`: stock parses it into the static and falls
/// back to 6 when absent or unparsable. A value outside 1..255 keeps the
/// default rather than producing a degenerate quality axis.
pub fn rootMaxQualityTier(src: []const u8) u8 {
    const ri = std.mem.findPos(u8, src, 0, "<items") orelse return components.max_quality_tiers;
    const v = xml.attr(src, ri, "max_quality_tier") orelse return components.max_quality_tiers;
    const n = xml.parseU8(v) orelse return components.max_quality_tiers;
    // 0 would collapse every quality axis (stock assigns the parsed value
    // unchecked and divides by it); fail closed on the default instead.
    if (n == 0) return components.max_quality_tiers;
    return n;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?ItemTable {
    return paths.tryLoadConfig("items.xml", ItemTable, loadFromPath, allocator, game_dir, config_dir);
}

pub fn writeI32Le(buf: []u8, pos: *usize, v: i32) error{Overflow}!void {
    if (pos.* + 4 > buf.len) return error.Overflow;
    std.mem.writeInt(i32, buf[pos.*..][0..4], v, .little);
    pos.* += 4;
}

pub fn writeDotNetString(buf: []u8, pos: *usize, s: []const u8) error{Overflow}!void {
    var len = s.len;
    while (true) {
        if (pos.* >= buf.len) return error.Overflow;
        // Low byte first; the | 0x80 below overwrites bit 7 with the
        // continuation flag, so the discarded high bits shift down on the next
        // iteration (same 7-bit length shape as the wire codec's writer).
        const b: u8 = @truncate(len);
        if (len < 0x80) {
            buf[pos.*] = b;
            pos.* += 1;
            break;
        }
        buf[pos.*] = b | 0x80;
        pos.* += 1;
        len >>= 7;
    }
    if (pos.* + s.len > buf.len) return error.Overflow;
    @memcpy(buf[pos.* .. pos.* + s.len], s);
    pos.* += s.len;
}

/// Stock FastTags match between a passive's tag list and a drop row's tag
/// list: an untagged passive applies to every drop; a tagged passive needs
/// a shared tag with the drop (an untagged drop is only matched by
/// untagged passives).
pub fn tagsIntersect(row_tags: []const u8, drop_tags: []const u8) bool {
    if (row_tags.len == 0) return true;
    if (drop_tags.len == 0) return false;
    var it = std.mem.splitScalar(u8, row_tags, ',');
    while (it.next()) |rt| {
        const t = std.mem.trim(u8, rt, " \t");
        if (t.len == 0) continue;
        var it2 = std.mem.splitScalar(u8, drop_tags, ',');
        while (it2.next()) |dt| {
            if (std.mem.eql(u8, t, std.mem.trim(u8, dt, " \t"))) return true;
        }
    }
    return false;
}

pub fn typeFromBuiltinId(item_id: u16) i32 {
    if (item_id == 0) return 0;
    return items_start_here + @as(i32, item_id);
}
