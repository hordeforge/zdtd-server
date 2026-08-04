//! Clean-room config XML patches (stock XmlPatcher subset).
//! Override files under --config-overrides dirs, applied in filename order.
//!
//! Supported ops (element local name, case-insensitive):
//!   set / setattribute / setbyxpath  — set attribute or replace element text
//!   remove / removebyxpath           — delete matched element
//!   append / appendbyxpath           — append child markup under matched element
//!
//! XPath subset: /tag/tag[@attr='val']/... and optional trailing /@attr
//! Root may be <configs file="blocks.xml"> … or file inferred from first /tag.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");

pub const max_override_files: usize = 256;
pub const max_path: usize = 2048;

const XSeg = struct {
    tag: []const u8 = "",
    filter_attr: ?[]const u8 = null,
    filter_val: ?[]const u8 = null,
};

const ParsedXPath = struct {
    segs: [16]XSeg = [_]XSeg{.{}} ** 16,
    n: usize = 0,
    /// Trailing attribute name when xpath ends with /@attr
    set_attr: ?[]const u8 = null,
};

fn parseXPath(xpath: []const u8) ?ParsedXPath {
    var out: ParsedXPath = .{};
    var s = std.mem.trim(u8, xpath, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '/') s = s[1..];
    // Trailing /@attr
    if (std.mem.lastIndexOf(u8, s, "/@")) |at| {
        out.set_attr = s[at + 2 ..];
        s = s[0..at];
    }
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        if (out.n >= out.segs.len) return null;
        var seg: XSeg = .{};
        if (std.mem.indexOfScalar(u8, raw, '[')) |br| {
            seg.tag = raw[0..br];
            // [@name='val'] or [@name="val"]
            const filt = raw[br..];
            if (std.mem.indexOf(u8, filt, "@")) |ai| {
                const rest = filt[ai + 1 ..];
                const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
                seg.filter_attr = std.mem.trim(u8, rest[0..eq], " \t");
                var v = std.mem.trim(u8, rest[eq + 1 ..], " \t]");
                if (v.len >= 2 and (v[0] == '\'' or v[0] == '"')) {
                    const q = v[0];
                    v = v[1..];
                    if (std.mem.indexOfScalar(u8, v, q)) |qe| v = v[0..qe];
                }
                seg.filter_val = v;
            }
        } else {
            seg.tag = raw;
        }
        if (seg.tag.len == 0) return null;
        out.segs[out.n] = seg;
        out.n += 1;
    }
    if (out.n == 0) return null;
    return out;
}

/// Infer stock config file from first xpath tag (blocks → blocks.xml).
pub fn fileFromXPath(xpath: []const u8) ?[]const u8 {
    const p = parseXPath(xpath) orelse return null;
    if (p.n == 0) return null;
    const tag = p.segs[0].tag;
    // Common stock roots
    const map = [_]struct { []const u8, []const u8 }{
        .{ "blocks", "blocks.xml" },
        .{ "items", "items.xml" },
        .{ "recipes", "recipes.xml" },
        .{ "lootcontainers", "loot.xml" },
        .{ "loot", "loot.xml" },
        .{ "entity_classes", "entityclasses.xml" },
        .{ "entityclasses", "entityclasses.xml" },
        .{ "entitygroups", "entitygroups.xml" },
        .{ "quests", "quests.xml" },
        .{ "traders", "traders.xml" },
        .{ "spawning", "spawning.xml" },
        .{ "buffs", "buffs.xml" },
        .{ "progression", "progression.xml" },
        .{ "vehicles", "vehicles.xml" },
        .{ "biomes", "biomes.xml" },
        .{ "materials", "materials.xml" },
        .{ "painting", "painting.xml" },
        .{ "worldglobal", "worldglobal.xml" },
        .{ "gamestages", "gamestages.xml" },
        .{ "dialogs", "dialogs.xml" },
        .{ "npc", "npc.xml" },
        .{ "rwgmixer", "rwgmixer.xml" },
        .{ "utilityai", "utilityai.xml" },
        .{ "weathersurvival", "weathersurvival.xml" },
        .{ "challenges", "challenges.xml" },
        .{ "item_modifiers", "item_modifiers.xml" },
        .{ "qualityinfo", "qualityinfo.xml" },
        .{ "shapes", "shapes.xml" },
        .{ "sounds", "sounds.xml" },
        .{ "events", "events.xml" },
        .{ "gameevents", "gameevents.xml" },
        .{ "archetypes", "archetypes.xml" },
        .{ "nav_objects", "nav_objects.xml" },
        .{ "misc", "misc.xml" },
    };
    for (map) |e| {
        if (std.mem.eql(u8, tag, e[0])) return e[1];
    }
    // Fallback: tag.xml
    return null;
}

