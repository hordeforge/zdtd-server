//! Item XML row readers: action-class, cvar/progression/exp scans,
//! bool props, stats bodies, and rounding.
//!
//! Split out of assets/items.zig (same code, moved verbatim; private fns
//! made pub); used by the table loader in items.zig.
//!
const std = @import("std");
const xml = @import("xml_util.zig");

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
        return @intFromFloat(if (@mod(f, 2.0) == 0) f else f + 1);
    }
    return @intFromFloat(@round(v));
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