fn elementMatches(hay: []const u8, open_at: usize, seg: XSeg) bool {
    // open_at points at '<'
    if (open_at + 1 + seg.tag.len > hay.len) return false;
    if (hay[open_at] != '<') return false;
    const tag_start = open_at + 1;
    if (!std.mem.startsWith(u8, hay[tag_start..], seg.tag)) return false;
    const after = tag_start + seg.tag.len;
    if (after < hay.len) {
        const c = hay[after];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != '>' and c != '/')
            return false;
    }
    if (seg.filter_attr) |fa| {
        const fv = seg.filter_val orelse return false;
        const got = xml.attr(hay, open_at, fa) orelse return false;
        return std.mem.eql(u8, got, fv);
    }
    return true;
}

/// Find open index of element matching full path; returns open_at or null.
fn findElement(hay: []const u8, xp: ParsedXPath) ?usize {
    return findElementIn(hay, xp, 0);
}

fn findElementIn(hay: []const u8, xp: ParsedXPath, start_seg: usize) ?usize {
    if (start_seg >= xp.n) return null;
    var search_from: usize = 0;
    while (search_from < hay.len) {
        const lt = std.mem.indexOfPos(u8, hay, search_from, "<") orelse break;
        if (lt + 1 < hay.len and (hay[lt + 1] == '/' or hay[lt + 1] == '!' or hay[lt + 1] == '?')) {
            search_from = lt + 1;
            continue;
        }
        if (elementMatches(hay, lt, xp.segs[start_seg])) {
            if (start_seg + 1 == xp.n) return lt;
            const gt = std.mem.indexOfPos(u8, hay, lt, ">") orelse break;
            if (gt > lt and hay[gt - 1] == '/') {
                search_from = gt + 1;
                continue;
            }
            const tag = xp.segs[start_seg].tag;
            var close_buf: [64]u8 = undefined;
            if (tag.len + 3 > close_buf.len) return null;
            close_buf[0] = '<';
            close_buf[1] = '/';
            @memcpy(close_buf[2..][0..tag.len], tag);
            close_buf[2 + tag.len] = '>';
            const close_tag = close_buf[0 .. 3 + tag.len];
            const close = std.mem.indexOfPos(u8, hay, gt + 1, close_tag) orelse {
                search_from = gt + 1;
                continue;
            };
            const body = hay[gt + 1 .. close];
            if (findElementIn(body, xp, start_seg + 1)) |rel| {
                return (gt + 1) + rel;
            }
            search_from = close + close_tag.len;
            continue;
        }
        search_from = lt + 1;
    }
    return null;
}

fn elementSpan(hay: []const u8, open_at: usize) ?struct { start: usize, end: usize } {
    const gt = std.mem.indexOfPos(u8, hay, open_at, ">") orelse return null;
    if (gt > open_at and hay[gt - 1] == '/') {
        return .{ .start = open_at, .end = gt + 1 };
    }
    // tag name
    var t0 = open_at + 1;
    while (t0 < hay.len and (hay[t0] == ' ' or hay[t0] == '\t')) t0 += 1;
    var t1 = t0;
    while (t1 < hay.len) : (t1 += 1) {
        const c = hay[t1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
    }
    const tag = hay[t0..t1];
    var close_buf: [72]u8 = undefined;
    if (tag.len + 3 > close_buf.len) return null;
    close_buf[0] = '<';
    close_buf[1] = '/';
    @memcpy(close_buf[2..][0..tag.len], tag);
    close_buf[2 + tag.len] = '>';
    const close_tag = close_buf[0 .. 3 + tag.len];
    const close = std.mem.indexOfPos(u8, hay, gt + 1, close_tag) orelse return null;
    return .{ .start = open_at, .end = close + close_tag.len };
}

fn setAttribute(allocator: std.mem.Allocator, hay: []const u8, open_at: usize, attr_name: []const u8, new_val: []const u8) ![]u8 {
    const gt = std.mem.indexOfPos(u8, hay, open_at, ">") orelse return error.BadElement;
    const window = hay[open_at .. gt + 1];
    // Find attr="..."
    var needle_buf: [80]u8 = undefined;
    if (attr_name.len + 2 > needle_buf.len) return error.NameTooLong;
    @memcpy(needle_buf[0..attr_name.len], attr_name);
    needle_buf[attr_name.len] = '=';
    const needle = needle_buf[0 .. attr_name.len + 1];
    if (std.mem.indexOf(u8, window, needle)) |ai| {
        var p = open_at + ai + needle.len;
        while (p < hay.len and (hay[p] == ' ' or hay[p] == '\t')) p += 1;
        if (p >= hay.len or hay[p] != '"') return error.BadAttr;
        const vstart = p + 1;
        const vend = std.mem.indexOfScalarPos(u8, hay, vstart, '"') orelse return error.BadAttr;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, hay[0..vstart]);
        try out.appendSlice(allocator, new_val);
        try out.appendSlice(allocator, hay[vend..]);
        return try out.toOwnedSlice(allocator);
    }
    // Insert before '>'
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const insert_at = if (gt > open_at and hay[gt - 1] == '/') gt - 1 else gt;
    try out.appendSlice(allocator, hay[0..insert_at]);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, attr_name);
    try out.appendSlice(allocator, "=\"");
    try out.appendSlice(allocator, new_val);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, hay[insert_at..]);
    return try out.toOwnedSlice(allocator);
}

fn opNameEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

/// Apply one patch document to base XML. Caller frees result.
pub fn applyPatchDoc(allocator: std.mem.Allocator, base: []const u8, patch_xml: []const u8, target_file: []const u8) ![]u8 {
    const clean = try xml.stripComments(allocator, patch_xml);
    defer allocator.free(clean);
    var cur = try allocator.dupe(u8, base);
    errdefer allocator.free(cur);

    // Optional file= on configs root
    var patch_file_filter: ?[]const u8 = null;
    if (std.mem.indexOf(u8, clean, "<configs")) |ci| {
        if (xml.attr(clean, ci, "file")) |f| patch_file_filter = f;
    }
    if (patch_file_filter) |pf| {
        if (!std.mem.eql(u8, pf, target_file)) {
            // Patch not for this file
            return cur;
        }
    }

    var i: usize = 0;
    while (i < clean.len) {
        const lt = std.mem.indexOfPos(u8, clean, i, "<") orelse break;
        if (lt + 1 >= clean.len) break;
        if (clean[lt + 1] == '/' or clean[lt + 1] == '!' or clean[lt + 1] == '?') {
            i = lt + 1;
            continue;
        }
        // op name
        var ne = lt + 1;
        while (ne < clean.len) : (ne += 1) {
            const c = clean[ne];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
        }
        const op = clean[lt + 1 .. ne];
        if (opNameEq(op, "configs") or opNameEq(op, "config")) {
            i = ne;
            continue;
        }
        const xpath = xml.attr(clean, lt, "xpath") orelse {
            i = ne;
            continue;
        };
        // Infer file from xpath when no root file=
        if (patch_file_filter == null) {
            if (fileFromXPath(xpath)) |inf| {
                if (!std.mem.eql(u8, inf, target_file)) {
                    i = ne;
                    continue;
                }
            }
        }
        const gt = std.mem.indexOfPos(u8, clean, lt, ">") orelse break;
        const self_close = gt > lt and clean[gt - 1] == '/';
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!self_close) {
            var cbuf: [80]u8 = undefined;
            if (op.len + 3 > cbuf.len) {
                i = gt + 1;
                continue;
            }
            cbuf[0] = '<';
            cbuf[1] = '/';
            @memcpy(cbuf[2..][0..op.len], op);
            cbuf[2 + op.len] = '>';
            const ct = cbuf[0 .. 3 + op.len];
            const cl = std.mem.indexOfPos(u8, clean, gt + 1, ct) orelse {
                i = gt + 1;
                continue;
            };
            body = std.mem.trim(u8, clean[gt + 1 .. cl], " \t\r\n");
            next_i = cl + ct.len;
        }

        const xp = parseXPath(xpath) orelse {
            i = next_i;
            continue;
        };

        if (opNameEq(op, "set") or opNameEq(op, "setattribute") or opNameEq(op, "setattributewithxpath") or opNameEq(op, "setbyxpath") or opNameEq(op, "setattributebyxpath")) {
            const open = findElement(cur, xp) orelse {
                i = next_i;
                continue;
            };
            const attr_name = xp.set_attr orelse "value";
            const new_val = if (body.len > 0) body else (xml.attr(clean, lt, "value") orelse {
                i = next_i;
                continue;
            });
            const updated = try setAttribute(allocator, cur, open, attr_name, new_val);
            allocator.free(cur);
            cur = updated;
        } else if (opNameEq(op, "remove") or opNameEq(op, "removebyxpath")) {
            const open = findElement(cur, xp) orelse {
                i = next_i;
                continue;
            };
            const span = elementSpan(cur, open) orelse {
                i = next_i;
                continue;
            };
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, cur[0..span.start]);
            try out.appendSlice(allocator, cur[span.end..]);
            allocator.free(cur);
            cur = try out.toOwnedSlice(allocator);
        } else if (opNameEq(op, "append") or opNameEq(op, "appendbyxpath")) {
            const open = findElement(cur, xp) orelse {
                i = next_i;
                continue;
            };
            const span = elementSpan(cur, open) orelse {
                i = next_i;
                continue;
            };
            // Insert before closing tag of matched element
            const gt2 = std.mem.indexOfPos(u8, cur, open, ">") orelse {
                i = next_i;
                continue;
            };
            if (gt2 > open and cur[gt2 - 1] == '/') {
                i = next_i;
                continue;
            }
            // Find last close before span.end
            const insert_at = span.end - blk: {
                // length of </tag>
                var t0 = open + 1;
                while (t0 < cur.len and (cur[t0] == ' ' or cur[t0] == '\t')) t0 += 1;
                var t1 = t0;
                while (t1 < cur.len) : (t1 += 1) {
                    const c = cur[t1];
                    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
                }
                break :blk (t1 - t0) + 3; // </tag>
            };
            if (insert_at > span.end or insert_at < open) {
                i = next_i;
                continue;
            }
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, cur[0..insert_at]);
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, body);
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, cur[insert_at..]);
            allocator.free(cur);
            cur = try out.toOwnedSlice(allocator);
        }
        i = next_i;
    }
    return cur;
}

/// List *.xml under dir (non-recursive) into out paths (caller frees each full path).
pub fn listXmlFilesSorted(allocator: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    const names = io_fs.listFileNames(allocator, dir_path) catch return;
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    var xml_names: std.ArrayList([]const u8) = .empty;
    defer xml_names.deinit(allocator);
    for (names) |n| {
        if (!std.mem.endsWith(u8, n, ".xml")) continue;
        try xml_names.append(allocator, n);
    }
    std.mem.sort([]const u8, xml_names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    for (xml_names.items) |n| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, n });
        try out.append(allocator, full);
    }
}

/// Apply all override XMLs from dirs (dir order, then filename order) onto base for target_file.
pub fn applyOverrideDirs(
    allocator: std.mem.Allocator,
    base: []const u8,
    target_file: []const u8,
    override_dirs: []const []const u8,
) ![]u8 {
    var cur = try allocator.dupe(u8, base);
    errdefer allocator.free(cur);
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }
    for (override_dirs) |d| {
        if (d.len == 0) continue;
        try listXmlFilesSorted(allocator, d, &files);
    }
    for (files.items) |fp| {
        const patch_raw = io_fs.readFileAll(allocator, fp) catch continue;
        defer allocator.free(patch_raw);
        const next = applyPatchDoc(allocator, cur, patch_raw, target_file) catch continue;
        allocator.free(cur);
        cur = next;
    }
    return cur;
}

test "parse xpath property value" {
    const p = parseXPath("/blocks/block[@name='generatorbank']/property[@name='MaxFuel']/@value").?;
    try std.testing.expectEqual(@as(usize, 3), p.n);
    try std.testing.expectEqualStrings("blocks", p.segs[0].tag);
    try std.testing.expectEqualStrings("block", p.segs[1].tag);
    try std.testing.expectEqualStrings("generatorbank", p.segs[1].filter_val.?);
    try std.testing.expectEqualStrings("value", p.set_attr.?);
}

test "set MaxFuel on generatorbank" {
    const base =
        \\<blocks>
        \\<block name="generatorbank">
        \\  <property name="MaxFuel" value="1000"/>
        \\  <property name="MaxPower" value="12250"/>
        \\</block>
        \\</blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <set xpath="/blocks/block[@name='generatorbank']/property[@name='MaxFuel']/@value">50</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "value=\"50\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "12250") != null);
}

test "remove block" {
    const base =
        \\<blocks>
        \\<block name="a"><property name="x" value="1"/></block>
        \\<block name="b"><property name="x" value="2"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs>
        \\  <remove xpath="/blocks/block[@name='a']"/>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "name=\"a\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name=\"b\"") != null);
}

test "fileFromXPath" {
    try std.testing.expectEqualStrings("blocks.xml", fileFromXPath("/blocks/block[@name='x']").?);
    try std.testing.expectEqualStrings("items.xml", fileFromXPath("/items/item[@name='y']").?);
}
